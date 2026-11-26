# Droidspaces LKM

> **树外内核模块，补回厂商 GKI 内核编译掉的容器设施**——PID/IPC namespace、
> devtmpfs、macvlan、IPv6 NAT，以及配置路径被删时仿真 pids/cpu cgroup 控制器。
> 按 KMI 从对应厂商源码树构建，开机按 `uname -r` + `ro.board.first_api_level`
> 选版：一份模块覆盖 **7 个 KMI**，无需重编内核。

> [![Build](https://github.com/misaka5202/droidspaces-lkm/actions/workflows/build.yml/badge.svg)](https://github.com/misaka5202/droidspaces-lkm/actions/workflows/build.yml)

> [**English**](README.md) | **简体中文**

---

## 用户文档

| 文档 | 内容 |
|------|------|
| [Releases](../../releases/latest) | 预览版下载：合并包 + 分 KMI 包 + 源码快照 |
| [KMI 覆盖矩阵](docs/KMI-COVERAGE.md) | 每个 KMI 的构建矩阵与构建陷阱 |
| [桌面与 Anland 部署指南](docs/ANLAND-DEPLOY.md) | Wayland 桌面部署、失败对照表、容器 tmpfs 限制 |
| [Mali 命名空间修复](extra/mali_nsfix/README.zh-CN.md) | 机制、实测数据、干跑诊断 |
| [cgroup 限制](extra/cgrouplimits/README.md) | pids/cpu 仿真的保证与限制 |
| [Changelog](docs/CHANGELOG.md) | 每个版本修了什么（中文维护，每条开头一行摘要） |
| [新建 issue](https://github.com/misaka5202/droidspaces-lkm/issues/new/choose) | 表单会直接要够区分"构建问题"和"环境不匹配"的数据 |
| [Droidspaces](https://github.com/ravindu644/Droidspaces-OSS) | 本模块服务的容器应用 |
| [5.x RootFS 构建仓库](https://github.com/misaka5202/Droidspaces-rootfs-Desktop-builder) | 自带合成器的桌面镜像（vkms 路线） |
| [6.x Anland RootFS](https://github.com/misaka5202/droidspaces-anland6-rootfs) | anland 6.x 镜像（mali_nsfix 路线） |

> [!IMPORTANT]
> **还没有正式版本**——本仓库目前发布的每一个 tag 都是 GitHub
> **pre-release（预览版）**。请把它当作"拿来试一试、有问题反馈"的构建，而不是
> 可以依赖的版本；等 inline 钩子后端在七个 KMI 上跑完真机回归才会打第一个正式版。
> `update.json` 只在「这次发布要让 KernelSU 更新器推给用户」时才改，由发布工作流
> 自动生成（当前同步到 v0.1.27）。

---

## 1. 模块

| 模块 | 作用 | 补齐的 CONFIG | 开机自启 |
|------|------|---------------|:---:|
| `lkm4ctr.ko` | 命名空间核心 | `PID_NS` / `UTS_NS` / `IPC_NS` / `SYSVIPC` / `POSIX_MQUEUE` | ✅ |
| `devtmpfs_lkm.ko` | 注册 devtmpfs 文件系统 | `DEVTMPFS` | ✅ |
| `macvlan.ko` | 容器独立局域网 IP | `MACVLAN` | ✅ |
| `ip6table_nat.ko` | IPv6 NAT | `IP6_NF_NAT` / `IP6_NF_TARGET_MASQUERADE` | ✅ |
| `vkms.ko` | 虚拟 DRM 设备，提供 render node | `DRM_VKMS`（含 `DRIVER_RENDER` 补丁） | ⭕ |
| `droid_lkm_pids.ko` | 仿真 pids 控制器 | `CGROUP_PIDS` | ✅ |
| `droid_lkm_cpu.ko` | 时间片 CPU 配额 | `CFS_BANDWIDTH` | ✅ |
| `uart_guard.ko` | tty 属性读取保护（kprobe） | 无（防厂商内核 `uart_get_info` 锁崩） | ✅ |
| `mali_nsfix.ko` | 重定向 `mali_kbase` 的 pid 查找，使 GPU context 能在 PID 命名空间内创建 | 无（补驱动的一处假设，见[它的说明](extra/mali_nsfix/README.zh-CN.md)） | 🔵 |

自动加载标记：✅ 开机加载 · 🔵 仅 Mali 平台开机加载 · ⭕ 默认不加载，
需在模块目录创建 `enable_vkms` 才装。

**九个里有八个开机加载**（带平台条件，见下），`vkms` 是例外、需要显式开启。
三个补充模块（`droid_lkm_pids` / `droid_lkm_cpu` / `uart_guard`）排在最后，
不会挡住前面五个：它们失败时设备照常开机、照常跑容器，只是少了对应的限额或
tty 保护。想少加载几个模块，用 WebUI 的**模块**页逐模块开关（写入 `ko_switch`，见
1.2 节）；或在模块目录放 `disable_pids` / `disable_cpu` /
`disable_uart_guard` / `disable_mali` 文件；放 `mali_nsfix_dryrun` 则以
不挂钩的干跑模式（`nshf_activate=0`）加载 mali_nsfix，用于预检。

### 1.1 按平台条件加载的模块

`mali_nsfix` 在 Mali 平台上自动加载，其余平台跳过。判断依据是设备实际报告的
状态，不是厂商名列表。

> [!IMPORTANT]
> **本表的 Android 版本说的是内核模块（KMI）那一侧**，与 anland6 用户态无关：
> anland6 的 `waylandbridge` 需要 **Android 14（API 34）+**（`ANativeWindow_readFromParcel`
> 是 API 34 才引入的符号，Android 13 上 daemon 加载失败）。
> 详见 <https://github.com/misaka5202/Droidspaces-anland6-rootfs#support-matrix>。

`vkms` / `mali_nsfix` 的加载组合由 `module/route` 决定（见[第 5 节](#5-显示路由eroute)）。
在 `auto` 下，`vkms` 默认不加载：它提供 `/dev/dri/renderD128`，背后没有 GPU——Mesa
只能回退到 llvmpipe（CPU 软件渲染）。它服务的是**自带标准 Wayland 合成器的桌面
镜像**（Anland 5.x 路线：KDE Plasma / KDE Plasma Mobile / GNOME / Hyprland /
Niri / Mango / Denial，镜像环境里带 `ANLAND_DRM_DEVICE=/dev/dri/renderD128`）：
Mali 厂商驱动只给 `/dev/mali0`，没有 DRM render node，这类镜像不开 `vkms`
合成器会直接拒绝启动（日志例：`kwin_backend_anland: no usable DRM render
device; cannot bring up OpenGL compositing`）。

**Anland 6.x 的 `waylandbridge` 会话不受此限制**：本机实测（OPPO PHZ110 /
MT6989 / 6.1.157）卸掉 `vkms` 后 GL 客户端照常渲染、画面照常上屏，合成器映射
`libGLES_mali.so`、打开 `/dev/mali0`，`/dev/dri/renderD128` 的 fd 数是 0；那条
链路只需要 `mali_nsfix`。一句话：**6.x 用 `mali_nsfix`，5.x / 自带合成器的
桌面用 `vkms`**。确有别的程序需要时，显式开启：

```sh
touch /data/adb/modules/droidspaces_lkm/enable_vkms
```

| 模块 | 什么时候加载 | 什么时候跳过 |
| --- | --- | --- |
| `mali_nsfix.ko` | 存在 `/dev/mali0`，或已加载 `mali_kbase` | 设备没有 Mali GPU |
| `vkms.ko` | 模块目录下存在 `enable_vkms` | 其余情况一律不加载 |

`mali_nsfix` 不是 MTK 专用的：它补的是 `mali_kbase` 的一处假设，任何 Mali 设备
都适用。不加载时，容器内进程创建 GPU context 会得到 `eglInitialize()` 返回
`0x3001`，`dmesg` 里是 `mali 13000000.mali: Failed to get pid pointer for
<comm>/<pid>`。驱动调用 `find_get_pid(current->tgid)`，而 `tgid` 永远是初始命名
空间的值、`find_get_pid()` 却经由调用者的活动命名空间解析，容器进程两者不一致，
查找失败。机制与实测数据见 [`extra/mali_nsfix/README.zh-CN.md`](extra/mali_nsfix/README.zh-CN.md)。

它正是 Mali 版 RootFS 能用的前提：那个镜像通过 libhybris 使用厂商
`libGLES_mali.so`，而它需要在容器内创建 GPU context。实测开销
（PHZ110 / MT6989 / 6.1.157）为 **0.000008% - 0.000025% CPU** —— 全系统每分钟
约 5 次 `find_get_pid()` 拦截；计数不用卸载模块就能读，在
`/sys/module/mali_nsfix/parameters/` 下的 `nshf_seen` / `nshf_hits`。
在没验证过的设备上可以先不挂钩加载（`mali_nsfix_dryrun`，即
`nshf_activate=0`），读 `nshf_active` / `nshf_probe_ok` / `nshf_layout_valid` /
`nshf_driver`；KernelSU「操作」按钮（`action.sh doctor`）会打印同一份状态，
并给一行机器可读的 `nshf_status`。先例与完整失败链见
[模块说明](extra/mali_nsfix/README.zh-CN.md)。

Mali 容器还需要什么（Android 侧合成器配置、`dma-buf` 处理），见 RootFS 仓库的
[桌面与 Anland 指南](https://github.com/misaka5202/Droidspaces-anland6-rootfs/blob/main/docs/zh/桌面与Anland.md)。

### 1.2 逐模块加载开关（ko_switch）

WebUI 的**模块**页可以逐个 `.ko` 选择开机是否加载，无需手动碰文件。每个模块三档：

- **默认** —— 跟随内置的路线判定（没改动时页面显示的就是它），等价于 `ko_switch` 里没有这一条。
- **开** —— 强制加载该模块，覆盖路线（例如在 `anland6` 下加载 `vkms`，或在 `desktop5` 下加载 `mali_nsfix`）。
- **关** —— 永不加载该模块，覆盖路线以及任何旧的 `enable_*` 文件。

应用后写入 `/data/adb/modules/droidspaces_lkm/ko_switch`，每个显式改动的模块一行
`name=0|1`（选「默认」的不落盘）：

```
# 由「模块」页生成；'#' 开头的行与空行会被忽略
lkm4ctr=1
vkms=0
droid_lkm_cpu=0
```

`service.sh` 按以下优先级读取（从高到低）：

1. `ko_switch` 里的显式值（`1`=加载，`0`=不加载）；
2. 旧的单文件开关（`disable_pids` / `disable_cpu` / `disable_uart_guard` /
   `disable_mali`），仅当 `ko_switch` 没有该模块这一条时生效；
3. `module/route` 路线判定与各模块默认。

`ko_switch` 缺失 / 为空 / 全畸形时，完全落到第 2、3 层 —— 一行坏数据（未知模块名、
值不是 0/1、缺少 `=`）只会被记一条警告并忽略，绝不影响其它模块。`action.sh doctor`
会为每个模块打印机器可读的 `ko_mod <name> switch=<1|0|default> loaded=<yes|no>`
行，重启后据此确认实际生效状态。

> [!WARNING]
> `lkm4ctr` 提供容器必需的 PID/IPC/UTS 命名空间。把它**关掉**会让 Droidspaces
> 容器无法启动。选择时页面会警告，`service.sh` 开机也会记一条 `WARN`。

---

## 2. 它修好什么

未打补丁的厂商内核上，`droidspaces check` 的容器关键项全线失败——PID/IPC
namespace、devtmpfs、macvlan、IPv6 NAT。装上本模块后，同一次检查以
**`[✓] All required features found!`** 收尾——这是 6.1.157 厂商内核上的真实
输出，不是推测。

`CPU limit`、`Process limit`、`Sandboxing (user namespaces)` 正是"模块补不了"
的三项，也是本项目以 v1.0.0 而不是 v0.x 发布的原因；机制见[第 8 节](#8-全覆盖)。

> [!WARNING]
> **检查全绿只代表内核设施存在，不代表每项功能端到端可用。** GPU 渲染取决于
> 驱动栈（Mali 需要 `mali_nsfix`，高通 Adreno 不需要；`vkms` 的 render node
> 背后没有 GPU——Mesa 回退 llvmpipe）；`--cpus` / `--pids-limit` 只有在容器
> 同时带 `--memory` 启动时才生效（[第 7 节](#7-cgroup-限制)）；`uart_guard`
> 是防护不是修复，tty 驱动本身的问题它管不了。
>
> **`Sandboxing (user namespaces)` 也不是原生的**——在这些内核上它是 `lkm4ctr`
> vendor 出来的 `user_namespace`，外加三条内核路径补丁让它暴露和持有归属
> （[第 8 节](#8-全覆盖)）。已验证的路径可用（`unshare -Ur`、`uid_map`/`gid_map`、
> 命名空间内 tmpfs/proc/bind 挂载），但真 `CONFIG_USER_NS=y` 内核能处理的边角
> 情形——嵌套命名空间、ucount 计账、LSM 交互、idmapped mounts——行为可能不同。
>
> 把 `droidspaces check` 当**前置条件探测**，用完再验证你真正要用的链路——
> [第 10 节](#10-排障)列了每条路线的检查项。

---

## 3. 安装

### 3.1 KernelSU / Magisk 模块（推荐）

从 [Releases](../../releases/latest) 下载 `droidspaces-lkm-arm64-<version>.zip`，
在管理器里刷入，重启。

模块会按 `/proc/sys/kernel/osrelease` 自动选择匹配当前 KMI 的 `.ko`。

MediaTek 设备在**没有旧配置**时，安装/更新会用音量键提示选择显示路线
（上 = Anland 6.x，下 = 标准桌面 5.x；读不到键则用 `auto`）。升级默认保留原
选择。装完可在 KernelSU 模块页打开 WebUI 复核或修改（重启生效）。

包内带 `updateJson`，后续版本管理器会直接提示更新，不用再回这里下载。
如果所在网络访问不了 `raw.githubusercontent.com`，把 `updateJson` 换成 jsDelivr 镜像：

```
updateJson=https://cdn.jsdelivr.net/gh/misaka5202/droidspaces-lkm@master/update.json
```

### 3.2 手动 insmod

```sh
insmod lkm4ctr-<kmi>.ko
insmod devtmpfs_lkm-<kmi>.ko devtmpfs_probe=2
insmod ip6table_nat-<kmi>.ko
insmod macvlan-<kmi>.ko
insmod vkms-<kmi>.ko
insmod droid_lkm_pids-<kmi>.ko
insmod droid_lkm_cpu-<kmi>.ko
```

`vkms` 只在需要给 Wayland 合成器提供 render node 时才有意义，其他模块不依赖它。

> [!CAUTION]
> **`devtmpfs_probe=2` 很重要。** 它只注册文件系统，不启动 kthread、不装设备
> hook。Droidspaces 只看 `/proc/filesystems` 里有没有 `devtmpfs`；默认路径
> （`probe=0`）会装 inline hook，在非目标版本内核上风险更高。

### 3.3 验证

```sh
cat /proc/filesystems | grep devtmpfs      # 应出现 devtmpfs
unshare -pf true && echo "PID ns OK"
droidspaces check                          # 应显示 All required features found!

# 显示路线与显示链路状态
cat /data/adb/modules/droidspaces_lkm/route            # auto | anland6 | desktop5
sh /data/adb/modules/droidspaces_lkm/action.sh doctor  # 一屏式状态
# 或在 KernelSU 模块页打开本模块 WebUI：主页 / 切换路线 / 模块 / 诊断 / 关于
```

---

## 4. 支持的内核

| 文件 | Android / 内核 |
|---|---|
| `droidspaces-lkm-android12-5.10-arm64-<version>.zip` | Android 12 / 5.10 |
| `droidspaces-lkm-android13-5.10-arm64-<version>.zip` | Android 13 / 5.10 |
| `droidspaces-lkm-android13-5.15-arm64-<version>.zip` | Android 13 / 5.15 |
| `droidspaces-lkm-android14-5.15-arm64-<version>.zip` | Android 14 / 5.15 |
| `droidspaces-lkm-android14-6.1-arm64-<version>.zip` | Android 14 / 6.1 |
| `droidspaces-lkm-android15-6.6-arm64-<version>.zip` | Android 15 / 6.6 |
| `droidspaces-lkm-android16-6.12-arm64-<version>.zip` | Android 16 / 6.12 |

`droidspaces-lkm-arm64-<version>.zip` 是**合并包**，里面包含全部 7 个 KMI 的产物，开机按内核版本 + `ro.board.first_api_level` 自动选对应那一份。想省空间可以只下按 KMI 分包的版本。

> [!CAUTION]
> **仅 arm64。** 非 GKI 内核、非 ARM64 设备不受支持。

每个模块都为每个 KMI 从 DDK 镜像里**该 KMI 自己的内核源码树**构建；
完整矩阵与各 KMI 的构建陷阱见 [KMI-COVERAGE.md](docs/KMI-COVERAGE.md)。

> [!WARNING]
> 同一 KMI 标签的厂商内核 ABI 仍可能有差异。装之前先确认 `uname -r` 里的
> KMI 标签，装完看 `/data/adb/droidspaces_lkm.log`。

---

## 5. 显示路线（route）

`module/route` 决定 Mali 上走哪条渲染路径，三档：

| route | 含义 | Mali 行为 |
|---|---|---|
| `auto`（默认） | 保持现状 | 自动装 `mali_nsfix`；`vkms` 仅在 `enable_vkms` 存在时装 |
| `anland6` | Anland 6.x / waylandbridge | 装 `mali_nsfix`；**强制不装 vkms** |
| `desktop5` | 自带标准合成器的桌面（Anland 5.x 路线） | **强制装 vkms**；不装 `mali_nsfix` |

非 MTK 设备上底栏不显示「切换路线」页签（路线只对 Mali 有意义）。

切换方式：

- **安装 / 更新时**：MediaTek 设备在没有旧配置时会提示按音量键——上 = Anland
  6.x，下 = 标准桌面 5.x；读不到键则用 `auto`。老安装升级默认保留原选择。
- **随时**：KernelSU 模块页打开本模块的 WebUI，单选后点「应用」，重启生效。
- **命令行**：`action.sh route auto|anland6|desktop5`。

WebUI（`webroot/`，Material You 风格 + 底栏五页签：主页 / 切换路线 / 模块 / 诊断 /
关于；MD3 与 MIUIx 两套主题，19 个语言 locale）随时可改路线；主页显示模块加载
情况，「模块」页逐个 `.ko` 选择开机是否加载（见 1.2 节），诊断页给 route、
`/dev/mali0`、`mali_kbase`、`nshf_*`、render node 与日志，
关于页放仓库与两个懒人包入口。

---

## 6. 配合它跑 Linux 桌面（Anland 6.x）

这个模块只负责「让容器能跑」。想在手机上看到真正的 Linux 窗口，还需要
**Anland 6.x** 那一套。Mali 设备上这条链路走 libhybris + `/dev/mali0`，宿主侧
的 `mali_nsfix` 是它的前提；**不需要 `vkms`**（`vkms` 是给 5.x / 自带标准
Wayland 合成器的桌面镜像准备的，见上一节）。

```
droidspaces-lkm（本项目）
  └─ mali_nsfix.ko → 容器内可用 /dev/mali0 建 GPU context
        │
        ▼
Droidspaces-anland6-rootfs（镜像）
  └─ 容器内的 anlandx 会话（wayland 链接 + rootless Xwayland + mini-wm）
        │
        ▼
Anland 6.x 宿主三件套
  ├─ anland-awl 模块（waylandbridge 守护进程，Wayland 服务端）
  ├─ com.anlandnext（显示端，每个窗口一个 Android Activity）
  └─ com.anland.shell（启动器，只负责把应用跑起来）
```

> [!IMPORTANT]
> **用改版，不要装上游 6.2。** 上游有输入缺陷：软键盘文本到不了应用（终端什么都
> 收不到）、应用窗口起不来（xdg configure serial 为 0）、X11 应用读不到剪贴板、
> 重装模块还会让 socket 路径失效。当前发布：
> [`misaka5202/anland`](https://github.com/misaka5202/anland/releases/latest)（宿主模块、APK、容器会话）与
> [`misaka5202/anland-shell`](https://github.com/misaka5202/anland-shell/releases/latest)（启动器）。
> 安装脚本已经默认从改版下载。

一步到位用
[Droidspaces-anland6-rootfs](https://github.com/misaka5202/Droidspaces-anland6-rootfs)
的安装脚本（宿主侧模块、APK、绑定挂载、守护进程配置一次配完）：

```bash
adb push scripts/setup-anland6-host.sh /data/local/tmp/
adb shell su -c 'sh /data/local/tmp/setup-anland6-host.sh'
```

装完用它的诊断脚本确认整条链路：

```bash
adb shell su -c 'sh /data/local/tmp/verify-anland6-host.sh'
```

它会按「宿主 → 容器 → 应用」三层逐项打勾（模块 / 守护进程 / socket / binder /
容器 / 应用）。Mali 上还有一项不在该脚本里、但同样关键的检查：`mali_nsfix`
是否已加载并挂钩——没挂钩时容器内 `eglInitialize()` 会返回 `0x3001`，
`dmesg` 出现 `Failed to get pid pointer`；可用本模块的「操作」按钮
（`action.sh doctor`）或干跑模式确认。

完整的宿主侧步骤、常见断点和排错表见
[桌面与 Anland](https://github.com/misaka5202/Droidspaces-anland6-rootfs/blob/main/docs/zh/桌面与Anland.md)。

> [!CAUTION]
> **不要装 Anland 5.x 那一套**（`virtual-drm-daemon.zip` / `app-debug.apk` /
> `/run/display.sock` 绑定）。5.x 用私有显示协议 + 自带合成器（KWin/GNOME 等），
> Mali 上那条路必须开 `vkms` 才有 render node；6.x 用 Wayland 本身做帧交换，
> 两条路由同时存在会互相打断。

---

## 7. cgroup 限制

`--cpus` 和 `--pids-limit` 是两项无法靠开关配置补上的能力：`CONFIG_CFS_BANDWIDTH=n`
和 `CONFIG_CGROUP_PIDS=n` 时代码路径在编译期就被删掉，没有可"打开"的东西。
这两个模块改为**模拟语义**：

```sh
insmod droid_lkm_pids-<kmi>.ko
insmod droid_lkm_cpu-<kmi>.ko
```

然后按需要带限制启动容器：

```sh
droidspaces --name=box --rootfs=<rootfs> \
    --memory=512M --cpus=0.5 --pids-limit=64 start
```

**`--memory` 是另外两项生效的前提**：仿真的 `pids.max` 与 `cpu.max` 挂在
memory 控制器上，而 Droidspaces 只在配置了内存限制时才启用 memory。

在容器 cgroup 里验证：

```sh
CG=/sys/fs/cgroup/droidspaces/<name>
cat $CG/pids.max          # 64
cat $CG/cpu.max           # 50000
cat $CG/pids.stats        # refused=N, layout=1
```

实现细节、保证与限制：[extra/cgrouplimits/README.md](extra/cgrouplimits/README.md)。

**请手动加载。** 它们 hook `cgroup_can_fork` / `cgroup_post_fork` /
`cgroup_exit` 时优先走 inline，装不上就退回 kprobe（`route=0`，默认）。
`route=1` 强制 inline、`route=2` 强制 kprobe，同一台设备可以随时对比和回退，
不用重编。不进开机自启，意味着任何异常交互都不可能让设备开不了机。

---

## 8. 全覆盖

Droidspaces 的每一项检查现在都通过，包括三项看起来模块补不了的：

| 检查 | 做法 |
|------|------|
| `CPU limit support` | `droid_lkm_cpu` 仿真 `cpu.max` + 补注册 `sched_cfs_bandwidth_slice_us` sysctl |
| `Process limit support` | `droid_lkm_pids` 仿真 pids 控制器，hook `cgroup_can_fork`/`cgroup_post_fork`/`cgroup_exit`，inline 优先、kprobe 兜底 |
| `Sandboxing (user namespaces)` | `lkm4ctr` 通过 `patches/0001-expose-ns-user.patch` 暴露 `/proc/<pid>/ns/user` |

userns 这一项要**三个修复叠加**，少任何一个都只会得到一个"检查全绿但用不了"
的半成品：

1. **暴露 `/proc/<pid>/ns/user`**（`patches/0001`）。发布符号链接只是做了一半：
   `nsfs_evict()` 会无条件解引用 `ns->ns.ops`，而内核静态的 `init_user_ns`
   在 `CONFIG_USER_NS=n` 时没有 ops 初始化器。只加 procfs 条目的补丁会在该
   命名空间第一次被销毁时把内核打崩。所以补丁先照 `kernel/pid_namespace.c`
   处理 `init_pid_ns` 的方式给 init 命名空间装上 `vns_userns_operations`。

2. **修正 mount namespace 的归属**（`patches/0002`）。`CONFIG_USER_NS=n` 时
   `get_user_ns()` 被编成 `return &init_user_ns`，忽略参数。`copy_mnt_ns()`
   用它来钉住新 mount namespace 的属主，于是在子 userns 里创建出来的 mount
   namespace 仍然"属于" init —— `may_mount()` 随即对所有挂载返回 EPERM。

3. **修正 `mount_capable()`**（同样在 `patches/0002`）。同一个 `get_user_ns()`
   bug 让 `alloc_fs_context()` 把 `fc->user_ns` 设成了 init。tmpfs / proc /
   ramfs 都带 `FS_USERNS_MOUNT`，于是走 `ns_capable(fc->user_ns, ...)` 分支
   失败。bind mount 不经过这个检查 —— 这也正是修完第 2 项后 bind 能用、
   tmpfs 还不行原因。

三项都到位后，6.1.157 厂商内核上：`unshare -Ur` 能映射 root，
`uid_map`/`gid_map` 接受 65536 的范围，tmpfs / proc / bind 挂载全部成功 ——
宿主机和 Droidspaces 容器内都一样。

另外两个 namespace 是**相反**的问题：内核本来就支持，是 lkm4ctr 把它们 stub 掉了。

| namespace | 修复前 | 修复后 |
|-----------|--------|--------|
| `NET_NS` | `unshare -n` 静默保持调用方的 ns；`--net=macvlan` 报 "could not create eth0" | 真实 netns，`--net=macvlan` 可用 |
| `CGROUP_NS` | `unshare -C` 保持调用方的 ns | 真实 cgroup namespace |

原实现给 `copy_net_ns` 传 `flags & ~CLONE_NEWNET`，而 `vns_copy_cgroup_ns`
直接忽略 flags。这两处都是**刻意的**：真实 `copy_net_ns` 路径曾导致
percpu_counters 链表损坏。这两个函数开头都是 `inc_ucount(user_ns)`，它会沿
`ns->ucounts` 走并改全局哈希表 —— 而 vendored user_namespace 不参与那套记账，
dmesg 里的 `dec_rlimit_ucounts` 下溢警告正是同一个错配。改传真实
`init_user_ns`（`CONFIG_USER_NS=n` 的内核自己在这些调用点用的就是它），
就把 vendored ns 完全排除在外，原生实现随即正常工作。

CPU limit 那一项也有一个容易被忽略的前提：Droidspaces 要求
`/proc/sys/kernel/sched_cfs_bandwidth_slice_us` 存在，而这个 sysctl 是
`CONFIG_CFS_BANDWIDTH` 保护下注册的，config=n 时内核根本不建。模块用
`register_sysctl()` 真的注册了一张同形状的表（0644、`proc_dointvec_minmax`、
默认 5000），所以那个路径可读可写，不是靠伪造 stat 骗过检查。

> [!NOTE]
> `/proc/<pid>/ns/user` 响应的是**按名查找**而不是目录枚举：
> `ls /proc/self/ns/` 看不到它，但 `stat` / `access` 会成功。这正是
> Droidspaces 实际使用的探测方式。

---

## 9. 安全说明

这些模块是在给内核补能力，所以它可能出错的地方值得写清楚。

- `mount_capable` 只对带 `FS_USERNS_MOUNT` 的文件系统做补正。内核刻意排除在
  user namespace 之外的文件系统仍然要求全局 `CAP_SYS_ADMIN`，容器内 root 挂不了。
- cgroup 限额模块对它跟踪的每个 cgroup 都持引用，cgroup 不会在脚下被释放。
  `cgroup_rmdir` 探针只做标记，真正的回收在工作队列里做，那里才能
  `synchronize_rcu()`。
- `lkm4ctr` 靠改写函数入口的 inline 跳转来重定向，不再用 kprobe 陷阱。
  被覆盖的指令搬到目标附近的 trampoline 里执行，所以 4 字节 `b` 就够；
  kprobe 只在近址分配失败时兜底。
- `devtmpfs_lkm` 会改写内核文本里的 `device_add`/`device_del`。它的 inline hook
  引擎拒绝跨函数边界的窗口、拒绝无法重定位的指令，并且只清除恢复点所在页的
  BTI 守卫属性、卸载时还原。它创建设备节点时，驱动没给 mode 就用 `0600` + root。
- 模块参数全部是 `0444`，运行期不可写。
- `droid_lkm_pids` 的 kprobe 处理器在原子上下文执行，绝不能睡眠。v0.1.27 去掉了
  该路径上最后一处睡眠调用（subtree_control 上的 `kernfs_find_and_get`）；memory
  是否启用的判断改为 `spin_lock_irqsave` 保护的原子观测表。旧版本若打出
  `BUG: scheduling while atomic ... ctl_subtree_pre [droid_lkm_pids]`，升级即可。
- `mali_nsfix` 装钩子前会自校验 `struct module` 布局（错位会把无关的
  `find_get_pid` 调用也重定向掉），且运行期不解析任何符号；校验不过直接拒绝加载。
- WebUI 是纯本地页面：`ksu.exec` 都以 root 执行，但只写 `module/route` 与
  `module/ko_switch` 两个配置文件（不做热 insmod/rmmod，开关下次开机才生效），
  除包内 locale 外不访问网络。

---

## 10. 排障

### 10.1 `insmod: unknown symbol in module, or unknown parameter`

这是内核把所有"装不上"的情况合并成的一句话，它**不告诉你到底是哪一种**。
模块日志现在会把它们分开。

**1. KMI 选错了** —— `.ko` 是给别的内核版本编的。`service.sh` 每次 insmod 前先验
`vermagic`，对不上就直接拒绝并打印两个版本号：

```
[FAIL] lkm4ctr: lkm4ctr-android14-6.1.ko 的 vermagic (6.1.166-dirty) 与内核 5.10.269-... 不匹配，跳过
```

看到这个说明装的包和设备对不上：重装对应内核的包（见[第 4 节](#4-支持的内核)），
并确认管理器里没有旧副本。

**2. 内核没导出某个符号** —— 这个 KMI 匹配救不了：同版本的厂商内核可能裁掉了
通用内核有的导出符号。日志会直接把内核那句原文抄下来，给出符号名：

```
[FAIL] lkm4ctr: insmod: failed to load ...: unknown symbol in module
             [  12.345] lkm4ctr: Unknown symbol some_helper (err -2)
```

带着那个符号名开 issue，就能直接定位。

**3. `unknown parameter`** —— 表示传了模块没声明的参数。`service.sh` 现在会先用
`.ko` 校验参数，不支持的记一条警告再忽略：

```
[WARN] devtmpfs_lkm 不支持参数 foo，已忽略
```

### 10.2 一个模块都没加载

点 KernelSU 模块页的「操作」按钮。它会打印内核版本、识别出的 KMI、模块列表和
能力自检，足够区分"环境不匹配"和"真的坏了"。

另外注意开机保护：连续三次开机都没走到 `boot-completed.sh`，模块会自动禁用自己，
并把原因写进 `/data/adb/droidspaces_lkm.log` 和 `/data/adb/droidspaces_lkm.d/`。

### 10.3 显示路线问题

**A. 自带合成器的桌面报 `no usable DRM render device`（或黑屏）。** 这是 5.x
路线：合成器要打开 `/dev/dri/renderD128`，而 Mali 不提供。把 route 设为
`desktop5`（WebUI「切换路线」页，或 `action.sh route desktop5`）并重启；
`auto` 下只有存在 `enable_vkms` 文件时才会加载 vkms。

**B. Anland 6.x 会话报 `Failed to get pid pointer` / `eglInitialize()` 返回
`0x3001`。** 这是 Mali GPU context 路径。把 route 设为 `anland6`（挂上
`mali_nsfix`）并重启，然后在 WebUI「诊断」或 `action.sh doctor` 里确认。

> [!CAUTION]
> 两条路线互斥，不要同时安装 5.x 与 6.x 的宿主组件。

### 10.4 `BUG: scheduling while atomic` 出现在 `droid_lkm_pids`

v0.1.27 已修复（见[第 9 节](#9-安全说明)）。更早的版本在容器启动、systemd 写
`cgroup.subtree_control` 时可能 panic，升级到 v0.1.27+。

### 10.5 Docker 起不来：`failed to create NAT chain DOCKER`

```
failed to start daemon: Error initializing network controller: error obtaining
controller instance: failed to register "bridge" driver: failed to create NAT
chain DOCKER: iptables failed: iptables --wait -t nat -N DOCKER: iptables
v1.8.10 (nf_tables): Could not fetch rule set generation id: Invalid argument
```

**根因是两项编译期内核配置，任何内核模块都补不齐。** 所有 GKI 内核
（`android12-5.10` 到 `android16-6.12`）都带 `CONFIG_IP_NF_IPTABLES=y`、
`CONFIG_NETFILTER_XTABLES_COMPAT=y`、`CONFIG_IP_NF_NAT=y`，但**没有
`CONFIG_NF_TABLES`**。`iptables-nft` 因此拿不到可用的 netfilter ABI，容器里
每一条 `iptables` 命令都会以上面那个 `Invalid argument` 失败。此外 GKI 也
**没有 `CONFIG_BRIDGE_NETFILTER`** —— 源码（`br_netfilter.c`）根本不在 GKI
树里 —— 所以 Docker 默认的 `bridge` 网络模式在这里同样没有 NAT 可用。

「操作」按钮现在会从 `/proc/config.gz` 把这两项如实报出来：

```
  [--]   没有 nf_tables —— iptables-nft 与本内核无法通信，请改用 iptables-legacy
  [OK]   legacy iptables + IPv4 NAT（docker --bridge=none --network=host 可用）
  [--]   docker bridge 拿不到 NAT（没有 BRIDGE_NETFILTER）—— 请用 --network=host
  nft_status nf_tables=no legacy=yes ipv4_nat=y bridge_netfilter=no
```

**修法 A —— 宿主网络（GKI 上唯一可行的路子）**，与上游 `lkm4ctr` 手册一致：

```sh
# 宿主上
sudo dockerd --config-file="$PREFIX/etc/docker/daemon.json" --bridge=none --experimental
# 容器里
sudo docker run --network=host --rm -it docker.io/library/alpine:latest /bin/sh
```

**修法 B —— 切 legacy iptables（能让 daemon 起来，但 bridge 上没有 NAT）。**
在容器里把 `iptables` 指向 legacy 后端：

```sh
update-alternatives --set iptables  /usr/sbin/iptables-legacy
update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
```

也可以用 `--iptables=false` 启动 daemon：Docker 能跑，但放弃端口映射与 NAT。

> [!NOTE]
> `droidspaces check` 全绿不代表 Docker 能跑：它证明的是内核设施存在，不是
> 每个使用这些设施的功能都可用。见[第 2 节](#2-它修好什么)。

---

## 11. 重要提醒

### 11.1 vermagic 不匹配也可能加载成功

内核真正校验的是 `struct module` 的布局（`.gnu.linkonce.this_module` 段大小），
不只是 vermagic 字符串。本项目所有 ko 的 `this_module` 都是 **1088 字节**，
与厂商模块一致，所以 DDK 编出的 ko 在 kernel release 不同的设备上也能加载。

### 11.2 `devtmpfs_lkm` 千万不要用默认参数开机自启

> [!CAUTION]
> 开机早期加载 `devtmpfs_probe=0`（默认）会**卡开机**：模块会改写内核只读
> 代码段，而早期启动环境不稳定。**始终传 `devtmpfs_probe=2`。**

### 11.3 硬件访问的边界

`--hw-access` 能映射 `/dev/mali0`、`/dev/dma_heap`、`/dev/binder` 等节点，
容器内可以 `open()`。但 Linux 桌面能否真正用上 GPU 取决于驱动栈：

- 高通 Adreno：`/dev/kgsl-3d0` + 用户态 Turnip 可用 —— anland 桌面方案可行，
  且不需要 `vkms`。
- ARM Mali：`/dev/mali0` 是私有 ioctl 接口，标准 Wayland 合成器（KDE/GNOME/
  Hyprland/Niri/Mango/Denial，即 5.x 路线）走 DRM，需要 `vkms` 提供 render
  node。**Anland 6.x（waylandbridge）是例外**：它经 libhybris 直接驱动
  `/dev/mali0`，只需 `mali_nsfix`，不需要 `vkms`。

anland 桌面部署记录：[ANLAND-DEPLOY.md](docs/ANLAND-DEPLOY.md)。

---

## 12. 构建与发布

两个工作流，**刻意分开**：

| 工作流 | 触发 | 是否发布 |
|---|---|---|
| [`ci.yml`](.github/workflows/ci.yml) | push 到 master、PR、手动 | 否，只留 artifact。**默认只编一个 KMI**（android14-6.1），要全量传 `full_matrix: true` |
| [`release.yml`](.github/workflows/release.yml) | 打 tag `vX.Y.Z`、手动指定 tag | 是，**只发预览版** |

两者都调用可复用的
[`build.yml`](.github/workflows/build.yml)，
那个工作流只负责编译打包。把"发布"从 CI 里拿掉的意义是：CI 绿灯永远不会把
坏产物推到用户面前，而每一次发布都对应某个人主动打的 tag。

发一个预览版：

```sh
git tag v0.1.27
git push origin v0.1.27
```

只想试构建、不想打 tag：在 Actions 那一次运行里下载 `ko-*` artifact。

### 12.1 模块目录结构

安装包按 KernelSU 模块规范组织——没有 `META-INF`，也没有 `system/` 覆盖
（这个模块不修改 `/system` 里的任何文件）：

```
module/
├── module.prop        元数据；version 就是更新器比较的那个
├── route              显示路线：auto | anland6 | desktop5（安装期写入）
├── ko_switch          逐模块加载开关（可选；WebUI「模块」页运行期生成）
├── customize.sh       安装期：架构/代际校验、音量键选路线、ui_print
├── service.sh         late_start：按 route 与 ko_switch 决定加载哪些 .ko
├── post-fs-data.sh    开机循环保护 + pstore 现场捕获
├── boot-completed.sh  真正开机成功后才清零计数器
├── uninstall.sh       清理；刻意不 rmmod（原因见下）
├── action.sh          「操作」按钮；另有 route / doctor 子命令
├── i18n.sh            安装/操作/服务脚本文案
├── webroot/           KernelSU WebUI（主页 / 切换路线 / 诊断 / 关于）
└── ko/                各 KMI 的 .ko + symcheck-*.txt
```

发布 zip 还带 `validation.json`：每个 `.ko` 的 SHA256/大小/vermagic、源码树
指纹与产出 commit，拿到包不翻 git 也能核对。

脚本用 `MODDIR=${0%/*}` 取自身目录，不硬编码 `/data/adb/modules/<id>`，
所以装在别处也能正常工作。

---

## 13. 源码与许可证

本项目**不重新实现**内核功能，全部为移植与适配：

| 组件 | 来源 | 许可证 |
|------|------|--------|
| `lkm4ctr`（`vendor/` + `glue/`） | [cyanmint/lkm4ctr](https://github.com/cyanmint/lkm4ctr) | 见其 `copying.txt`；`vendor/kernel/` 源自 Linux，**GPL-2.0-only** |
| `devtmpfs_lkm` / `macvlan` / `ip6table_nat` | [ai-luo2006/droidspaces-6.12-pmb110](https://github.com/ai-luo2006/droidspaces-6.12-pmb110) | GPL-2.0 |
| `droid_lkm_pids` | 同项目的 pids Plan B 移植 | GPL-2.0 |
| `droid_lkm_cpu` | 原创 | GPL-2.0 |
| `extra/hk/` | [Dere3046/HooKern](https://github.com/Dere3046/HooKern) —— 内核 hook 库，做了适配 | GPL-2.0 |
| `extra/kallrecon/` | [Dere3046/KallRecon](https://github.com/Dere3046/KallRecon) —— kallsyms 重建 | GPL-2.0 |
| `uart_guard` | 原创 | GPL-2.0 |
| `mali_nsfix` | 原创（kprobe ARM Mali DDK，见 `extra/mali_nsfix/ORIGIN`） | GPL-2.0 |

> [!IMPORTANT]
> **GPL-2.0 要求分发二进制时提供对应源码。** 每个 Release 附带的
> `source-<tag>.tar.gz` 就是编出该版本 ko 的完整源码快照。

`vendor/kernel/user_namespace.c`、`vendor/kernel/nsproxy.c`、
`vendor/kernel/pid_namespace.c`、`vendor/ipc/*` 直接来自 Linux
（6.1.124 / android14-6.1），仅做了符号重命名以支持树外构建。

---

## 14. 参考

- [Droidspaces](https://github.com/ravindu644/Droidspaces-OSS)
- [lkm4ctr](https://github.com/cyanmint/lkm4ctr) — 命名空间模块
- [droidspaces-6.12-pmb110](https://github.com/ai-luo2006/droidspaces-6.12-pmb110) — devtmpfs / macvlan / ip6nat / pids 实现
- [susfs4ksu-lkm](https://github.com/inforcqb/susfs4ksu-lkm) — 发布模式参考
- [HooKern](https://github.com/Dere3046/HooKern) —— 内核 hook 库，`extra/hk/` 由它适配而来
- [KallRecon](https://github.com/Dere3046/KallRecon) —— kallsyms 重建，vendored 在 `extra/kallrecon/`

> [!CAUTION]
> **免责声明**：加载内核模块等同于以最高权限执行内核代码。仅在你能接受设备
> 无法开机风险的前提下使用，并确保有恢复手段（fastboot / recovery）。
