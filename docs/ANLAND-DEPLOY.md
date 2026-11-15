# anland Linux 桌面部署手册

[English](ANLAND-DEPLOY.en.md) | **简体中文**

在 **ARM Mali 平台（G720 级 GPU）** 上运行 Linux 桌面，
画面通过 anland 显示在 Android 屏幕上。

本文档记录的是**实际验证过的步骤**，每一条都有对应的实测证据。
适用前提：不想重编内核，只能靠 LKM 补能力。

---

## 先读这里：本文档讲的是 anland 5.x

anland 有两代，容器侧的部署方式**完全不同**，别混着看：

| | **5.x**（本文档） | **6.x** |
|---|---|---|
| 显示协议 | 私有 Anland Display Protocol | **Wayland 本身** |
| 合成器 | 必须**打过补丁的合成器**（如 Hyprland/KWin 的 anland backend） | **stock 合成器不用改** |
| 连接方式 | `/run/display.sock` + bind mount | binder 传 fd，**没有 socket 文件** |
| 窗口 | 整块屏幕投到一个 Android 窗口 | **每个窗口一个真正的 Android 窗口** |
| 容器内组件 | 无（靠 patched 合成器） | `anlandx` 会话（wayland 链接 + rootless Xwayland + mini-wm） |
| 宿主产物 | `anland-daemon.zip` + `anland-v5.apk`（`com.anland.consumer`） | `module/anland-awl.zip` + `anland-wayland.apk` + `anlandx.tar.gz` |

**5.x 的痛点**：那个 patched 合成器并不在公开的 `anland-kde-packages` 里。
实测装了那批 deb 之后，`kwin_wayland` 二进制里一个 anland 字样都没有 —— 会话起来了、
合成器也在跑，但画面没有出口，用户看到的就是黑屏。

**6.x 绕开了这个死胡同**：把 Wayland 本身做成帧交换协议，宿主侧 `waylandbridge`
（KernelSU 模块 `anland-awl`）通过 binder 把每个 `xdg_toplevel` 变成真正的
Android 窗口，所以 stock 合成器不用改。

