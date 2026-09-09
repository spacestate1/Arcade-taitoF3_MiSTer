#!/usr/bin/env python3
"""ES5505 model -- a port of MAME's es5506.cpp (the ES5505 half), driven by
the register write stream tools/oracle_en_dump.lua captures.

This is the sound board's f3_render.py: an exact, integer-for-integer port of
the reference, so the RTL sampler can be diffed against it sample by sample.
It is NOT tuned to sound right; it is tuned to be MAME.

    python3 tools/es5505_model.py dump/en3 --seconds 10 --out model.wav
    python3 tools/es5505_model.py dump/en3 --seconds 10 --raw model.bin
        raw: per output sample, 8 x int32 little-endian -- the four stereo
        pairs of 20-bit samples, before the pump/ESP/MB87078 -- which is what
        the RTL produces and what sim/es5505_tb diffs against.

What is reproduced (es5506.cpp, es5505 paths): the voice register file with
byte-lane writes, the 20.9 address accumulator (kept in MAME's 20.11 form
with the 2-bit shift, mask and all), two-sample linear interpolation, the
four-pole filter with the LP3/LP4 modes and C integer division, the 4+4-bit
exponent/mantissa volume table, the loop modes (none / LPE / bidirectional;
BLE alone stops, as on the 5505), the direction flag, ACT and the sample
rate it sets, the page register, and the per-voice sample bank from the
Taito EN board's 0x300000 registers. Sample words are the ROM byte in the
high byte, low byte zero (ROM_LOAD16_BYTE into an erased region).

Not reproduced (does not touch the samples): the IRQ vector, the serial
mode/test registers, reads.

Timing: MAME updates the stream before every register write, so a write
takes effect after all samples up to its machine time. The stream carries
that time; the model generates samples at the ES5505 rate up to each write
before applying it.
"""
import argparse
import os
import struct
import sys
import wave

MASTER_CLOCK = 30_476_180 // 2      # 15.238 MHz, taito_en.cpp

# es5506.h constants, ES5505 flavour
ADDRESS_FRAC_BIT = 11                # internal accumulator fraction (5506)
ADDRESS_INTEGER_BIT = 20
ADDRESS_FRAC_BIT_5505 = 9
VOLUME_BIT = 8
VOLUME_ACC_BIT = 20
FINE_FILTER_BIT = 16
FILTER_BIT = 12
FILTER_SHIFT = FINE_FILTER_BIT - FILTER_BIT

# control bits (es5506.cpp enum, 5505 placements)
CONTROL_STOP0 = 0x0001
CONTROL_STOP1 = 0x0002
CONTROL_LEI = 0x0004
CONTROL_LPE = 0x0008
CONTROL_BLE = 0x0010
CONTROL_IRQE = 0x0020
CONTROL_DIR = 0x0040
CONTROL_IRQ = 0x0080
CONTROL_STOPMASK = CONTROL_STOP0 | CONTROL_STOP1
CONTROL_LOOPMASK = CONTROL_BLE | CONTROL_LPE
LP3 = 1
LP4 = 2

ADDRESS_ACC_SHIFT = ADDRESS_FRAC_BIT - ADDRESS_FRAC_BIT_5505        # 2
ADDRESS_ACC_MASK = ((((1 << ADDRESS_INTEGER_BIT) - 1) << ADDRESS_FRAC_BIT_5505)
                    | ((1 << ADDRESS_FRAC_BIT_5505) - 1)) << ADDRESS_ACC_SHIFT
ADDRESS_ACC_MASK |= (1 << ADDRESS_ACC_SHIFT) - 1
VOLUME_SHIFT = VOLUME_BIT - (4 + 4)                                  # 0
VOLUME_ACC_SHIFT = (16 + ((1 << 4) - 1)) - VOLUME_ACC_BIT            # 11


def cdiv(a, b):
    """C integer division: truncates toward zero (Python's // floors)."""
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b > 0) else -q


def s16(v):
    v &= 0xffff
    return v - 0x10000 if v & 0x8000 else v


def s32(v):
    v &= 0xffffffff
    return v - 0x100000000 if v & 0x80000000 else v


def build_volume_table():
    exponent_bit, mantissa_bit = 4, 4
    exponent_shift = 1 << exponent_bit
    exponent_mask = exponent_shift - 1
    mantissa_len = 1 << mantissa_bit
    mantissa_mask = mantissa_len - 1
    mantissa_shift = exponent_shift - mantissa_bit - 1
    table = []
    for i in range(1 << (exponent_bit + mantissa_bit)):
        exponent = (i >> mantissa_bit) & exponent_mask
        mantissa = (i & mantissa_mask) | mantissa_len
        table.append((mantissa << mantissa_shift) >> (exponent_shift - exponent))
    return table


