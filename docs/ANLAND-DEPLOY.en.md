# anland Linux desktop deployment guide

Running a Linux desktop on **ARM Mali platforms (G720-class GPU)**, with the
picture shown on the Android screen through anland.

[**English**](ANLAND-DEPLOY.en.md) | [简体中文](ANLAND-DEPLOY.md)

Every step here was **actually verified** and has matching on-device evidence.
Precondition: you do not want to rebuild the kernel, so the LKM has to supply
the missing capabilities.

---

## Read this first: this guide covers anland 5.x

anland has two generations and the container-side setup is **completely
different** between them. Do not mix them.

| | **5.x** (this guide) | **6.x** |
|---|---|---|
| Display protocol | private Anland Display Protocol | **Wayland itself** |
| Compositor | requires a **patched compositor** (Hyprland/KWin with an anland backend) | **stock compositors work unmodified** |
| Transport | `/run/display.sock` + bind mount | binder-passed fds, **no socket file** |
| Windows | the whole screen maps to one Android window | **each window becomes a real Android window** |
| Container side | nothing (the patched compositor does it) | an `anlandx` session (wayland link + rootless Xwayland + mini-wm) |
| Host artifacts | `anland-daemon.zip` + `anland-v5.apk` (`com.anland.consumer`) | `module/anland-awl.zip` + `anland-wayland.apk` + `anlandx.tar.gz` |

**The 5.x pain point:** that patched compositor is **not** published in the
public `anland-kde-packages`. Measured: after installing those .debs, the
`kwin_wayland` binary contains zero occurrences of "anland" — the session
starts, the compositor runs, but there is no output path to the screen. The
user sees a black screen.

**6.x sidesteps that dead end** by making Wayland itself the frame-exchange
protocol: the host-side `waylandbridge` (KernelSU module `anland-awl`) turns
every `xdg_toplevel` into a real Android window over binder, so stock
compositors need no changes.

