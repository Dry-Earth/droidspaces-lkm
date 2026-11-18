# Droidspaces LKM

**在原始 GKI 内核上补齐容器能力，无需重编内核、无需刷 boot。**

[**English**](README.md) | **简体中文** · [Releases](../../releases/latest) · [KMI 覆盖矩阵](docs/KMI-COVERAGE.md)

---

Droidspaces 需要 PID/IPC namespace、devtmpfs、macvlan、IPv6 NAT 以及若干
cgroup 控制器。多数厂商内核为了通过 GKI ABI 检查把这些都编译掉了。

想让它们回来，得自己重编内核再刷进去。这条路能走，就是代价
不小：每个机型要单独编一份，编出来的稳定性得自己担，系统一更新还得重来。
做成模块就避开了这些——一份模块覆盖 7 个 KMI，按 `uname -r` 匹配，
跟机型本身关系不大。

## 项目状态

**还没有正式版本。** 本仓库目前发布的每一个 tag 都是 GitHub **pre-release（预览版）**。
请把它当作"拿来试一试、有问题反馈"的构建，而不是可以依赖的版本。
等 inline 钩子后端在七个 KMI 上都跑完真机回归，才会打第一个正式版。

| | |
|---|---|
| CI 做什么 | 编译全部 KMI，编译不过就让构建失败，产物只作为 Actions artifact 保留。**永不发布。** |
| Release 做什么 | 只在打 tag（`vX.Y.Z`）时运行，构建后发布**预览版**，附模块包、分 KMI 的 zip 和源码快照。 |
| 去哪反馈 | [新建 issue](https://github.com/misaka5202/droidspaces-lkm/issues/new/choose)，表单会直接要够定位问题的那几项数据。 |

`update.json` 只在"这次发布要让 KernelSU 更新器推给用户"时才改，所以它现在指向
尚未发布的 `v0.1.0`。

## 它修好什么

未打补丁的厂商内核上，`droidspaces check` 是这样的：

```
[MUST HAVE]
  [✗] PID namespace
  [✗] IPC namespace
[RECOMMENDED]
  [✗] devtmpfs support
[OPTIONAL]
  [✗] Macvlan support
  [✗] IPv6 NAT support
```

装上本项目后，每一行都是勾：

```
[MUST HAVE]
  [✓] Root privileges          [✓] PID namespace
  [✓] Linux version            [✓] Mount namespace
  [✓] UTS namespace            [✓] IPC namespace
  [✓] pivot_root syscall       [✓] /proc filesystem
  [✓] /sys filesystem          [✓] Seccomp support

[RECOMMENDED]
  [✓] epoll / signalfd / PTY / devpts      [✓] Loop device
  [✓] ext4 filesystem                      [✓] Cgroup v2 support
  [✓] Cgroup namespace                     [✓] New mount API
  [✓] devtmpfs support

[OPTIONAL]
  [✓] FUSE support             [✓] TUN/TAP support
  [✓] OverlayFS support        [✓] Network namespace
  [✓] Bridge device support    [✓] Veth pair support
  [✓] Macvlan support          [✓] IPv6 NAT support
  [✓] Memory limit support     [✓] Swap limit support
  [✓] CPU limit support        [✓] CPU usage accounting
  [✓] Process limit support    [✓] Sandboxing (user namespaces)

[✓] All required features found!
```

这是 6.1.157 厂商内核上的真实输出，不是推测。`OPTIONAL` 那一块才是重点：
`CPU limit`、`Process limit`、`Sandboxing` 正是"模块补不了"的三项，也是
本项目以 v1.0.0 而不是 v0.x 发布的原因。

## 包含的模块

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
tty 保护。想"装但不加载"某个，在模块目录放 `disable_pids` / `disable_cpu` /
`disable_uart_guard` / `disable_mali` 文件即可；放 `mali_nsfix_dryrun` 则以
不挂钩的干跑模式（`nshf_activate=0`）加载 mali_nsfix，用于预检。

### 按平台条件加载的模块

`mali_nsfix` 在 Mali 平台上自动加载，其余平台跳过。判断依据是设备实际报告的
状态，不是厂商名列表。

> **本表的 Android 版本说的是内核模块（KMI）那一侧**，与 anland6 用户态无关：
> anland6 的 `waylandbridge` 需要 **Android 14（API 34）+**（`ANativeWindow_readFromParcel`
> 是 API 34 才引入的符号，Android 13 上 daemon 加载失败）。
> 详见 <https://github.com/misaka5202/Droidspaces-anland6-rootfs#support-matrix>。

`vkms` 默认完全不加载。它提供的 `/dev/dri/renderD128` 背后没有 GPU，Mesa 只能
落回 llvmpipe，也就是 CPU 软件渲染。它服务的是**自带标准 Wayland 合成器的桌面
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

## 安装

### 方式一：KernelSU / APatch 模块（推荐）

从 [Releases](../../releases/latest) 下载 `droidspaces-lkm-arm64-<version>.zip`，
在管理器里刷入，重启。

包内带 `updateJson`，后续版本管理器会直接提示更新，不用再回这里下载。
如果所在网络访问不了 `raw.githubusercontent.com`，把 `updateJson` 换成 jsDelivr 镜像：

```
updateJson=https://cdn.jsdelivr.net/gh/misaka5202/droidspaces-lkm@master/update.json
```

模块会按 `/proc/sys/kernel/osrelease` 自动选择匹配当前 KMI 的 `.ko`。

### 方式二：手动 insmod

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

**`devtmpfs_probe=2` 很重要。** 它只注册文件系统，不启动 kthread、不装设备
hook。Droidspaces 只看 `/proc/filesystems` 里有没有 `devtmpfs`；默认路径
（`probe=0`）会装 inline hook，在非目标版本内核上风险更高。

### 验证

```sh
cat /proc/filesystems | grep devtmpfs      # 应出现 devtmpfs
unshare -pf true && echo "PID ns OK"
droidspaces check                          # 应显示 All required features found!
```

## 支持的内核

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

**仅 arm64。** 非 GKI 内核、非 ARM64 设备不受支持。

每个模块都为每个 KMI 从 DDK 镜像里**该 KMI 自己的内核源码树**构建；
完整矩阵与各 KMI 的构建陷阱见 [KMI-COVERAGE.md](docs/KMI-COVERAGE.md)。

> 同一 KMI 标签的厂商内核 ABI 仍可能有差异。装之前先确认 `uname -r` 里的
> KMI 标签，装完看 `/data/adb/droidspaces_lkm.log`。

## 显示路线（route）

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

WebUI（`webroot/`，Material You 风格 + 底栏四页签：主页 / 切换路线 / 诊断 /
关于，中英双语）随时可改路线；主页显示模块加载情况，诊断页给 route、
`/dev/mali0`、`mali_kbase`、`nshf_*`、render node 与日志，关于页放仓库与两个
懒人包入口：

- 5.x RootFS 构建仓库：https://github.com/misaka5202/Droidspaces-rootfs-Desktop-builder
- 6.x Anland RootFS 仓库：https://github.com/misaka5202/droidspaces-anland6-rootfs

## 配合它跑 Linux 桌面（Anland 6.x）

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

> **不要装 Anland 5.x 那一套**（`virtual-drm-daemon.zip` / `app-debug.apk` /
> `/run/display.sock` 绑定）。5.x 用私有显示协议 + 自带合成器（KWin/GNOME 等），
> Mali 上那条路必须开 `vkms` 才有 render node；6.x 用 Wayland 本身做帧交换，
> 两条路由同时存在会互相打断。

## cgroup 限制

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

## 全覆盖

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

注意 `/proc/<pid>/ns/user` 响应的是**按名查找**而不是目录枚举：
`ls /proc/self/ns/` 看不到它，但 `stat` / `access` 会成功。这正是
Droidspaces 实际使用的探测方式。

## 安全说明

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

每个版本修了什么见 [CHANGELOG.md](docs/CHANGELOG.md)。

## 排障

### `insmod: unknown symbol in module, or unknown parameter`

这是内核把所有"装不上"的情况合并成的一句话，它**不告诉你到底是哪一种**。
模块日志现在会把它们分开。

**1. KMI 选错了** —— `.ko` 是给别的内核版本编的。`service.sh` 每次 insmod 前先验
`vermagic`，对不上就直接拒绝并打印两个版本号：

```
[FAIL] lkm4ctr: lkm4ctr-android14-6.1.ko 的 vermagic (6.1.166-dirty) 与内核 5.10.269-... 不匹配，跳过
```

看到这个说明装的包和设备对不上：重装对应内核的包，并确认管理器里没有旧副本。

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

### 一个模块都没加载

点 KernelSU 模块页的「操作」按钮。它会打印内核版本、识别出的 KMI、模块列表和
能力自检，足够区分"环境不匹配"和"真的坏了"。

另外注意开机保护：连续三次开机都没走到 `boot-completed.sh`，模块会自动禁用自己，
并把原因写进 `/data/adb/droidspaces_lkm.log` 和 `/data/adb/droidspaces_lkm.d/`。

## 重要提醒

### vermagic 不匹配也可能加载成功

内核真正校验的是 `struct module` 的布局（`.gnu.linkonce.this_module` 段大小），
不只是 vermagic 字符串。本项目所有 ko 的 `this_module` 都是 **1088 字节**，
与厂商模块一致，所以 DDK 编出的 ko 在 kernel release 不同的设备上也能加载。

### `devtmpfs_lkm` 千万不要用默认参数开机自启

开机早期加载 `devtmpfs_probe=0`（默认）会**卡开机**：模块会改写内核只读
代码段，而早期启动环境不稳定。**始终传 `devtmpfs_probe=2`。**

### 硬件访问的边界

`--hw-access` 能映射 `/dev/mali0`、`/dev/dma_heap`、`/dev/binder` 等节点，
容器内可以 `open()`。但 Linux 桌面能否真正用上 GPU 取决于驱动栈：

- 高通 Adreno：`/dev/kgsl-3d0` + 用户态 Turnip 可用 —— anland 桌面方案可行，
  且不需要 `vkms`。
- ARM Mali：`/dev/mali0` 是私有 ioctl 接口，标准 Wayland 合成器（KDE/GNOME/
  Hyprland/Niri/Mango/Denial，即 5.x 路线）走 DRM，需要 `vkms` 提供 render
  node。**Anland 6.x（waylandbridge）是例外**：它经 libhybris 直接驱动
  `/dev/mali0`，只需 `mali_nsfix`，不需要 `vkms`。

anland 桌面部署记录：[ANLAND-DEPLOY.md](docs/ANLAND-DEPLOY.md)。

## 构建与发布

两个工作流，**刻意分开**：

| 工作流 | 触发 | 是否发布 |
|---|---|---|
| [`ci.yml`](https://github.com/misaka5202/droidspaces-lkm/blob/master/.github/workflows/ci.yml) | push 到 master、PR、手动 | 否，只留 artifact。**默认只编一个 KMI**（android14-6.1），要全量传 `full_matrix: true` |
| [`release.yml`](https://github.com/misaka5202/droidspaces-lkm/blob/master/.github/workflows/release.yml) | 打 tag `vX.Y.Z`、手动指定 tag | 是，**只发预览版** |

两者都调用可复用的
[`build.yml`](https://github.com/misaka5202/droidspaces-lkm/blob/master/.github/workflows/build.yml)，
那个工作流只负责编译打包。把"发布"从 CI 里拿掉的意义是：CI 绿灯永远不会把
坏产物推到用户面前，而每一次发布都对应某个人主动打的 tag。

发一个预览版：

```sh
git tag v0.1.0
git push origin v0.1.0
```

只想试构建、不想打 tag：在 Actions 那一次运行里下载 `ko-*` artifact。

### 模块目录结构

安装包按 KernelSU 模块规范组织——没有 `META-INF`，也没有 `system/` 覆盖
（这个模块不修改 `/system` 里的任何文件）：

```
module/
├── module.prop      元数据；version 就是更新器比较的那个
├── customize.sh     安装期：架构检查、KMI 提示、ui_print
├── service.sh       late_start：按 KMI 加载 .ko
├── uninstall.sh     清理；刻意不 rmmod（原因见下）
└── action.sh        「操作」按钮：一屏给出状态与能力自检
```

脚本用 `MODDIR=${0%/*}` 取自身目录，不硬编码 `/data/adb/modules/<id>`，
所以装在别处也能正常工作。

## 源码与许可证

本项目**不重新实现**内核功能，全部为移植与适配：

| 组件 | 来源 | 许可证 |
|------|------|--------|
| `lkm4ctr`（`vendor/` + `glue/`） | [cyanmint/lkm4ctr](https://github.com/cyanmint/lkm4ctr) | 见其 `copying.txt`；`vendor/kernel/` 源自 Linux，**GPL-2.0-only** |
| `devtmpfs_lkm` / `macvlan` / `ip6table_nat` | [ai-luo2006/droidspaces-6.12-pmb110](https://github.com/ai-luo2006/droidspaces-6.12-pmb110) | GPL-2.0 |
| `droid_lkm_pids` | 同项目的 pids Plan B 移植 | GPL-2.0 |
| `droid_lkm_cpu` | 原创 | GPL-2.0 |

**GPL-2.0 要求分发二进制时提供对应源码。** 每个 Release 附带的
`source-<tag>.tar.gz` 就是编出该版本 ko 的完整源码快照。

`vendor/kernel/user_namespace.c`、`vendor/kernel/nsproxy.c`、
`vendor/kernel/pid_namespace.c`、`vendor/ipc/*` 直接来自 Linux
（6.1.124 / android14-6.1），仅做了符号重命名以支持树外构建。

## 参考

- [Droidspaces](https://github.com/ravindu644/Droidspaces-OSS)
- [lkm4ctr](https://github.com/cyanmint/lkm4ctr) — 命名空间模块
- [droidspaces-6.12-pmb110](https://github.com/ai-luo2006/droidspaces-6.12-pmb110) — devtmpfs / macvlan / ip6nat / pids 实现
- [susfs4ksu-lkm](https://github.com/inforcqb/susfs4ksu-lkm) — 发布模式参考

**免责声明**：加载内核模块等同于以最高权限执行内核代码。仅在你能接受设备
无法开机风险的前提下使用，并确保有恢复手段（fastboot / recovery）。