VOLUME = build_volume_table()


def acc_shifted(val, bias=0):
    """get_address_acc_shifted_val: register value -> internal 20.11 form."""
    sh = ADDRESS_ACC_SHIFT - bias
    return (val << sh) if sh >= 0 else (val >> -sh)


class Voice:
    __slots__ = ("control", "freqcount", "start", "end", "k2", "k1", "lvol", "rvol",
                 "accum", "o1n1", "o2n1", "o2n2", "o3n1", "o3n2", "o4n1", "bank")

    def __init__(self):
        self.control = CONTROL_STOPMASK
        self.freqcount = 0
        self.start = 0
        self.end = 0
        self.k2 = 0
        self.k1 = 0
        self.lvol = 1 << (VOLUME_BIT - 1)
        self.rvol = 1 << (VOLUME_BIT - 1)
        self.accum = 0
        self.o1n1 = self.o2n1 = self.o2n2 = self.o3n1 = self.o3n2 = self.o4n1 = 0
        self.bank = 0


class ES5505:
    def __init__(self, rom):
        self.rom = rom                        # bytes: word i's high byte
        self.rom_words = 4 * 1024 * 1024      # 8 MB region / 2
        self.voices = [Voice() for _ in range(32)]
        self.page = 0
        self.active_voices = 0x1f
        self.sample_rate = MASTER_CLOCK // (16 * (self.active_voices + 1))
        self.irqv = 0x80

    # ---- sample memory (taito_en en_otis_map) -------------------------
    def read_sample(self, v, addr):
        idx = ((v.bank << 20) + addr) & (self.rom_words - 1)
        if idx < len(self.rom):
            return s16(self.rom[idx] << 8)
        return 0

    # ---- register reads (es5505_device::reg_read_high, the one with a side
    # effect): an O1(n-1) read on a STOPPED voice fetches the raw sample word
    # at the accumulator and stores it as o1n1 -- how the Taito driver reads
    # its sound table out of the sample ROM. Every other read is pure.
    def read(self, offset):
        v = self.voices[self.page & 0x1f]
        if 0x20 <= self.page < 0x40 and offset == 6 and (v.control & CONTROL_STOPMASK):
            v.o1n1 = self.read_sample(v, (v.accum & ADDRESS_ACC_MASK) >> ADDRESS_FRAC_BIT)
            return v.o1n1 & 0xffff
        return None

    # ---- register writes ------------------------------------------------
    def write(self, offset, data, mask):
        lo = (mask & 0x00ff) != 0
        hi = (mask & 0xff00) != 0
        v = self.voices[self.page & 0x1f]
        if self.page < 0x20:
            self._write_low(v, offset, data, lo, hi)
        elif self.page < 0x40:
            self._write_high(v, offset, data, lo, hi)
        else:
            self._write_test(v, offset, data, lo, hi)

    def _page_act(self, offset, data, lo):
        if offset == 0x0d:            # ACT
            if lo:
                self.active_voices = data & 0x1f
                self.sample_rate = MASTER_CLOCK // (16 * (self.active_voices + 1))
            return True
        if offset == 0x0f:            # PAGE
            if lo:
                self.page = data & 0x7f
            return True
        return offset == 0x0e         # IRQV, read only

    def _write_low(self, v, offset, data, lo, hi):
        if offset == 0x00:            # CR
            v.control |= 0xf000
            if lo:
                v.control = (v.control & ~0x00ff) | (data & 0x00ff)
            if hi:
                v.control = (v.control & ~0x0f00) | (data & 0x0f00)
        elif offset == 0x01:          # FC
            if lo:
                v.freqcount = (v.freqcount & ~acc_shifted(0x00fe, 1)) | acc_shifted(data & 0x00fe, 1)
            if hi:
                v.freqcount = (v.freqcount & ~acc_shifted(0xff00, 1)) | acc_shifted(data & 0xff00, 1)
        elif offset == 0x02:          # STRT hi
            if lo:
                v.start = (v.start & ~acc_shifted(0x00ff0000)) | acc_shifted((data & 0x00ff) << 16)
            if hi:
                v.start = (v.start & ~acc_shifted(0x1f000000)) | acc_shifted((data & 0x1f00) << 16)
        elif offset == 0x03:          # STRT lo
            if lo:
                v.start = (v.start & ~acc_shifted(0x000000e0)) | acc_shifted(data & 0x00e0)
            if hi:
                v.start = (v.start & ~acc_shifted(0x0000ff00)) | acc_shifted(data & 0xff00)
        elif offset == 0x04:          # END hi
            if lo:
                v.end = (v.end & ~acc_shifted(0x00ff0000)) | acc_shifted((data & 0x00ff) << 16)
            if hi:
                v.end = (v.end & ~acc_shifted(0x1f000000)) | acc_shifted((data & 0x1f00) << 16)
        elif offset == 0x05:          # END lo
            if lo:
                v.end = (v.end & ~acc_shifted(0x000000e0)) | acc_shifted(data & 0x00e0)
            if hi:
                v.end = (v.end & ~acc_shifted(0x0000ff00)) | acc_shifted(data & 0xff00)
        elif offset == 0x06:          # K2
            if lo:
                v.k2 = (v.k2 & ~0x00f0) | (data & 0x00f0)
            if hi:
                v.k2 = (v.k2 & ~0xff00) | (data & 0xff00)
        elif offset == 0x07:          # K1
            if lo:
                v.k1 = (v.k1 & ~0x00f0) | (data & 0x00f0)
            if hi:
                v.k1 = (v.k1 & ~0xff00) | (data & 0xff00)
        elif offset == 0x08:          # LVOL
            if hi:
                v.lvol = (v.lvol & ~0xff) | ((data & 0xff00) >> 8)
        elif offset == 0x09:          # RVOL
            if hi:
                v.rvol = (v.rvol & ~0xff) | ((data & 0xff00) >> 8)
        elif offset == 0x0a:          # ACC hi
            if lo:
                v.accum = (v.accum & ~acc_shifted(0x00ff0000)) | acc_shifted((data & 0x00ff) << 16)
            if hi:
                v.accum = (v.accum & ~acc_shifted(0x1f000000)) | acc_shifted((data & 0x1f00) << 16)
        elif offset == 0x0b:          # ACC lo
            if lo:
                v.accum = (v.accum & ~acc_shifted(0x000000ff)) | acc_shifted(data & 0x00ff)
            if hi:
                v.accum = (v.accum & ~acc_shifted(0x0000ff00)) | acc_shifted(data & 0xff00)
        else:
            self._page_act(offset, data, lo)

    def _write_high(self, v, offset, data, lo, hi):
        if offset == 0x00:            # CR
            v.control |= 0xf000
            if lo:
                v.control = (v.control & ~0x00ff) | (data & 0x00ff)
            if hi:
                v.control = (v.control & ~0x0f00) | (data & 0x0f00)
        elif 0x01 <= offset <= 0x06:  # filter pole states
            name = {1: "o4n1", 2: "o3n1", 3: "o3n2", 4: "o2n1", 5: "o2n2", 6: "o1n1"}[offset]
            cur = getattr(v, name)
            if lo:
                cur = (cur & ~0x00ff) | (data & 0x00ff)
            if hi:
                cur = s16((cur & ~0xff00) | (data & 0xff00))
            setattr(v, name, cur)
        else:
            self._page_act(offset, data, lo)

    def _write_test(self, v, offset, data, lo, hi):
        # CH0L..CH3R, SERMODE, PAR: stream/serial configuration, no effect on
        # the generated samples
        self._page_act(offset, data, lo)

    # ---- generation -----------------------------------------------------
    @staticmethod
    def interpolate(s1, s2, accum):
        shifted = 1 << ADDRESS_FRAC_BIT
        a = accum & (shifted - 1) & ADDRESS_ACC_MASK
        return (s1 * (shifted - a) + s2 * a) >> ADDRESS_FRAC_BIT

    @staticmethod
    def lowpass(out, cutoff, inp):
        return cdiv((cutoff >> FILTER_SHIFT) * (out - inp), 1 << FILTER_BIT) + inp

    @staticmethod
    def highpass(out, cutoff, inp, prev):
        return out - prev + cdiv((cutoff >> FILTER_SHIFT) * inp, 1 << (FILTER_BIT + 1)) + cdiv(inp, 2)

    def apply_filters(self, v, sample):
        sample = self.lowpass(sample, v.k1, v.o1n1)
        v.o1n1 = sample
        sample = self.lowpass(sample, v.k1, v.o2n1)
        v.o2n2 = v.o2n1
        v.o2n1 = sample
        lp = (v.control >> 10) & 3
        if lp == 0:
            sample = self.highpass(sample, v.k2, v.o3n1, v.o2n2)
            v.o3n2 = v.o3n1
            v.o3n1 = sample
            sample = self.highpass(sample, v.k2, v.o4n1, v.o3n2)
            v.o4n1 = sample
        elif lp == LP3:
            sample = self.lowpass(sample, v.k1, v.o3n1)
            v.o3n2 = v.o3n1
            v.o3n1 = sample
            sample = self.highpass(sample, v.k2, v.o4n1, v.o3n2)
            v.o4n1 = sample
        elif lp == LP4:
            sample = self.lowpass(sample, v.k2, v.o3n1)
            v.o3n2 = v.o3n1
            v.o3n1 = sample
            sample = self.lowpass(sample, v.k2, v.o4n1)
            v.o4n1 = sample
        else:
            sample = self.lowpass(sample, v.k1, v.o3n1)
            v.o3n2 = v.o3n1
            v.o3n1 = sample
            sample = self.lowpass(sample, v.k2, v.o4n1)
            v.o4n1 = sample
        return sample

    @staticmethod
    def get_sample(sample, volume):
        return (sample * VOLUME[volume >> VOLUME_SHIFT]) >> VOLUME_ACC_SHIFT

    def check_end_forward(self, v, accum):
        if accum > v.end:
            if v.control & CONTROL_IRQE:
                v.control |= CONTROL_IRQ
            mode = v.control & CONTROL_LOOPMASK
            if mode == 0 or mode == CONTROL_BLE:
                v.control |= CONTROL_STOP0
            elif mode == CONTROL_LPE:
                accum = (v.start + (accum - v.end)) & ADDRESS_ACC_MASK
            else:
                accum = (v.end - (accum - v.end)) & ADDRESS_ACC_MASK
                v.control ^= CONTROL_DIR
        return accum

    def check_end_reverse(self, v, accum):
        if accum < v.start:
            if v.control & CONTROL_IRQE:
                v.control |= CONTROL_IRQ
            mode = v.control & CONTROL_LOOPMASK
            if mode == 0 or mode == CONTROL_BLE:
                v.control |= CONTROL_STOP0
            elif mode == CONTROL_LPE:
                accum = (v.end - (v.start - accum)) & ADDRESS_ACC_MASK
            else:
                accum = (v.start + (v.start - accum)) & ADDRESS_ACC_MASK
                v.control ^= CONTROL_DIR
        return accum

    def generate_pcm(self, v, dest, l):
        freqcount = v.freqcount
        accum = v.accum & ADDRESS_ACC_MASK
        if not (v.control & CONTROL_STOPMASK):
            a0 = (accum & ADDRESS_ACC_MASK) >> ADDRESS_FRAC_BIT
            a1 = ((accum + (1 << ADDRESS_FRAC_BIT)) & ADDRESS_ACC_MASK) >> ADDRESS_FRAC_BIT
            val1 = self.read_sample(v, a0)
            val2 = self.read_sample(v, a1)
            val1 = self.interpolate(val1, val2, accum)
            if not (v.control & CONTROL_DIR):
                accum = (accum + freqcount) & ADDRESS_ACC_MASK
            else:
                accum = (accum - freqcount) & ADDRESS_ACC_MASK
            val1 = self.apply_filters(v, val1)
            dest[l] += self.get_sample(val1, v.lvol)
            dest[l + 1] += self.get_sample(val1, v.rvol)
            if not (v.control & CONTROL_DIR):
                accum = self.check_end_forward(v, accum)
            else:
                accum = self.check_end_reverse(v, accum)
        v.accum = accum

    def generate_irq(self, v, n):
        if v.control & CONTROL_IRQ:
            if self.irqv & 0x80:
                self.irqv = n & 0x1f
                v.control &= ~CONTROL_IRQ

    def generate(self):
        """One output sample: 8 ints (four stereo pairs), 20-bit clamped."""
        cur = [0] * 8
        for n in range(self.active_voices + 1):
            v = self.voices[n]
            channel = ((v.control >> 8) & 3) % 4
            self.generate_pcm(v, cur, channel << 1)
            self.generate_irq(v, n)
        lim = 1 << 19
        return [max(-lim, min(lim - 1, x)) for x in cur]


