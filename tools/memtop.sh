#!/bin/bash
# Top N processes by memory, plus a census of where the RAM ACTUALLY went.
#
# Run as root. On this machine processes have never explained more than ~4 GB
# of the ~28 GB `free` calls "used", so the top-N list alone cannot find the
# culprit -- the physical page census below is what does.
#
#   sudo ./tools/memtop.sh          # top 10 + full census
#   sudo ./tools/memtop.sh 20       # top 20 instead
#
# Already RULED OUT by direct test on this box, do not re-chase:
#   nvidia_uvm (unloaded, memory did not return), ZFS (not installed), zram,
#   CMA, hugepages, KVM guests, tmpfs/shm, dma_buf, slab, vmalloc.

N=${1:-10}
[ "$(id -u)" -eq 0 ] || echo "NOTE: not root -- the census and slab/vmalloc sections will be skipped."

printf '=== TOP %d PROCESSES BY MEMORY (RSS) ===\n' "$N"
printf '%9s %8s  %-9s %s\n' 'RSS' 'PID' 'USER' 'COMMAND'
ps -eo rss=,pid=,user=,args= --sort=-rss | head -n "$N" | while read -r rss pid user args; do
    printf '%8.1fM %8s  %-9s %.60s\n' "$(echo "$rss/1024" | bc -l)" "$pid" "$user" "$args"
done

echo
echo '=== WHAT THE COUNTERS SAY ==='
ps -eo rss= | awk '{s+=$1} END {printf "%-16s %8.2f GB   <- every process added up\n", "all processes", s/1048576}'
awk '
/^MemTotal/{t=$2} /^MemFree/{f=$2} /^Buffers/{b=$2} /^Cached:/{c=$2}
/^SReclaimable/{sr=$2} /^SUnreclaim/{su=$2} /^AnonPages/{a=$2} /^Shmem:/{sh=$2}
/^PageTables/{pt=$2} /^SecPageTables/{spt=$2} /^KernelStack/{ks=$2}
/^VmallocUsed/{v=$2} /^Percpu/{pc=$2}
END {
    printf "%-16s %8.2f GB   <- process memory the kernel counts\n", "AnonPages", a/1048576
    printf "%-16s %8.2f GB   <- page cache (reclaimable, not a leak)\n", "Cached", (c+b)/1048576
    printf "%-16s %8.2f GB   <- kernel slab\n", "Slab", (sr+su)/1048576
    printf "%-16s %8.2f GB   <- shared memory / tmpfs\n", "Shmem", sh/1048576
    printf "%-16s %8.2f GB   <- pgtables + kstacks + vmalloc + percpu\n", "kernel misc", (pt+spt+ks+v+pc)/1048576
    printf "%-16s %8.2f GB   <- free\n", "MemFree", f/1048576
    printf "%-16s %8s\n", "", "--------"
    known = f+b+c+sr+su+a+sh+pt+spt+ks+v+pc
    printf "%-16s %8.2f GB\n", "MemTotal", t/1048576
    printf "%-16s %8.2f GB\n", "accounted", known/1048576
    printf "%-16s %8.2f GB   <- belongs to NO counter\n", "UNACCOUNTED", (t-known)/1048576
}' /proc/meminfo

# ---------------------------------------------------------------- census ----
# /proc/kpageflags is one 64-bit flag word per physical page frame. Walking it
# classifies EVERY page by what the kernel thinks it is. This kernel has
# CONFIG_PAGE_OWNER and CONFIG_MEM_ALLOC_PROFILING both unset, so this is the
# best available answer to "who allocated it" -- it gives the WHAT, and a
# large "unflagged" bucket means pages taken by a driver via alloc_pages(),
# which is exactly the memory no counter reports.
if [ -r /proc/kpageflags ]; then
    echo
    echo '=== PHYSICAL PAGE CENSUS (/proc/kpageflags) ==='
    python3 - <<'PY'
