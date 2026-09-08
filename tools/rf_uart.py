#!/usr/bin/env python3
"""Capture the core's UART debug output from the MiSTer.

The core drives UART_TXD, which sys_top wires to the HPS UART, so it arrives
on the board as /dev/ttyS1 (ttyS0 is the Linux console).

    .venv/bin/python3 tools/rf_uart.py                # 10 s of self-test pages
    .venv/bin/python3 tools/rf_uart.py -t 20 -o cap.txt

With "UART Debug" on its default (Self Test) this prints the self-test page,
one row per frame, repeating about twice a second. Set it to "Write Ring" in
the OSD for the Phase 0/1 write-stream oracle instead -- see
tools/rf_write_compare.py and the alignment note in HANDOFF.md.
"""
import argparse
import sys

import os

import paramiko

# The board is on DHCP and has moved before; RF_HOST overrides, as rf_deploy
# does. The router publishes it as MiSTer.lan.
HOST = os.environ.get("RF_HOST", "MiSTer.lan")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-t", "--seconds", type=int, default=10)
    ap.add_argument("-o", "--out")
    args = ap.parse_args()

    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username="root", password="1", timeout=15)

    cmd = (f"stty -F /dev/ttyS1 115200 raw -echo; "
           f"timeout {args.seconds} cat /dev/ttyS1")
    _, out, err = c.exec_command(cmd, timeout=args.seconds + 30)
    text = out.read().decode(errors="ignore")
    e = err.read().decode(errors="ignore")
    c.close()

    if e.strip():
        print(e, file=sys.stderr)
    if args.out:
        open(args.out, "w").write(text)
        print(f"wrote {args.out} ({len(text)} bytes)")
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