def load_stream(path):
    """(time, tag, addr, data, mask) from oracle_en_dump.lua's en_writes.txt."""
    out = []
    with open(path) as f:
        for line in f:
            p = line.split()
            if len(p) < 6:
                continue
            frame, tag, addr, data, mask = int(p[0]), p[1], int(p[2], 16), int(p[3], 16), int(p[4], 16)
            t = float(p[5]) if len(p) > 5 else frame / 58.97
            if tag in ("ES", "BK", "VL", "ESR"):
                out.append((t, tag, addr, data, mask))
    return out


def load_rom_file(path):
    """A prebuilt sample image in ES5505 word order, one byte per word.

    load_rom() below only knows Ray Force / Gunlock, whose two 2 MB ROMs
    happen to concatenate into exactly the compacted image. Every other F3
    set has its own layout -- Riding Fight, Ring Rage, Arabian Magic and
    Grid Seeker load the second ROM at region 0x600000, which is a 1 MB
    hole in word space -- so those games need the image built for them.
    tools/rf_stream_sum.py's assembler produces exactly these bytes as the
    MRA's ensoniq slice, which is also what the core has in SDRAM: feeding
    that here compares the model against the bytes the board actually holds.
    """
    return open(path, "rb").read()


def load_rom(root):
    """The Ensoniq sample bytes in ES5505 word order: d66-01 then d66-02."""
    import zipfile
    for name in ("gunlock.zip", "rayforce.zip"):
        p = os.path.join(root, name)
        if os.path.exists(p):
            z = zipfile.ZipFile(p)
            data = b""
            for want in ("d66-01.ic2", "d66-02.ic3"):
                m = [n for n in z.namelist() if n.endswith(want)][0]
                data += z.read(m)
            return data
    raise SystemExit("gunlock.zip / rayforce.zip not found in " + root)