If you are on a **Mali / MediaTek device and cannot obtain a patched
compositor**, prefer the 6.x route. The matching 6.x image builder lives at
[`misaka5202/Droidspaces-anland6-rootfs`](https://github.com/misaka5202/Droidspaces-anland6-rootfs).

---

## End result

```
Android screen:
  ┌─────────────────────────┐
  │ root@hypr:~# █          │   <- Linux terminal
  │                         │
  │   (foot window 590x1217)│
  └─────────────────────────┘
  ESC  /  -  HOME ^ END PGUP ⌨
  TAB CTRL ALT <- v -> PGDN ⚙    <- anland keyboard bar
```

Verified rendering paths:

| Path | GL_RENDERER | FPS (glmark2 640x480) |
|------|-------------|:---:|
| Mesa llvmpipe | `llvmpipe (LLVM 21.1.8, 128 bits)` | 23~27 |
| **MobileGL -> Mali** | **`Espryt (MobileGL Core) (Mali-G720-Immortalis MC12, OpenGL ES 3.2)`** | 21~26 |

The two are close because the bottleneck is anland's software composition, not
GPU compute. MobileGL's value is that the **functional path is proven** and can
carry OpenGL 4.6 programs.

---

## Components

```
Android side
├── droidspaces-lkm module   8 .ko files: container caps + render node + cgroup emulation (see table)
├── anland-daemon module     display broker (5.x)
├── com.anland.consumer      display APK (5.x)
├── anlandproxy              root connection forwarder (works around KernelSU su restrictions, 5.x)
└── libMobileGLServer.so     Mali GPU render service (optional, for GPU acceleration)

Inside the container (Droidspaces)
├── Hyprland 0.55.2          Wayland compositor (anland backend)
├── /opt/mobilegl/           MobileGL client (glibc aarch64)
└── /run/display.sock        anland socket (5.x only)
```

### The 8 droidspaces-lkm modules

| Module | Purpose | CONFIG it stands in for |
|---|---|---|
| `lkm4ctr.ko` | namespace core | `PID_NS` / `UTS_NS` / `IPC_NS` / `SYSVIPC` / `POSIX_MQUEUE` |
| `devtmpfs_lkm.ko` | registers a devtmpfs filesystem | `DEVTMPFS` |
| `macvlan.ko` | per-container LAN IP | `MACVLAN` |
| `ip6table_nat.ko` | IPv6 NAT | `IP6_NF_NAT` / `IP6_NF_TARGET_MASQUERADE` |
| `vkms.ko` | virtual DRM device, provides the render node | `DRM_VKMS` (with the `DRIVER_RENDER` patch) |
| `droid_lkm_pids.ko` | emulated pids controller | `CGROUP_PIDS` |
| `droid_lkm_cpu.ko` | time-slice CPU quota | `CFS_BANDWIDTH` |
| `uart_guard.ko` | tty attribute read guard (kprobe) | none (guards a vendor `uart_get_info` lock bug) |

The last three are newer: `droid_lkm_pids` / `droid_lkm_cpu` make `--pids-limit`
and `--cpus` work; `uart_guard` guards a vendor-kernel defect in
`uart_get_info` / `console_show` around `port->mutex` — measured: reading
`/sys/class/tty/*/console` takes the device down.

---

## Prerequisite: the LKM

Flash the package for your KMI — `droidspaces-lkm-<kmi>-arm64.zip`, e.g.
`droidspaces-lkm-android14-6.1-arm64.zip` — then reboot.

**Do not guess the KMI.** 5.10 and 5.15 each have two generations sharing one
kernel version string (`android12-5.10` / `android13-5.10`,
`android13-5.15` / `android14-5.15`), and many vendor kernels strip the
`androidNN` tag out of `uname -r`. Check first:

```bash
getprop ro.board.first_api_level    # factory API level; OTA upgrades do not change it
```

| Value | Generation |
|---|---|
| 31 / 32 | android12 (5.10) |
| 33 | android13 (5.10 / 5.15) |
| 34 | android14 (5.15 / 6.1) |
| 35 / 36 / 37 | android15 / 16 / 17 |

The module reads this itself, and automatically retries the sibling generation
when one generation fails to insmod.

The boot log lives at **`/data/adb/droidspaces_lkm.log`** (not the old
`/data/local/tmp`) and should show:

```
[OK]   lkm4ctr  (lkm4ctr-android14-6.1.ko)
[OK]   devtmpfs_lkm  (devtmpfs_lkm-android14-6.1.ko) devtmpfs_probe=2
[OK]   ip6table_nat  (ip6table_nat-android14-6.1.ko)
[OK]   macvlan  (macvlan-android14-6.1.ko)
[OK]   vkms  (vkms-android14-6.1.ko)
[OK]   droid_lkm_pids  (droid_lkm_pids-android14-6.1.ko)
[OK]   droid_lkm_cpu  (droid_lkm_cpu-android14-6.1.ko)
[OK]   uart_guard  (uart_guard-android14-6.1.ko)
[OK] PID namespace
[OK] IPC namespace
[OK] devtmpfs
[OK] /dev/dri/renderD128 (vkms)
```

**`vkms` is the critical one.** Vendor kernels do not enable
`CONFIG_DRM_VKMS`, so there is only `card0` (the display controller) and no
render node. Hyprland / KWin Wayland backends hard-require a read-write DRM
render node:

```c
// the check inside hyprland-anland
[[ -r "$ANLAND_DRM_DEVICE" && -w "$ANLAND_DRM_DEVICE" ]] || die 'render node unavailable'
```

After `vkms.ko` loads:

```
crw-rw-rw- 1 root graphics 226,  1  card1        <- vkms display device
crw-rw-rw- 1 root graphics 226, 128  renderD128   <- render node
```

### Why vkms and not vgem

Mesa's GBM backend looks up the dri driver by DRM driver name. A full Mesa
install ships `vkms_dri.so` but **no** `vgem_dri.so`. With vgem, Hyprland stops
at:

```
DEBUG: openRenderNode got drm device /dev/dri/renderD128
CRIT : Couldn't open a gbm device            (OpenGL.cpp:351)
```

### The two vkms patches

**Patch one: `DRIVER_RENDER`.** Upstream vkms declares
`driver_features = MODESET|ATOMIC|GEM`, so `drm_dev_register()` never creates a
render minor:

```c
.driver_features = DRIVER_MODESET | DRIVER_ATOMIC | DRIVER_GEM |
                   DRIVER_RENDER,
```

> An earlier revision of this guide said to edit `extra/vkms/vkms_drv.c`.
> **That directory has been deleted** — `extra/vkms/` and `extra/vgem/` were
> never referenced by the build script and were dead code. `vkms` is now
> compiled from the **kernel tree's own** `drivers/gpu/drm/vkms` with the patch
> applied.

**Patch two: strip the CRC / DEBUG_FS dependency.** Upstream
`vkms_composer.c` calls `drm_crtc_add_crc_entry()`, which lives in
`drivers/gpu/drm/drm_debugfs_crc.o` — and that object is gated by
`drm-$(CONFIG_DEBUG_FS)` in the DRM Makefile. **GKI's `gki_defconfig` never
enables `DEBUG_FS`**, so the symbol does not exist at all:

```
insmod: failed to load vkms.ko: Unknown symbol drm_crtc_add_crc_entry (err -2)
```

`scripts/patch_vkms_debugfs.py` removes those call sites at build time. The
script is **tolerant per version**: if the target's vkms source has no such
code it counts as success (that is the 5.10 case); if it matches, the call is
rewritten; if it is present but does not match, the module is skipped rather
than force-patched.

---

## Step two: the anland components

```bash
# daemon (KernelSU module)
flash anland-daemon.zip, or unpack manually into /data/adb/modules/anland-daemon/

# display APK
adb install anland-v5.apk
```

Starting the daemon manually (for debugging):

```bash
su -c 'nohup /data/adb/modules/anland-daemon/display_daemon \
       /data/local/tmp/display_daemon.sock > /data/local/tmp/anland-daemon.log 2>&1 &'
```

---

## Step three: the container

### 3.1 Prepare the rootfs

Use the **Ubuntu-26-hyprland-Wayland** image from
`Goldzxcbug/Droidspaces-rootfs-Desktop-builder`:

```bash
su -c 'cd /data/local/Droidspaces/rootfs-ubuntu && \
       busybox tar xJf /sdcard/Download/Ubuntu-26-hyprland-*.tar.xz'
```

### 3.2 Fix the rootfs GPU configuration (critical)

That rootfs is preconfigured for Qualcomm Adreno, and `/etc/environment`
contains three fatal lines:

```ini
MESA_LOADER_DRIVER_OVERRIDE=kgsl
GALLIUM_DRIVER=kgsl
FD_FORCE_KGSL=1
```

A Mali device has no kgsl node and Mesa fails immediately. **Replace them:**

```ini
# rendering: vkms + swrast software rasterizer
MESA_LOADER_DRIVER_OVERRIDE=swrast
LIBGL_ALWAYS_SOFTWARE=1

# anland
ANLAND=1
ANLAND_SOCKET=/run/display.sock
ANLAND_DRM_DEVICE=/dev/dri/renderD128
ANLAND_PRESENT_BACKEND=legacy
ANLAND_SKIP_IMPLICIT_SYNC_WAIT=1
XWAYLAND_GBM_DEVICE=/dev/dri/renderD128

# wayland
XDG_SESSION_CLASS=user
XDG_SESSION_TYPE=wayland
XDG_CURRENT_DESKTOP=Hyprland
XDG_SESSION_DESKTOP=Hyprland
QT_QPA_PLATFORM=wayland
```

**`MESA_LOADER_DRIVER_OVERRIDE=swrast` is mandatory.** With only
`LIBGL_ALWAYS_SOFTWARE=1`, Mesa tries Zink and fails:

```
MESA: error: ZINK: vkEnumeratePhysicalDevices failed
MESA-EGL: warning: egl: failed to create dri2 screen
```

Measured comparison (Wayland-platform EGL):

| Configuration | Result |
|------|:---:|
| default | eglInitialize failed |
| `GALLIUM_DRIVER=llvmpipe` | eglInitialize failed |
| `MESA_LOADER_DRIVER_OVERRIDE=zink` | eglInitialize failed |
| **`MESA_LOADER_DRIVER_OVERRIDE=swrast`** | **EGL 1.5** |
| `MESA_LOADER_DRIVER_OVERRIDE=kms_swrast` | EGL 1.5 |
| `EGL_PLATFORM=gbm` | EGL 1.5 |

### 3.3 Create the container

```bash
su -c '/data/local/Droidspaces/bin/droidspaces --name=anland \
    --rootfs=/data/local/Droidspaces/rootfs-ubuntu \
    --anland --gpu --net=host \
    --init=/usr/lib/systemd/systemd start'
```

Success looks like:

```
[Anland] display socket bind-mounted to /run/display.sock
[GPU] Mirrored node: ./dev/dri/renderD128  (226:128)
Container 'anland' is running in background.
```

**Verify socket identity** (the inodes must match):

```bash
S=$(ls /data/local/Droidspaces/Net/anland-*.sock | head -1)
stat -c '%F inode=%i' "$S"
stat -c '%F inode=%i' /data/local/Droidspaces/rootfs-ubuntu/run/display.sock
# both must report "socket" and the same inode
```

If the container side is a `regular empty file`, the bind mount failed — **rebuild
the container cleanly**. A manual `mount --bind` turns the socket into a plain
file.

### 3.4 Start Hyprland

```bash
su -c '/data/local/Droidspaces/bin/droidspaces --name=anland run -- /bin/sh /root/hnx.sh'
```

Script contents (`/root/hnx.sh`):

```sh
#!/bin/sh
export XDG_RUNTIME_DIR=/run/user/1000
mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
export ANLAND=1
export ANLAND_SOCKET=/run/display.sock
export ANLAND_DRM_DEVICE=/dev/dri/renderD128
export XDG_SESSION_TYPE=wayland
export XDG_CURRENT_DESKTOP=Hyprland
export MESA_LOADER_DRIVER_OVERRIDE=swrast
export LIBGL_ALWAYS_SOFTWARE=1

pkill -9 -f Hyprland 2>/dev/null
pkill -9 -f Xwayland 2>/dev/null
sleep 2
rm -rf "$XDG_RUNTIME_DIR"/wayland-* "$XDG_RUNTIME_DIR"/hypr 2>/dev/null

nohup /usr/bin/Hyprland --i-am-really-stupid > /root/hx.log 2>&1 &
sleep 12
pgrep -a Hyprland | head -2
```

**Note `--i-am-really-stupid`**: Hyprland refuses to run as root without it.

**Xwayland must be disabled** (`/root/.config/hypr/hyprland.conf`):

```ini
xwayland {
    enabled = false
}
```

Otherwise Xwayland reports `(EE) failed to read Wayland events: Broken pipe`
and takes the compositor down with it.

---

## Step four: connect the app (anlandproxy)

### Why a proxy is needed

The anland daemon validates peers like this:

```c
// src/android/anland/display_daemon.c
if (hdr.type == CTRL_MSG_CONSUMER_HELLO)
    allowed = peer_is_root(fd);        // the consumer must be uid == 0
else if (hdr.type == CTRL_MSG_PRODUCER_HELLO)
    allowed = peer_in_container(fd);   // the producer must be in another PID namespace
```

But **KernelSU hides the `su` binary entirely from a normal app's mount
namespace**:

```
app namespace: mnt:[4026537016]
/system/bin has 433 files, but su is not among them
```

So the app's `use_root=true` probe fails:

```
W Anland: root socket probe failed:
          java.io.IOException: Cannot run program "su": error=2, No such file or directory
```

### The proxy approach

`anlandproxy` runs as root, listens on a path the app can reach, and forwards
to the real daemon. **It must pass SCM_RIGHTS-accompanying dmabuf fds through
verbatim.**

```bash
# build (NDK, static)
$NDK/toolchains/llvm/prebuilt/*/bin/aarch64-linux-android26-clang \
    -O2 -static -o anlandproxy anlandproxy.c

# deploy
adb push anlandproxy /data/local/tmp/
adb shell su -c 'chmod 755 /data/local/tmp/anlandproxy'

# start
su -c 'S=$(ls /data/local/Droidspaces/Net/anland-*.sock | head -1)
       nohup /data/local/tmp/anlandproxy /data/local/tmp/anland_bridge.sock "$S" \
             > /data/local/tmp/anlandproxy.log 2>&1 &'
```

The `anlandproxy.c` source is in this repository's history; the original lived
at `C:\nomount\wsl\anlandproxy.c` on the test machine.

### Configure the app

```bash
su -c 'cat > /data/data/com.anland.consumer/shared_prefs/anland_settings.xml <<EOF
<?xml version="1.0" encoding="utf-8" standalone="yes" ?>
<map>
    <int name="topapp_mode" value="1" />
    <boolean name="use_root" value="false" />
    <string name="socket_path">/data/local/tmp/anland_bridge.sock</string>
</map>
EOF
chown u0_a437:u0_a437 /data/data/com.anland.consumer/shared_prefs/anland_settings.xml'
```

`use_root=false` plus a custom `socket_path` pointing at the proxy.

### Success indicators

Daemon log (`/data/local/Droidspaces/Logs/anland/anland`):

```
daemon: listening on /data/local/Droidspaces/Net/anland-<hash>.sock
daemon: producer connected
daemon: consumer connected
daemon: consumer deposited 5 fds
daemon: fds delivered to producer        <- handshake complete
daemon: screen info 1264x2517 fmt=1
```

On the Hyprland side:

```
Monitor ANLAND-1 (ID 0): 1264x2517@60.00000 at 0x0
	description: Anland Consumer
```

---

## Step five: launch applications

**Use shm-rendering apps, not EGL.**

`alacritty` / `kitty` create their surface through EGL and fail with
`failed to create dri2 screen`. Use `foot` (pure shm):

```bash
su -c 'apt-get install -y foot'

# launch (inherits the Hyprland environment)
su -c '/data/local/Droidspaces/bin/droidspaces --name=anland run -- /bin/sh -c "
  export XDG_RUNTIME_DIR=/run/user/1000
  export HYPRLAND_INSTANCE_SIGNATURE=$(ls /run/user/1000/hypr/ | head -1)
  hyprctl dispatch exec foot
"'
```

Verify:

```bash
hyprctl clients    # should show the foot window as mapped:1 visible:1 monitor:0
```

---

## Optional: MobileGL GPU acceleration

Translate the container's OpenGL to the Android-side Mali GPU.

### Build the Android side (Mali render service)

```bash
cd MobileGL
git submodule update --init --depth=1 --recursive
(cd 3rdparty/glslang && python update_glslang_sources.py)

cmake -S . -B build-android -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK/build/cmake/android.toolchain.cmake \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-26 \
  -DCMAKE_BUILD_TYPE=Release \
  -DMOBILEGL_BUILD_DISAGGREGATED=ON -DMOBILEGL_BUILD_DISAGGREGATED_INPROC=ON \
  -DMOBILEGL_BUILD_TEST=OFF -DMOBILEGL_BUILD_BENCHMARK=OFF
cmake --build build-android --target MobileGL MobileGLServer -j 8

# strip (341MB -> 18MB)
llvm-strip --strip-unneeded libMobileGL.so
```

### Start the server (TCP mode)

```bash
su -c 'cd /data/local/tmp && setsid env -u MOBILEGL_TRANSPORT \
  -u MOBILEGL_IPC_SERVER_PATH -u MOBILEGL_IPC_RING_MB -u MOBILEGL_IPC_STAGE_MB \
  MOBILEGL_IPC_DIAL=no \
  MOBILEGL_IPC_TOKEN=anland-mobilegl-token-2026 \
  MOBILEGL_BACKEND_TYPE=DirectGLES \
  LD_LIBRARY_PATH=/data/local/tmp \
  ./libMobileGLServer.so tcp://0.0.0.0:40613 --serve \
  > /data/local/tmp/mgl_server.log 2>&1 &'
```

Verify it is listening:

```bash
netstat -tlnp | grep 40613
# tcp 0 0 0.0.0.0:40613 LISTEN <pid>/libMobileGLServer.so
```

### Build the glibc client inside the container

**Compile natively inside the container** (it is already aarch64 glibc, so the
match is automatic):

```bash
su -c '/data/local/Droidspaces/bin/droidspaces --name=anland run -- /bin/sh -c "
  apt-get install -y build-essential cmake ninja-build \
      libgbm-dev libegl-dev libgles-dev libvulkan-dev mesa-common-dev
  cd /opt/mobilegl
  cmake -S . -B build-client -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DMOBILEGL_BUILD_DISAGGREGATED=ON \
      -DMOBILEGL_BUILD_TEST=OFF -DMOBILEGL_BUILD_BENCHMARK=OFF
  cmake --build build-client --target MobileGL -j 6
"'
```

Output: `/opt/mobilegl/build-client/libMobileGL.so` (22 MB) plus `libEGL.so` /
`libGL.so` symlinks.

### Verify

```bash
export MOBILEGL_TRANSPORT=spawn
export MOBILEGL_IPC_CONTROL=tcp://127.0.0.1:40613
export MOBILEGL_IPC_TOKEN=anland-mobilegl-token-2026
export __EGL_VENDOR_LIBRARY_FILENAMES=/opt/mobilegl/build-client/libEGL.so
export LD_LIBRARY_PATH=/opt/mobilegl/build-client

glmark2-es2-wayland --size=640x480 -b :duration=3
```

Expected output:

```
GL_RENDERER: Espryt (MobileGL Core) (Mali-G720-Immortalis MC12, OpenGL ES 3.2)
GL_VERSION:  4.6.0 MobileGL 26.11-dev, Direct (GLES) Backend
```

### MobileGL build traps

| Problem | Fix |
|------|------|
| empty submodules | `git submodule update --init --recursive` |
| `SPIR-V tools not found` | `cd 3rdparty/glslang && python update_glslang_sources.py` |
| `MG_Gbm not existing directory` | do not drop `MobileGL/MG_Gbm` when packaging sources |
| missing `MobileGL/Init.cpp` | do not drop the root-level `MobileGL/*.cpp` files |
| missing `glvnd/libeglabi.h` | do not drop `3rdparty/glvnd` |
| `mobilegl_gbm.so` not generated | needs `gbm_backend_abi.h` (not in stock libgbm-dev); safe to ignore |

---

## Troubleshooting

### A module will not load / the device hangs at boot

Look at the log and the state directory (both exist since recent versions):

```bash
cat /data/adb/droidspaces_lkm.log            # persistent log, survives reboots (256KB rotation)
ls -l /data/adb/droidspaces_lkm.d/           # snapshots, breadcrumb, blacklist
cat /data/adb/droidspaces_lkm.d/loading      # which module was loading when we died
cat /data/adb/droidspaces_lkm.d/blacklist    # modules automatically blacklisted
cat /data/adb/droidspaces_lkm.d/hang-report.txt   # state snapshot from the last 15s before a hang
```

**The breadcrumb mechanism:** `service.sh` writes the module name into
`loading` and `sync`s before every `insmod`, and deletes it on success. If the
next boot still finds it, the previous boot died **while loading that named
module** — it is appended to `blacklist` and skipped from then on, so the user
does not have to keep rebooting to find out.

**The boot guard:** after three consecutive boots that never reach
`boot-completed.sh`, the module disables itself and leaves a `disable` file.
This is the last line of defence against "reboot -> hang again -> infinite
loop".

If `service.sh` did not even write a log (the `droidspaces_lkm.d/` directory is
empty), the hang happened after `post-fs-data` but before `late_start`, i.e.
**our modules were never loaded**. The problem is then another module or the
kernel itself, not this one. Confirming takes one boot in safe mode with only
this module enabled.

### The container exits immediately

```bash
# look at the monitor log
tail -20 /data/local/Droidspaces/Logs/<name>/log
```

If you see `Monitor performing cleanup` followed by
`Container is running in background`, systemd exited. Check the kgsl lines in
`/etc/environment`.

### The socket is a plain file inside the container

```bash
stat -c '%F %i' rootfs/run/display.sock     # expect "socket"
```

If it is not a socket, **rebuild the container cleanly** — a manual bind mount
will not help.

### Hyprland crashes

```bash
grep -aE 'CRIT|ASSERTION|Couldn' /root/hx.log
```

Common causes:
- `Couldn't open a gbm device` -> use vkms rather than vgem, and add `DRIVER_RENDER`
- `ZINK: vkEnumeratePhysicalDevices failed` -> set `MESA_LOADER_DRIVER_OVERRIDE=swrast`
- Lua config syntax errors -> delete `/root/.config/hypr/hyprland.lua`

### The app keeps opening its settings page

```bash
logcat -d -s Anland:*
```

`root socket probe failed: Cannot run program "su"` -> use the anlandproxy
approach.

### EGL initialisation fails

```
eglInitialize failed with error 0x3001
```

Wayland-platform EGL needs `MESA_LOADER_DRIVER_OVERRIDE=swrast`; setting only
`LIBGL_ALWAYS_SOFTWARE=1` is not enough.

---

## Known limitations

| Item | Status | Notes |
|---|---|---|
| CPU limit (`--cpus`) | supported | emulated by `droid_lkm_cpu.ko` (time slice + SIGSTOP/SIGCONT); no `CONFIG_CFS_BANDWIDTH` needed |
| Process limit (`--pids-limit`) | supported | emulated by `droid_lkm_pids.ko`; no `CONFIG_CGROUP_PIDS` needed |
| Sandboxing (`--allow-sandboxing`) | unsupported | needs the `CONFIG_USER_NS` core path |
| GPU acceleration benefit | partial | the MobileGL path works, but the bottleneck is anland composition |
| Audio | untested | anland has an audio channel; not tested |
| Input methods | untested | fcitx5 configured, Chinese input not tested |

> **Additional condition for `--pids-limit` / `--cpus`:** the emulated cftypes
> hang off cgroup v2, so the container must **also set `--memory`** (that is what
> creates a dedicated cgroup). Without it the limits do not take effect.
>
> Earlier revisions of this guide marked both as "requires a kernel rebuild".
> That was true before `droid_lkm_pids` / `droid_lkm_cpu` existed and is no
> longer the case.

---

## Test device

The environment used for everything in this guide:

```
Device:     arm64 Android device (bootloader locked)
SoC:        MediaTek MT6989 (ARM Mali GPU)
GPU:        Mali-G720-Immortalis MC12
Kernel:     6.1.157-android14-11-o-g2d576b643492
KMI:        android14-6.1
Bootloader: locked (verifiedbootstate=green, flash.locked=1)
Root:       KernelSU (LKM mode)
```

**These numbers are only valid for this 6.1 / MediaTek device.** Support for
5.10 / 5.15 / 6.6 / 6.12 is built and verified per KMI, but the anland flow in
this guide has not been exercised on real hardware for those.

---

## References

- [anland](https://github.com/SuperTurtleDev/anland) — display protocol (both 5.x and 6.x live here)
- [anland-shell](https://github.com/SuperTurtleDev/anland-shell) — 6.x container/app management
- [Droidspaces](https://github.com/ravindu644/Droidspaces-OSS) — container runtime
- [Droidspaces anland docs](https://www.droidspaces.org/docs/anland.html)
- [Desktop-builder](https://github.com/Goldzxcbug/Droidspaces-rootfs-Desktop-builder) — rootfs (5.x desktop matrix)
- [Droidspaces-anland6-rootfs](https://github.com/misaka5202/Droidspaces-anland6-rootfs) — 6.x image builder (Qualcomm + MediaTek, Chinese)
- [MobileGL](https://github.com/MobileGL-Dev/MobileGL) — OpenGL translation
- [droidspaces-lkm](https://github.com/misaka5202/droidspaces-lkm) — the LKM (this project)