如果你是 **Mali / MTK 设备且拿不到 patched 合成器**，优先考虑 6.x 路线。
本仓库配套的 6.x 镜像构建器：
[`misaka5202/Droidspaces-anland6-rootfs`](https://github.com/misaka5202/Droidspaces-anland6-rootfs)。

---

## 最终效果

```
Android 屏幕显示:
  ┌─────────────────────────┐
  │ root@hypr:~# █          │   ← Linux 终端
  │                         │
  │   (foot 窗口 590x1217)   │
  └─────────────────────────┘
  ESC  /  -  HOME ↑ END PGUP ⌨
  TAB CTRL ALT ← ↓ → PGDN ⚙    ← anland 键盘条
```

已验证的渲染方式：
| 方式 | GL_RENDERER | FPS (glmark2 640x480) |
|------|-------------|:---:|
| Mesa llvmpipe | `llvmpipe (LLVM 21.1.8, 128 bits)` | 23~27 |
| **MobileGL → Mali** | **`Espryt (MobileGL Core) (Mali-G720-Immortalis MC12, OpenGL ES 3.2)`** | 21~26 |

两者 FPS 接近，因为瓶颈在 anland 的软件合成而非 GPU 计算。
MobileGL 的价值在于**功能通路已验证**，可承载 OpenGL 4.6 程序。

---

## 组成部分

```
Android 侧
├── droidspaces-lkm 模块     8 个 ko：容器能力 + render node + cgroup 仿真（见下表）
├── anland-daemon 模块       显示 broker（5.x）
├── com.anland.consumer      显示端 APK（5.x）
├── anlandproxy              root 连接转发（绕开 KernelSU su 限制，5.x）
└── libMobileGLServer.so     Mali GPU 渲染服务（可选，GPU 加速用）

容器内（Droidspaces）
├── Hyprland 0.55.2          Wayland 合成器（anland backend）
├── /opt/mobilegl/           MobileGL 客户端（glibc aarch64）
└── /run/display.sock        anland socket（5.x 才有）
```

### droidspaces-lkm 的 8 个模块

| 模块 | 作用 | 补齐的 CONFIG |
|---|---|---|
| `lkm4ctr.ko` | 命名空间核心 | `PID_NS` / `UTS_NS` / `IPC_NS` / `SYSVIPC` / `POSIX_MQUEUE` |
| `devtmpfs_lkm.ko` | 注册 devtmpfs 文件系统 | `DEVTMPFS` |
| `macvlan.ko` | 容器独立局域网 IP | `MACVLAN` |
| `ip6table_nat.ko` | IPv6 NAT | `IP6_NF_NAT` / `IP6_NF_TARGET_MASQUERADE` |
| `vkms.ko` | 虚拟 DRM 设备，提供 render node | `DRM_VKMS`（含 `DRIVER_RENDER` 补丁） |
| `droid_lkm_pids.ko` | 仿真 pids 控制器 | `CGROUP_PIDS` |
| `droid_lkm_cpu.ko` | 时间片 CPU 配额 | `CFS_BANDWIDTH` |
| `uart_guard.ko` | tty 属性读取保护（kprobe） | 无（防厂商内核 `uart_get_info` 锁崩） |

后三个是较新版本才有的：`droid_lkm_pids` / `droid_lkm_cpu` 让 `--pids-limit` 和
`--cpus` 可用；`uart_guard` 防的是厂商内核在 `uart_get_info` / `console_show`
里对 `port->mutex` 的处理缺陷（实测读 `/sys/class/tty/*/console` 会把设备打挂）。

---

## 前置：LKM 模块

刷入对应 KMI 的 `droidspaces-lkm-<kmi>-arm64.zip`（例如
`droidspaces-lkm-android14-6.1-arm64.zip`），重启。

**KMI 别自己猜。** 5.10 / 5.15 各有两代共用同一个内核版本号
（`android12-5.10` 与 `android13-5.10`、`android13-5.15` 与 `android14-5.15`），
而不少厂商内核把 `androidNN` 字样从 `uname -r` 里去掉了。装之前确认：

```bash
getprop ro.board.first_api_level    # 出厂 API level，OTA 不会改它
```

| 值 | 代际 |
|---|---|
| 31 / 32 | android12（5.10） |
| 33 | android13（5.10 / 5.15） |
| 34 | android14（5.15 / 6.1） |
| 35 / 36 / 37 | android15 / 16 / 17 |

模块自己也会读这个属性，并且在一代 insmod 失败时自动换另一代重试。

开机日志在 **`/data/adb/droidspaces_lkm.log`**（不是旧版的 `/data/local/tmp`），
应显示：

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

**`vkms` 是关键。** 厂商内核没开 `CONFIG_DRM_VKMS`，只有 `card0`
（显示控制器）而没有 render node。Hyprland / KWin 的 Wayland 后端
硬性要求一个可读写的 DRM render node：

```c
// hyprland-anland 里的检查
[[ -r "$ANLAND_DRM_DEVICE" && -w "$ANLAND_DRM_DEVICE" ]] || die 'render node unavailable'
```

`vkms.ko` 加载后：

```
crw-rw-rw- 1 root graphics 226,  1  card1        ← vkms 显示设备
crw-rw-rw- 1 root graphics 226, 128  renderD128   ← render node
```

### 为什么是 vkms 而不是 vgem

Mesa 的 GBM 后端按 DRM driver 名字找 dri 驱动，完整安装的 Mesa 里有
`vkms_dri.so` 却**没有** `vgem_dri.so`。用 vgem 时 Hyprland 会停在：

```
DEBUG: openRenderNode got drm device /dev/dri/renderD128
CRIT : Couldn't open a gbm device            (OpenGL.cpp:351)
```

### vkms 的两个补丁

**补丁一：`DRIVER_RENDER`。** 上游 vkms 的 `driver_features` 只有
`MODESET|ATOMIC|GEM`，`drm_dev_register()` 不会为它创建 render minor：

```c
.driver_features = DRIVER_MODESET | DRIVER_ATOMIC | DRIVER_GEM |
                   DRIVER_RENDER,
```

> 早先这份文档说在 `extra/vkms/vkms_drv.c` 改。**那个目录已经删了** ——
> `extra/vkms/` 和 `extra/vgem/` 从未被构建脚本引用，是死代码。
> 现在 `vkms` 直接从**内核树自带**的 `drivers/gpu/drm/vkms` 编译并打补丁。

**补丁二：裁掉 CRC / DEBUG_FS 依赖。** 上游 `vkms_composer.c` 会调
`drm_crtc_add_crc_entry()`，而那个函数在 `drivers/gpu/drm/drm_debugfs_crc.o` 里，
`drm_debugfs_crc.o` 又由 `Makefile` 的 `drm-$(CONFIG_DEBUG_FS)` 门控 ——
**GKI 的 `gki_defconfig` 从不设 `DEBUG_FS`**，所以这个符号在 GKI 上根本不存在：

```
insmod: failed to load vkms.ko: Unknown symbol drm_crtc_add_crc_entry (err -2)
```

现在构建时用 `scripts/patch_vkms_debugfs.py` 把这几处调用裁掉。脚本是**按版本容忍**的：
目标内核的 vkms 源码里没有这段代码时算成功（5.10 就是），有且模式匹配才替换，
有但模式不符就跳过这个模块（不硬改）。

---

## 第二步：anland 组件

```bash
# daemon（KernelSU 模块）
刷 anland-daemon.zip，或手动解压到 /data/adb/modules/anland-daemon/

# 显示端 APK
adb install anland-v5.apk
```

手动启动 daemon（调试时）：

```bash
su -c 'nohup /data/adb/modules/anland-daemon/display_daemon \
       /data/local/tmp/display_daemon.sock > /data/local/tmp/anland-daemon.log 2>&1 &'
```

---

## 第三步：容器

### 3.1 准备 rootfs

用 `Goldzxcbug/Droidspaces-rootfs-Desktop-builder` 的
**Ubuntu-26-hyprland-Wayland** 版：

```bash
# 解压到 rootfs 目录
su -c 'cd /data/local/Droidspaces/rootfs-ubuntu && \
       busybox tar xJf /sdcard/Download/Ubuntu-26-hyprland-*.tar.xz'
```

### 3.2 修复 rootfs 的 GPU 配置（关键）

这个 rootfs 是给高通 Adreno 预配置的，`/etc/environment` 里有三行致命配置：

```ini
MESA_LOADER_DRIVER_OVERRIDE=kgsl
GALLIUM_DRIVER=kgsl
FD_FORCE_KGSL=1
```

Mali 设备没有 kgsl 节点，Mesa 直接失败。**必须替换**：

```ini
# 渲染: vkms + swrast 软件光栅化
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

**`MESA_LOADER_DRIVER_OVERRIDE=swrast` 是必须的。**
只设 `LIBGL_ALWAYS_SOFTWARE=1` 时 Mesa 会尝试 Zink 并失败：

```
MESA: error: ZINK: vkEnumeratePhysicalDevices failed
MESA-EGL: warning: egl: failed to create dri2 screen
```

实测对比（Wayland 平台 EGL）：

| 配置 | 结果 |
|------|:---:|
| 默认 | ❌ eglInitialize failed |
| `GALLIUM_DRIVER=llvmpipe` | ❌ eglInitialize failed |
| `MESA_LOADER_DRIVER_OVERRIDE=zink` | ❌ eglInitialize failed |
| **`MESA_LOADER_DRIVER_OVERRIDE=swrast`** | ✅ **EGL 1.5** |
| `MESA_LOADER_DRIVER_OVERRIDE=kms_swrast` | ✅ EGL 1.5 |
| `EGL_PLATFORM=gbm` | ✅ EGL 1.5 |

### 3.3 创建容器

```bash
su -c '/data/local/Droidspaces/bin/droidspaces --name=anland \
    --rootfs=/data/local/Droidspaces/rootfs-ubuntu \
    --anland --gpu --net=host \
    --init=/usr/lib/systemd/systemd start'
```

成功标志：

```
[Anland] display socket bind-mounted to /run/display.sock
[GPU] Mirrored node: ./dev/dri/renderD128  (226:128)
Container 'anland' is running in background.
```

**验证 socket 一致性**（必须 inode 相同）：

```bash
S=$(ls /data/local/Droidspaces/Net/anland-*.sock | head -1)
stat -c '%F inode=%i' "$S"
stat -c '%F inode=%i' /data/local/Droidspaces/rootfs-ubuntu/run/display.sock
# 两者必须都是 socket 且 inode 相同
```

如果容器内是 `regular empty file`，说明 bind mount 失败——**必须干净重建容器**，
手动 `mount --bind` 会把 socket 变成普通文件。

### 3.4 启动 Hyprland

```bash
su -c '/data/local/Droidspaces/bin/droidspaces --name=anland run -- /bin/sh /root/hnx.sh'
```

脚本内容（`/root/hnx.sh`）：

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

**注意 `--i-am-really-stupid`**：Hyprland 默认拒绝以 root 运行。

**必须关掉 Xwayland**（`/root/.config/hypr/hyprland.conf`）：

```ini
xwayland {
    enabled = false
}
```

否则 Xwayland 报 `(EE) failed to read Wayland events: Broken pipe` 后带崩合成器。

---

## 第四步：连接 app（关键：anlandproxy）

### 为什么需要代理

anland daemon 的校验逻辑：

```c
// src/android/anland/display_daemon.c
if (hdr.type == CTRL_MSG_CONSUMER_HELLO)
    allowed = peer_is_root(fd);        // consumer 必须 uid == 0
else if (hdr.type == CTRL_MSG_PRODUCER_HELLO)
    allowed = peer_in_container(fd);   // producer 必须在不同 PID namespace
```

而 **KernelSU 从普通 app 的 mount namespace 完全隐藏了 `su` 二进制**：

```
app 的 namespace: mnt:[4026537016]
/system/bin 有 433 个文件，但 su 不在！
```

app 的 `use_root=true` 探测因此失败：

```
W Anland: root socket probe failed:
          java.io.IOException: Cannot run program "su": error=2, No such file or directory
```

### 代理方案

`anlandproxy` 以 root 运行，监听 app 能访问的路径，转发到真 daemon。
**关键：必须原样转发 SCM_RIGHTS 附带 dmabuf fd。**

```bash
# 编译（NDK，静态）
$NDK/toolchains/llvm/prebuilt/*/bin/aarch64-linux-android26-clang \
    -O2 -static -o anlandproxy anlandproxy.c

# 部署
adb push anlandproxy /data/local/tmp/
adb shell su -c 'chmod 755 /data/local/tmp/anlandproxy'

# 启动
su -c 'S=$(ls /data/local/Droidspaces/Net/anland-*.sock | head -1)
       nohup /data/local/tmp/anlandproxy /data/local/tmp/anland_bridge.sock "$S" \
             > /data/local/tmp/anlandproxy.log 2>&1 &'
```

`anlandproxy.c` 源码见 `C:\nomount\wsl\anlandproxy.c`。

### 配置 app

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

`use_root=false` + 自定义 `socket_path` 指向代理。

### 成功标志

daemon 日志（`/data/local/Droidspaces/Logs/anland/anland`）：

```
daemon: listening on /data/local/Droidspaces/Net/anland-<hash>.sock
daemon: producer connected
daemon: consumer connected
daemon: consumer deposited 5 fds
daemon: fds delivered to producer        ← 握手完成
daemon: screen info 1264x2517 fmt=1
```

Hyprland 侧：

```
Monitor ANLAND-1 (ID 0): 1264x2517@60.00000 at 0x0
	description: Anland Consumer
```

---

## 第五步：启动应用

**用 shm 渲染的应用，不要用 EGL。**

`alacritty` / `kitty` 通过 EGL 创建 surface，会因 `failed to create dri2 screen`
失败。改用 `foot`（纯 shm）：

```bash
su -c 'apt-get install -y foot'

# 启动（继承 Hyprland 环境）
su -c '/data/local/Droidspaces/bin/droidspaces --name=anland run -- /bin/sh -c "
  export XDG_RUNTIME_DIR=/run/user/1000
  export HYPRLAND_INSTANCE_SIGNATURE=$(ls /run/user/1000/hypr/ | head -1)
  hyprctl dispatch exec foot
"'
```

验证：

```bash
hyprctl clients    # 应显示 foot 窗口 mapped:1 visible:1 monitor:0
```

---

## 可选：MobileGL GPU 加速

把容器内的 OpenGL 转译到 Android 侧的 Mali GPU。

### 编译 Android 版（Mali 渲染服务）

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

# strip（341MB → 18MB）
llvm-strip --strip-unneeded libMobileGL.so
```

### 启动 server（TCP 模式）

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

验证监听：

```bash
netstat -tlnp | grep 40613
# tcp 0 0.0.0.0:40613 LISTEN <pid>/libMobileGLServer.so
```

### 编译容器内 glibc 客户端

**在容器内原生编译**（容器本身就是 aarch64 glibc，天然匹配）：

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

产物：`/opt/mobilegl/build-client/libMobileGL.so`（22 MB）+
`libEGL.so` / `libGL.so` 软链接。

### 验证

```bash
export MOBILEGL_TRANSPORT=spawn
export MOBILEGL_IPC_CONTROL=tcp://127.0.0.1:40613
export MOBILEGL_IPC_TOKEN=anland-mobilegl-token-2026
export __EGL_VENDOR_LIBRARY_FILENAMES=/opt/mobilegl/build-client/libEGL.so
export LD_LIBRARY_PATH=/opt/mobilegl/build-client

glmark2-es2-wayland --size=640x480 -b :duration=3
```

期望输出：

```
GL_RENDERER: Espryt (MobileGL Core) (Mali-G720-Immortalis MC12, OpenGL ES 3.2)
GL_VERSION:  4.6.0 MobileGL 26.11-dev, Direct (GLES) Backend
```

### 编译 MobileGL 的坑

| 问题 | 解法 |
|------|------|
| 子模块为空 | `git submodule update --init --recursive` |
| `SPIR-V tools not found` | `cd 3rdparty/glslang && python update_glslang_sources.py` |
| `MG_Gbm not existing directory` | 打包源码时别漏 `MobileGL/MG_Gbm` |
| `MobileGL/Init.cpp` 缺失 | 别漏 `MobileGL/*.cpp` 根目录文件 |
| `glvnd/libeglabi.h` 缺失 | 别漏 `3rdparty/glvnd` |
| `mobilegl_gbm.so` 未生成 | 需 `gbm_backend_abi.h`（不在标准 libgbm-dev 里），可忽略 |

---

## 故障排查

### 模块装不上 / 开机卡住

先看日志和状态目录（新版本才有这套）：

```bash
cat /data/adb/droidspaces_lkm.log            # 持久日志（跨重启保留，256KB 轮转）
ls -l /data/adb/droidspaces_lkm.d/           # 快照、面包屑、黑名单都在这里
cat /data/adb/droidspaces_lkm.d/loading      # 上次死在加载哪个模块上
cat /data/adb/droidspaces_lkm.d/blacklist    # 已自动拉黑的模块
cat /data/adb/droidspaces_lkm.d/hang-report.txt   # 卡死前最后 15 秒的状态快照
```

**面包屑机制**：`service.sh` 在每个 `insmod` 前把模块名写进 `loading` 并
`sync`，成功后删掉。下次开机发现它还在，就说明上次是在加载**那个具名模块**时
死的 —— 直接写进 `blacklist` 以后跳过，不再让用户反复重启去试。

**开机保护**：连续 3 次开机没走到 `boot-completed.sh`，模块自动禁用自己并留下
`disable` 文件。这是防"重启 → 再次卡死 → 无限循环"的最后一道闸。

如果 `service.sh` 连日志都没写（`droidspaces_lkm.d/` 是空目录），说明卡死发生在
`post-fs-data` 之后、`late_start` 之前，那时我们的模块**还没加载** —— 问题在
别的模块或内核本身，不在这个模块。用安全模式只留这个模块再开一次即可确认。

### 容器一启动就退出

```bash
# 看 monitor 日志
tail -20 /data/local/Droidspaces/Logs/<name>/log
```

如果看到 `Monitor performing cleanup` 紧跟 `Container is running in background`，
说明 systemd 退出了。检查 `/etc/environment` 的 kgsl 配置。

### socket 在容器内是普通文件

```bash
stat -c '%F %i' rootfs/run/display.sock     # 期望 socket
```

不是 socket 就**干净重建容器**，手动 bind mount 无效。

### Hyprland 崩溃

```bash
grep -aE 'CRIT|ASSERTION|Couldn' /root/hx.log
```

常见原因：
- `Couldn't open a gbm device` → 用 vkms 而非 vgem，并加 `DRIVER_RENDER`
- `ZINK: vkEnumeratePhysicalDevices failed` → 设 `MESA_LOADER_DRIVER_OVERRIDE=swrast`
- Lua 配置语法错误 → 删掉 `/root/.config/hypr/hyprland.lua`

### app 一直跳设置页

```bash
logcat -d -s Anland:*
```

`root socket probe failed: Cannot run program "su"` → 用 anlandproxy 方案。

### EGL 初始化失败

```
eglInitialize failed with error 0x3001
```

Wayland 平台 EGL 需要 `MESA_LOADER_DRIVER_OVERRIDE=swrast`，
只设 `LIBGL_ALWAYS_SOFTWARE=1` 不够。

---

## 已知限制

| 项 | 状态 | 说明 |
|---|---|---|
| CPU limit (`--cpus`) | ✅ | 由 `droid_lkm_cpu.ko` 仿真（时间片 + SIGSTOP/SIGCONT），不再需要 `CONFIG_CFS_BANDWIDTH` |
| Process limit (`--pids-limit`) | ✅ | 由 `droid_lkm_pids.ko` 仿真，不再需要 `CONFIG_CGROUP_PIDS` |
| Sandboxing (`--allow-sandboxing`) | ❌ | 需 `CONFIG_USER_NS` 核心路径 |
| GPU 加速收益 | ⚠️ | MobileGL 通路可用，但瓶颈在 anland 合成 |
| 音频 | 未验证 | anland 有音频通道，未测试 |
| 输入法 | 未验证 | fcitx5 已配置，未测试中文输入 |

> **`--pids-limit` / `--cpus` 的附加条件**：两项仿真的 cftype 挂在 cgroup v2
> 上，容器必须**同时设 `--memory`**（它才会创建独立的 cgroup），否则限额不生效。
>
> 早期文档把这两项标成 ❌「需内核重新编译」，那是 `droid_lkm_pids` /
> `droid_lkm_cpu` 出现之前的情况，已经不成立了。

---

## 关键设备信息

本文档的实测环境：

```
设备:       arm64 Android 设备（bootloader 锁定）
SoC:        MediaTek MT6989（ARM Mali GPU）
GPU:        Mali-G720-Immortalis MC12
内核:       6.1.157-android14-11-o-g2d576b643492
KMI:        android14-6.1
bootloader: 锁定 (verifiedbootstate=green, flash.locked=1)
Root:       KernelSU（LKM 模式）
```

**这份信息只对 6.1 / MTK 这一台负责。** 5.10 / 5.15 / 6.6 / 6.12 的支持是
按 KMI 分别编译验证的，但没有在真机上跑过本文档的 anland 流程。

---

## 参考

- [anland](https://github.com/SuperTurtleDev/anland) — 显示协议（**5.x 和 6.x 都在这个仓库**）
- [anland-shell](https://github.com/SuperTurtleDev/anland-shell) — 6.x 的容器/应用管理
- [Droidspaces](https://github.com/ravindu644/Droidspaces-OSS) — 容器
- [Droidspaces 官方 anland 文档](https://www.droidspaces.org/docs/anland.html)
- [Desktop-builder](https://github.com/Goldzxcbug/Droidspaces-rootfs-Desktop-builder) — rootfs（5.x 桌面矩阵）
- [Droidspaces-anland6-rootfs](https://github.com/misaka5202/Droidspaces-anland6-rootfs) — 6.x 专用镜像构建器（高通 / MTK 双版本，中文）
- [MobileGL](https://github.com/MobileGL-Dev/MobileGL) — OpenGL 转译
- [droidspaces-lkm](https://github.com/misaka5202/droidspaces-lkm) — LKM 模块（本项目）