def run(stream, rom, seconds, gains=None):
    chip = ES5505(rom)
    banks = [0] * 32
    out = []                      # raw 8-channel samples
    t = 0.0
    i = 0
    n = len(stream)
    while t < seconds:
        # apply every write due before the next sample
        while i < n and stream[i][0] <= t:
            _, tag, addr, data, mask = stream[i]
            if tag == "ES":
                chip.write((addr - 0x200000) >> 1, data, mask)
            elif tag == "ESR":
                chip.read((addr - 0x200000) >> 1)
            elif tag == "BK":
                banks[((addr - 0x300000) >> 1) & 31] = data & 3
                for k in range(32):
                    chip.voices[k].bank = banks[k]
            i += 1
        out.append(chip.generate())
        t += 1.0 / chip.sample_rate
    return out, chip.sample_rate


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dumpdir")
    ap.add_argument("--rom", default=".", help="directory holding gunlock.zip")
    ap.add_argument("--rom-file", help="prebuilt sample image in ES5505 word "
                    "order (one byte per word) -- required for any set whose "
                    "ensoniq layout is not Ray Force's two contiguous ROMs")
    ap.add_argument("--seconds", type=float, default=5.0)
    ap.add_argument("--out", help="stereo 16-bit wav of a dry mix, at the ES5505 rate")
    ap.add_argument("--raw", help="the 8-channel 20-bit stream, 8 x int32 per sample")
    ap.add_argument("--dump-rom", help="write the sample bytes in ES5505 word order (for the RTL bench)")
    args = ap.parse_args()
    if args.dump_rom:
        with open(args.dump_rom, "wb") as f:
            f.write(load_rom_file(args.rom_file) if args.rom_file else load_rom(args.rom))
        print("rom ->", args.dump_rom)
        if not (args.out or args.raw):
            return

    stream = load_stream(os.path.join(args.dumpdir, "en_writes.txt"))
    rom = load_rom_file(args.rom_file) if args.rom_file else load_rom(args.rom)
    print(f"{len(stream)} chip writes, {len(rom)} sample bytes")
    samples, rate = run(stream, rom, args.seconds)
    print(f"{len(samples)} samples at {rate} Hz")

    if args.raw:
        with open(args.raw, "wb") as f:
            for s in samples:
                f.write(struct.pack("<8i", *s))
        print("raw ->", args.raw)
    if args.out:
        # dry mix as the pump would with the ESP summing: L = ch0L + ch1L + ch2L + ch3L
        w = wave.open(args.out, "wb")
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(rate)
        buf = bytearray()
        for s in samples:
            l = (s[0] + s[2] + s[4] + s[6]) >> 4
            r = (s[1] + s[3] + s[5] + s[7]) >> 4
            buf += struct.pack("<hh", max(-32768, min(32767, l)), max(-32768, min(32767, r)))
        w.writeframes(bytes(buf))
        w.close()
        print("wav ->", args.out)


if __name__ == "__main__":
    main()