import sys
BITS = {0:"LOCKED",1:"ERROR",2:"REFERENCED",3:"UPTODATE",4:"DIRTY",5:"LRU",
        6:"ACTIVE",7:"SLAB",8:"WRITEBACK",9:"RECLAIM",10:"BUDDY",11:"MMAP",
        12:"ANON",13:"SWAPCACHE",14:"SWAPBACKED",15:"COMP_HEAD",16:"COMP_TAIL",
        17:"HUGE",18:"UNEVICTABLE",19:"HWPOISON",20:"NOPAGE",21:"KSM",22:"THP",
        23:"OFFLINE",24:"ZERO",25:"IDLE",26:"PGTABLE",32:"RESERVED",
        33:"MLOCKED",34:"MAPPEDTODISK",35:"PRIVATE",36:"PRIVATE_2",
        37:"OWNER_PRIVATE",38:"ARCH",39:"UNCACHED",40:"SOFTDIRTY"}
B = lambda n: 1 << n
NOPAGE, BUDDY, SLAB, LRU, ANON = B(20), B(10), B(7), B(5), B(12)
PGTABLE, RESERVED, COMP_TAIL, OFFLINE = B(26), B(32), B(16), B(23)

cat = {}
combos = {}
total = 0
try:
    import numpy as np
    use_np = True
except ImportError:
    use_np = False
    from array import array

def bump(d, k, n=1):
    d[k] = d.get(k, 0) + n

with open("/proc/kpageflags", "rb") as f:
    while True:
        buf = f.read(1 << 20)
        if not buf:
            break
        if use_np:
            arr = np.frombuffer(buf, dtype="<u8")
            vals, counts = np.unique(arr, return_counts=True)
            for v, c in zip(vals.tolist(), counts.tolist()):
                bump(combos, v, c)
        else:
            arr = array("Q"); arr.frombytes(buf)
            for v in arr:
                bump(combos, v)

for v, c in combos.items():
    total += c
    if v & NOPAGE:       k = "no page frame (hole)"
    elif v & OFFLINE:    k = "offline"
    elif v & RESERVED:   k = "reserved (firmware/kernel)"
    elif v & BUDDY:      k = "FREE (buddy allocator)"
    elif v & SLAB:       k = "slab"
    elif v & PGTABLE:    k = "page tables"
    elif v & ANON:       k = "anon (process memory)"
    elif v & LRU:        k = "page cache (file)"
    elif v & COMP_TAIL:  k = "compound tail (part of a huge alloc)"
    elif v == 0:         k = "ALLOCATED, NO FLAGS  <-- driver alloc_pages()"
    else:                k = "allocated, other flags"
    bump(cat, k, c)

PS = 4096
print("  %-38s %10s   %s" % ("category", "pages", "size"))
for k, c in sorted(cat.items(), key=lambda kv: -kv[1]):
    print("  %-38s %10d   %8.2f GB" % (k, c, c * PS / 1073741824))
print("  %-38s %10d   %8.2f GB" % ("TOTAL page frames", total, total * PS / 1073741824))

print()
print("  top raw flag combinations (in case the buckets above mislead):")
for v, c in sorted(combos.items(), key=lambda kv: -kv[1])[:8]:
    names = ",".join(n for b, n in BITS.items() if v & (1 << b)) or "<none>"
    print("    0x%016x %10d pages %8.2f GB  %s" % (v, c, c * PS / 1073741824, names[:60]))
PY
fi

