import fcntl, glob, os, shutil, struct, sys, time
UI_SET_EVBIT, UI_SET_KEYBIT, UI_SET_ABSBIT = 0x40045564, 0x40045565, 0x40045567
UI_DEV_CREATE = 0x5501
EV_SYN, EV_KEY, EV_ABS = 0x00, 0x01, 0x03

# exactly the Xbox One pad's capabilities, so MiSTer's built-in gamepad
# defaults apply to us the same way they do to the real one
BTN = [0x130,0x131,0x133,0x134,0x136,0x137,0x13a,0x13b,0x13c,0x13d,0x13e]
NAME = {0x13a:"SELECT_coin", 0x13b:"START", 0x130:"A", 0x131:"B"}
AXES = {0x00:(-32768,32767), 0x01:(-32768,32767), 0x02:(0,1023),
        0x03:(-32768,32767), 0x04:(-32768,32767), 0x05:(0,1023),
        0x10:(-1,1), 0x11:(-1,1)}

mra, wait = sys.argv[1], float(sys.argv[2])
seq = sys.argv[3:]                      # e.g. SELECT_coin:1 START:1
OUT = "/tmp/rf_pad_shots"
shutil.rmtree(OUT, ignore_errors=True); os.makedirs(OUT)

def emit(fd,t,c,v): os.write(fd, struct.pack("@llHHi",0,0,t,c,v))
def press(fd,code,ms=120):
    emit(fd,EV_KEY,code,1); emit(fd,EV_SYN,0,0); time.sleep(ms/1000.0)
    emit(fd,EV_KEY,code,0); emit(fd,EV_SYN,0,0); time.sleep(0.25)

def shot(n,label):
    for d_ in glob.glob("/media/fat/screenshots/*/"):
        for f in glob.glob(d_+"*.png"): os.remove(f)
    open("/dev/MiSTer_cmd","w").write("screenshot\n"); time.sleep(3)
    for d_ in glob.glob("/media/fat/screenshots/*/"):
        g = glob.glob(d_+"*.png")
        if g: shutil.copy(g[0], "%s/%02d_%s.png"%(OUT,n,label)); return

fd = os.open("/dev/uinput", os.O_WRONLY|os.O_NONBLOCK)
fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY); fcntl.ioctl(fd, UI_SET_EVBIT, EV_ABS)
for b in BTN: fcntl.ioctl(fd, UI_SET_KEYBIT, b)
for a in AXES: fcntl.ioctl(fd, UI_SET_ABSBIT, a)
amax=[0]*64; amin=[0]*64
for a,(lo,hi) in AXES.items(): amin[a]=lo; amax[a]=hi
os.write(fd, struct.pack("@80sHHHHi", b"Microsoft X-Box One pad", 3, 0x045e, 0x02d1, 0x0101, 0)
           + struct.pack("@64i",*amax) + struct.pack("@64i",*amin)
           + struct.pack("@64i",*([0]*64)) + struct.pack("@64i",*([0]*64)))
fcntl.ioctl(fd, UI_DEV_CREATE)
print("virtual pad up"); sys.stdout.flush()
time.sleep(2)
print(open("/proc/bus/input/devices").read().count("X-Box"), "xbox-like devices now")
sys.stdout.flush()

if mra != "-":
    open("/dev/MiSTer_cmd","w").write("load_core %s\n"%mra)
    print("core loaded, waiting %gs"%wait); sys.stdout.flush(); time.sleep(wait)

n=0; shot(n,"attract"); n+=1
for tok in seq:
    name,_,rep = tok.partition(":")
    code = {v:k for k,v in NAME.items()}.get(name)
    if code is None: print("unknown",name); continue
    for _ in range(int(rep) if rep else 1): press(fd,code)
    print("pressed",name); sys.stdout.flush()
    time.sleep(2.0); shot(n,name); n+=1
time.sleep(6); shot(n,"after6s"); n+=1
time.sleep(10); shot(n,"after16s")
print("done")