# --------------------------------------------------------- root-only bits ---
if [ "$(id -u)" -eq 0 ]; then
    echo
    echo '=== TOP SLAB CACHES ==='
    awk 'NR>2 {kb=$2*$4/1024; if (kb>4096) printf "  %-28s %8.1f MB\n", $1, kb/1024}' /proc/slabinfo | sort -k2 -rn | head -8

    echo
    echo '=== TOP VMALLOC ALLOCATIONS ==='
    awk '{for(i=1;i<=NF;i++) if($i ~ /^pages=/){split($i,p,"="); if(p[2]*4096 > 16*1024*1024) printf "  %8.1f MB  %s\n", p[2]*4096/1048576, $3}}' /proc/vmallocinfo | sort -rn | head -8
    [ -s /proc/vmallocinfo ] || echo "  (none over 16 MB)"

    echo
    echo '=== GPU / DMA BUFFERS ==='
    if [ -e /sys/kernel/debug/dma_buf/bufinfo ]; then
        awk '/^size/{s+=$2} END {printf "  dma_buf total: %.2f GB\n", s/1073741824}' /sys/kernel/debug/dma_buf/bufinfo
    else
        echo "  no dma_buf debugfs"
    fi
    for d in /sys/kernel/debug/dri/*/; do
        [ -d "$d" ] && echo "  dri: $d $(ls "$d" 2>/dev/null | tr '\n' ' ' | cut -c1-70)"
    done
    command -v nvidia-smi >/dev/null && nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader | sed 's/^/  gpu: /'
fi

# If the no-flags bucket is large, the NVIDIA driver is the prime suspect
# on this box: os_alloc_mem in /proc/vmallocinfo resolves to [nvidia], and
# it is the only out-of-tree module here. These are the settings that make
# it hold GPU memory copies in SYSTEM RAM.
echo
echo '=== NVIDIA SYSTEM-MEMORY SETTINGS (prime suspect for no-flag pages) ==='
if [ -r /proc/driver/nvidia/params ]; then
    grep -iE "PreserveVideoMemoryAllocations|DynamicPowerManagement|EnableSystemMemoryPools|MemoryPoolSize|InitializeSystemMemoryAllocations|TemporaryFilePath" \
        /proc/driver/nvidia/params | sed 's/^/  /'
    echo '  set by:'
    grep -rniE "NVreg_(PreserveVideoMemoryAllocations|DynamicPowerManagement)" \
        /etc/modprobe.d/ /usr/lib/modprobe.d/ 2>/dev/null | sed 's/^/    /'
    echo '  nvidia suspend/resume services (these are what the Preserve option exists for):'
    systemctl list-unit-files 2>/dev/null | grep -iE "nvidia-(suspend|resume|hibernate)" | sed 's/^/    /'
    echo '  symbol check:'
    grep -w os_alloc_mem /proc/kallsyms 2>/dev/null | sed 's/^/    /'
else
    echo '  nvidia driver not loaded'
fi

# ------------------------------------------------------------- guidance -----
echo
echo 'READING THIS: if UNACCOUNTED is large AND the census shows a big'
echo '"ALLOCATED, NO FLAGS" bucket, a driver took those pages with'
echo 'alloc_pages() and no counter will ever show it. The only remaining'
echo 'question is WHICH driver, and this kernel cannot answer it directly:'
po=no; ap=no
zgrep -q '^CONFIG_PAGE_OWNER=y' /proc/config.gz 2>/dev/null && po=yes
[ -e /proc/allocinfo ] && ap=yes
printf '  this kernel (%s): page_owner=%s  /proc/allocinfo=%s\n' "$(uname -r)" "$po" "$ap"
if [ "$ap" = yes ]; then
    echo '  BEST: sort -k1 -n -r /proc/allocinfo | head -20   # names the caller'
elif [ "$po" = yes ]; then
    echo '  BEST: boot with page_owner=on, then'
    echo '        cat /sys/kernel/debug/page_owner > /tmp/po.txt'
    echo '        page_owner_sort /tmp/po.txt /tmp/s.txt && head -40 /tmp/s.txt'
else
    echo '  Neither tool exists here. Bisect instead:'
    echo '   1. Boot the other installed kernel and re-run this script:'
    ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's/^/        /'
    echo '   2. Decisive GPU-driver test, from a TTY (Ctrl-Alt-F2) as root:'
    echo '        systemctl isolate multi-user.target'
    echo '        modprobe -r nvidia_drm nvidia_modeset nvidia && free -h'
    echo '        systemctl isolate graphical.target'
    echo '      (kills the desktop session -- save work first)'
fi
