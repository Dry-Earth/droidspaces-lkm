# Droidspaces LKM for OnePlus Ace 5 Pro (hummer)

上游 [misaka5202/droidspaces-lkm](https://github.com/misaka5202/droidspaces-lkm)
（已同步 v0.1.29 / `89cbefc`）+ 本 fork 的**精确内核构建**通道。

| 项目 | 值 |
|---|---|
| 机型 | 一加 Ace 5 Pro（`hummer`） |
| 系统 | LineageOS 24.0 |
| 内核 | `6.6.144-4k-g01ee97578159` |
| 内核 commit | `01ee97578159bc9cb2a60f559d20510ce33add6a` |
| KMI | `android15-6.6` |
| 原厂编译器 | clang r596125（clang 22.0.2） |
| 模块 ID | `droidspaces_lkm` |

在不刷内核的前提下补上容器能力：PID/IPC/UTS namespace、**真实 user namespace**、
devtmpfs、macvlan、IPv6 NAT、cgroup pids/cpu 限流、vkms、tty 保护。

> **两个仓库怎么选**
>
> | 需求 | 用哪个 |
> |---|---|
> | 真实 `unshare -Ur` / `uid_map` / `gid_map` | **本仓库**（`droidspaces_lkm`） |
> | 只要 `droidspaces check` 全绿、带 crash 兜底加载器 | [`Dry-Earth/LKM-Droidspaces`](https://github.com/Dry-Earth/LKM-Droidspaces)（`phdroid`） |
>
> 两者都会抢 namespace hook，**不能同时启用**。上游英文文档见
> [README-UPSTREAM.md](README-UPSTREAM.md)。

---

## 1. 这个仓库实现了什么

### 1.1 按设备精确构建

- 从 OTA `boot.img` 解出原厂 `.config`、完整 `Linux version`、编译器 banner
- 从 `build-manifest.xml` 取 kernel / modules / clang / build-tools /
  kernel-build-tools / mkbootimg 的 revision
- 用**同一套 manifest clang** 在 runner 上编出与设备一致的 KDIR，再用它编所有模块
- 不用 DDK 容器，不用 magiskboot（用 AOSP `unpack_bootimg.py`）

工具 revision（20261120 OTA）：

| 工具 | revision |
|---|---|
| clang | `29182889…`（clang-r596125） |
| build-tools | `9b6c8c6a…` |
| kernel-build-tools | `811c6e29…` |
| mkbootimg | `4a27dd13…` |

### 1.2 跟上游 v0.1.29 对齐

| 上游能力 | 效果 |
|---|---|
| `ko_switch` | WebUI 里逐模块开关，写 `/data/adb/modules/droidspaces_lkm/ko_switch` |
| `i18n.sh` | 模块脚本多语言，日志标记不翻译（便于 grep） |
| `lkm4ctr-lite` | 不带 vendored overlayfs 的独立回退版，完整版装不上时自动回退 |
| `mali_nsfix` | Mali GPU 在 PID namespace 里创建 context 的修复（本机 Adreno 不加载） |
| 符号自检 | 构建期 `nm -u` 固化未定义符号，`MUST_NOT_APPEAR` 命中直接失败 |
| WebUI | `module/webroot/` 预构建页面（20 种语言） |

### 1.3 缺啥补啥

`scripts/build_modules.sh` 读解包出来的 `build-config/stock.config`，内核里已经
启用的能力直接跳过：

| 模块 | 跳过条件 |
|---|---|
| `devtmpfs_lkm` | `CONFIG_DEVTMPFS=y/m` |
| `macvlan` | `CONFIG_MACVLAN=y/m` |
| `ip6table_nat` | `CONFIG_IP6_NF_NAT` + `CONFIG_IP6_NF_TARGET_MASQUERADE` |
| `droid_lkm_pids` | `CONFIG_CGROUP_PIDS=y/m` |
| `droid_lkm_cpu` | `CONFIG_CFS_BANDWIDTH=y/m` |
| `vkms` | `CONFIG_DRM_VKMS=y/m` |

`lkm4ctr` 与 `uart_guard` 始终构建。完整性检查按同一份 config 计算“本次应有”的
模块，缺一个就红，不会静默发出残缺包。本机这些 CONFIG 全是 `n`，所以实际仍是全套。

### 1.4 NSpid 补丁（`patches/0012-nspid-status.patch`）

Droidspaces App 用 `/proc/<pid>/status` 的 `NSpid` 最后一位是否为 `1` 判断容器
init（`src/container/registry.c` 的 `is_container_init()`）。

本机内核 `CONFIG_PID_NS=n`，`fs/proc/array.c` 里整段 `NStgid/NSpid/NSpgid/NSsid`
被编译掉。即使 lkm4ctr 用的是真实 `copy_pid_ns`，App 也看不到 NSpid，于是显示
“容器未运行”。

0012 用 `shadow_hook` 挂 `proc_pid_status`，按 `pid->numbers[]` 重建这段输出
（逻辑与内核一致），只对 `pid->level > ns->level` 的进程追加，宿主进程不受影响。

设备实测：装上带 0012 的包后，启动容器 App 立即显示“运行中”。

### 1.5 真实 user namespace

userns 来自 lkm4ctr vendored 的 `vendor/kernel/user_namespace.c` / `nsproxy.c`，
是真实的 `struct user_namespace`：

- `unshare -Ur true` 返回 0
- ns 内 `uid=0`，`uid_map` / `gid_map` 可写（父进程给子进程写，gid 先
  `setgroups=deny`），范围映射 `0 0 65536` 实测可用
- ns 内挂 `tmpfs` / `proc` 可用

但它**不是**原生 `CONFIG_USER_NS=y`，`setns` 等路径可能不完整，不要当安全边界。

### 1.6 针对 hummer 的稳定性结论

| 结论 | 说明 |
|---|---|
| namespace hook 走 kprobe | 带 PAC 序言（`paciasp`/`pacibisp`）的函数不能用 text patch，否则卡死 |
| `devtmpfs_lkm` 必须 `devtmpfs_probe=2` | 默认 `probe=0` 会装 `device_add/del` inline hook 改内核只读段，开机加载会卡 |
| `vkms` 需要 `DRIVER_RENDER` 补丁 | 否则只有 `card` 没有 `/dev/dri/renderD*` |
| `uart_guard` 默认加载 | 容器里 udev 扫 `/sys/class/tty` 会锁已损坏的 `tty_port`，能把内核打 panic |
| userns 自检 `mount tmpfs -13` | SELinux `u:r:kernel:s0` 的 `mounton` 拒绝，不影响 `droidspaces check` |

### 1.7 已知外部问题

App 终端里 `exit` / 点 × 导致整机硬复位：根因是 **KernelSU 的 LKM 模式 root**，
与模块和上游无关（同一内核上的 phDroid 也能复现，换非 LKM root 后不再复位）。

---

## 2. 模块清单

| 模块 | 作用 | 默认加载 |
|---|---|:---:|
| `lkm4ctr` | PID/IPC/UTS/user namespace 核心 | ✓ |
| `lkm4ctr-lite` | 不带 vendored overlayfs 的回退版 | 仅回退时 |
| `devtmpfs_lkm` | 注册 devtmpfs | ✓（config 缺时编） |
| `macvlan` | `--net=macvlan` | ✓（config 缺时编） |
| `ip6table_nat` | IPv6 NAT | ✓（config 缺时编） |
| `droid_lkm_pids` | cgroup pids 控制器 | ✓ |
| `droid_lkm_cpu` | `cpu.max` 时间片限流 | ✓ |
| `vkms` | 虚拟 DRM（render node，CPU 软件渲染） | ✗ 默认关闭 |
| `uart_guard` | tty 属性读保护 | ✓ |
| `mali_nsfix` | Mali GPU 的 PID 查找修复 | 仅 Mali 设备 |

加载顺序：

```
lkm4ctr → devtmpfs_lkm → ip6table_nat → macvlan → (vkms)
→ droid_lkm_pids → droid_lkm_cpu → uart_guard → (mali_nsfix)
```

`config.conf` 里的 `modules=` 不是必需项：`service.sh` 按上面的顺序找
`ko/<name>-<kmi>.ko`，找不到就记 `[MISS]` 跳过。

---

## 3. 模块怎么用

### 3.1 安装前

1. 保留 fastboot / recovery 回滚手段。
2. 停用其它 namespace 实现（phDroid、`droidspaces_hummer`、旧版本模块）：

```sh
su -c 'touch /data/adb/modules/phdroid/disable'
su -c 'touch /data/adb/modules/droidspaces_hummer/disable'
```

3. **重启**，让旧的 hook 完全卸载。

### 3.2 安装

KernelSU / APatch 安装 `droidspaces-lkm-hummer-arm64.zip`，重启。

包内布局：

```
module.prop  customize.sh  service.sh  post-fs-data.sh  action.sh
i18n.sh  route  webroot/                  # WebUI
ko/lkm4ctr-android15-6.6.ko               # 每个模块一个
ko/...  ko/SHA256SUMS
build-info.json  build-info.txt
```

### 3.3 开机加载与日志

`service.sh` 在 `late_start` 自动按顺序加载，不需要手动操作。

| 路径 | 内容 |
|---|---|
| `/data/adb/droidspaces_lkm.log` | 加载日志（>256 KB 轮转到 `.log.old`） |
| `/data/adb/droidspaces_lkm.d/` | 状态目录（`snapshot.txt` / `hang-report.txt`） |
| `/data/adb/droidspaces_lkm.bootcount` | 开机计数，由 `boot-completed.sh` 在系统真正启动后清零 |

日志同时写 `/dev/kmsg`，所以 `dmesg` / bugreport 里也能看到。

### 3.4 逐模块开关（`ko_switch`）

文件：`/data/adb/modules/droidspaces_lkm/ko_switch`，每行一个 `<name>=<0|1>`：

```
lkm4ctr=1
vkms=1
droid_lkm_pids=0
```

- 可写名字：`lkm4ctr`、`devtmpfs_lkm`、`ip6table_nat`、`macvlan`、`vkms`、
  `droid_lkm_pids`、`droid_lkm_cpu`、`uart_guard`、`mali_nsfix`
- 没写 / 写 `-` = 跟随 `route` / 旧开关 / 默认值
- **重启后生效**（`service.sh` 只在开机跑）

WebUI 的模块页就是读写这个文件。

### 3.5 使用路线（`route`）

文件：`/data/adb/modules/droidspaces_lkm/route`，值：

| 值 | 场景 | 对 vkms / mali 的影响 |
|---|---|---|
| `auto`（默认） | 普通手机 | vkms 只在有 `enable_vkms` 时加载 |
| `anland6` | Wayland 桌面镜像 | 不加载 vkms |
| `desktop5` | 桌面镜像 | 仅 Mali 设备加载 vkms；mali_nsfix 默认不装 |

切换：

```sh
su -c 'sh /data/adb/modules/droidspaces_lkm/action.sh route desktop5'
# 或 WebUI 里选，重启生效
```

hummer 是 Adreno + 普通 LineageOS，保持 `auto` 即可。

### 3.6 旧开关（仍兼容）

| 文件 | 作用 |
|---|---|
| `enable_vkms` | `route=auto` 时加载 vkms |
| `disable_pids` / `disable_cpu` | 不加载 cgroup 限流模块 |
| `disable_uart_guard` | 不加载 tty 保护 |
| `disable_mali` | 不加载 mali_nsfix |
| `mali_nsfix_dryrun` | 加载 mali_nsfix 但不挂钩，只做探针 |

`ko_switch` 优先级高于这些文件。

### 3.7 WebUI

KernelSU 模块页点“打开”：

- 概览：内核、KMI、route、已加载模块、mali_nsfix 状态
- 模块页：逐模块 `开 / 关 / 跟随默认`（写 `ko_switch`）
- 路线页：`auto` / `anland6` / `desktop5`（写 `route`）
- 日志页：`/data/adb/droidspaces_lkm.log`

WebUI 只改配置，**重启后生效**。

### 3.8 诊断（`action.sh`）

KernelSU 模块页的“操作”按钮会跑 `action.sh`，输出一屏结论：版本、内核、route、
加载状态、`/proc/filesystems` 里的 devtmpfs、`unshare` 能力、各模块导出符号检查。

```sh
su -c 'sh /data/adb/modules/droidspaces_lkm/action.sh doctor'
```

### 3.9 验证

```sh
# 加载日志
su -c 'cat /data/adb/droidspaces_lkm.log'

# 内核模块
su -c 'lsmod | grep -E "lkm4ctr|devtmpfs_lkm|droid_lkm|uart_guard"'

# Droidspaces 自检（不在默认 PATH）
su -c '/data/local/Droidspaces/bin/droidspaces check'

# 真实 userns
su -c 'unshare -Ur sh -c "id -u; cat /proc/self/uid_map"'

# 范围映射（父进程写子进程）
su -c 'unshare -U sleep 60 & p=$!; sleep 1; \
  echo "0 0 65536" > /proc/$p/uid_map; echo deny > /proc/$p/setgroups; \
  echo "0 0 65536" > /proc/$p/gid_map; cat /proc/$p/uid_map; kill $p'

# App 识别容器 init
su -c 'grep NSpid /proc/<容器init的宿主pid>/status'
```

`droidspaces check` 应该全绿；`NSpid` 应出现 `<host_pid> 1`。

### 3.10 卸载 / 切换

```sh
su -c 'touch /data/adb/modules/droidspaces_lkm/remove'
```

重启后卸载。切到 phDroid 时同样先停用本模块并重启。

---

## 4. 工作流怎么用

### 4.1 入口与输入

**Actions → `[hummer] Build from manifest tools`**
（`.github/workflows/build-hummer-manifest.yml`）

| 输入 | 默认 | 说明 |
|---|---|---|
| `boot_img_url` | `.../hummer/20261113/boot.img` | OTA 的 boot.img |
| `manifest_url` | `.../hummer/20261113/build-manifest.xml` | 同一 OTA 的 manifest |
| `publish_release` | `true` | 成功后发 Release |

```sh
gh workflow run build-hummer-manifest.yml \
  -f boot_img_url=https://github.com/Dry-Earth/LKM-Droidspaces/releases/download/boot-assets/boot-20261120-finasu-v3.img \
  -f manifest_url=https://mirrorbits.lineageos.org/full/hummer/20261120/build-manifest.xml \
  -f publish_release=true
```

默认值停在 20261113；构建新 OTA 时手动换两个 URL。

### 4.2 流水线做什么

1. 解析 manifest → kernel / modules / clang / build-tools / kernel-build-tools / mkbootimg
2. 下载 boot.img，用 AOSP `unpack_bootimg.py` 解包
3. 提取 `.config`、完整 `Linux version`、编译器（patched boot 没有 `based on r…`
   时从 `CONFIG_CC_VERSION_TEXT` 回退）
4. 按 manifest revision 检出 kernel / modules
5. 准备工具链并缓存到 `tools/`；pahole 不可用时回退 Ubuntu `dwarves`
6. 用原厂 config + clang 编精确 KDIR（ccache 缓存在 `.ccache`）
7. clone `cyanmint/lkm4ctr`，按文件名顺序应用 `patches/*.patch`
8. 编模块（config-driven，只编缺的），生成 `out/*.ko` 与 `modules-built-*.txt`
9. 校验每个 `.ko` 的 vermagic 等于设备 `uname -r`
10. 打包：整份 `module/`（脚本 + i18n + WebUI）+ `ko/` + `build-info.*`
11. 发 Release / 上传 artifact

冷缓存约 30 分钟，命中 `tools/` 与 `.ccache` 后通常十几分钟。

### 4.3 产物

| 类型 | 名称 |
|---|---|
| Release tag | `hummer-manifest-<run_id>` |
| ZIP | `droidspaces-lkm-hummer-arm64.zip` |
| 校验 | `SHA256SUMS`、`build-info-hummer.txt` |
| Actions artifact | `droidspaces-lkm-hummer-manifest-<run_id>` |

`build-info-hummer.txt` 记录 boot sha256、kernel/modules commit、工具 revision、
lkm4ctr commit、每个 `.ko` 与 zip 的 sha256 —— 排查“装的哪一版”先看它。

### 4.4 什么时候要重跑

- OTA 换了（`uname -r` 的 `g...` 变化）→ 必须重跑
- 改了 `scripts/build_modules.sh`、`patches/*.patch`、`extra/**/*.c`、`ci/*`
- `cyanmint/lkm4ctr` 的 HEAD 变了
- 上游发了新 Release 或合并了上游
- 只改文档 → 不用重跑

### 4.5 失败排查

| 现象 | 原因 / 处理 |
|---|---|
| `git apply` 在 patch 步骤失败 | 上游 patch 编号/内容变了，或本地 patch 不是最后一个；按序重排后用 `git apply --check` 本地验证 |
| `lkm4ctr` 编不过 | 多半是内核树 ABI 变化；看 `ci/adapt-lkm4ctr.py` 是否需要新规则 |
| 模块 `unknown symbol` | vermagic 或符号表不匹配；先核对 `build-info-hummer.txt` |
| `pahole` 报错 | manifest 预编译版不可用，已自动回退 Ubuntu `dwarves` |
| 开机没有模块 | 看 `droidspaces_lkm.log` 的 `[MISS]` / `[FAIL]`；确认 `ko/<name>-<kmi>.ko` 存在 |
| 容器里没有 `renderD*` | `vkms` 默认关闭；`ko_switch` 写 `vkms=1` 后重启，且需要 `DRIVER_RENDER` 补丁 |
| App 显示“容器未运行” | 内核缺 `NSpid`；确认包里是带 `0012` 编出来的 `lkm4ctr` |

---

## 5. 已验证状态（2026-11-27）

设备：OnePlus Ace 5 Pro / LineageOS 24 / `boot-20261120-finasu-v3`

| Release | ZIP sha256 | 内容 |
|---|---|---|
| `hummer-manifest-45852211799` | `74cc0089958e594498264c9b7d85ff5b6a7ee8b84e2f462f66f45b6877693575` | 真实 userns |
| `hummer-manifest-45861110289` | `080163934d558c17209b10cd58de7f02d195c2df47e9812ca9fe4c9e0ffe378a` | + NSpid |
| `hummer-manifest-45862609906` | 同上 | + config-driven（本机 config 下产物相同） |
| `hummer-manifest-45865204444` | `c3b9a92aa0de42def49a91f295de11f6d7adbaeaec13bb67b826e363b5b9ed76` | 上游 v0.1.29 + config-driven + 完整 WebUI + NSpid |

已设备实测（`45865204444`）：

- `droidspaces check` **全绿**：必需项全过；可选/推荐项里
  `Sandboxing (user namespaces)`、`Macvlan`、`IPv6 NAT`、`CPU limit`、
  `Process limit`、`Cgroup namespace` 全部打勾
- **启动容器后 App 立即显示“运行中”** —— `0012` 的 NSpid 模拟生效
  （`/proc/<init>/status` 出现 `NSpid: <host_pid> 1`）
- 7 个模块加载：`lkm4ctr`、`devtmpfs_lkm`、`ip6table_nat`、`macvlan`、
  `droid_lkm_pids`、`droid_lkm_cpu`、`uart_guard`
- 两个 `[SKIP]` 均为预期：`vkms` 默认关闭（已有 Adreno 的 `renderD128`），
  `mali_nsfix` 因无 `/dev/mali0` / `mali_kbase` 跳过
- `droid_lkm_pids` 布局校验 `controllers=7 (built against 7)`；
  `droid_lkm_cpu` `cpu.max emulation active`
- `boot-completed` 已清零开机计数，无卡死

早前 `45852211799` 的 userns 验证：

- `unshare -Ur true` = 0，`uid=0`，`uid_map`/`gid_map` = `0 0 1`
- 范围映射 `0 0 65536` 通过（父进程写子进程）
- `unshare -Urm` + `mount -t tmpfs` 成功
- 8 个模块（当时包含 `vkms`）全部加载

---

## 6. 与 phDroid 的取舍

| | 本仓库（`droidspaces_lkm`） | phDroid（`phdroid`） |
|---|---|---|
| userns | 真实 `struct user_namespace` | 模拟（只为 check 绿） |
| `unshare -Ur` / `uid_map` | ✓ | ✗ |
| 加载器 | 上游 `service.sh` + `ko_switch` | 带 crash/blocked/生存窗口 |
| WebUI | 上游（模块/路线/日志） | 上游 `main-native` |
| 模块 ID | `droidspaces_lkm` | `phdroid` |

两者互斥，只能启用一个。

---

## 7. 目录

```
ci/        精确 KDIR、模块构建、manifest 工具、打包
scripts/   build_modules.sh（config-driven）、vkms/macvlan 补丁、符号清单
patches/   应用到 cyanmint/lkm4ctr 的补丁（0001–0012）
module/    KernelSU 模块模板（service.sh / action.sh / i18n.sh / webroot）
extra/     hk、kallrecon、cgrouplimits、devtmpfs、net_ip6nat、mali_nsfix、uart_guard
docs/      上游文档与 CHANGELOG
prebuilt/  上游预编译产物
```

---

## 8. 维护

- **同步上游**：

  ```sh
  git remote add upstream https://github.com/misaka5202/droidspaces-lkm.git
  git fetch upstream master
  git merge upstream/master
  ```

  冲突处理：保留 `ci/`、`scripts/build_modules.sh` 的 config 判断、
  `patches/0012-*`、hummer workflow；其余取上游。
- **patch 顺序**：`git apply` 按文件名字典序；本 fork 的 patch 必须排在上游最后
  一个之后（当前 `0012`）。新增 patch 后本地按序验证：

  ```sh
  git clone --depth=1 -b lkm4ctr https://github.com/cyanmint/lkm4ctr.git /tmp/lkm4ctr
  for p in patches/*.patch; do
    git -C /tmp/lkm4ctr apply --check "$p" || echo "FAIL $p"
    git -C /tmp/lkm4ctr apply "$p"
  done
  ```

- **Windows 上改文件**：仓库有 `.gitattributes`（`*.patch -text`、`*.sh eol=lf`），
  不要手工把 patch 存成 CRLF。
- **OTA**：内核 commit 没变只换 `manifest_url`；变了两个 URL 一起换并重跑。

---

## 9. 已知限制

- 只支持 `target-release` 记录的这一颗内核（当前 `6.6.144-4k-g01ee97578159`）。
- 模块 ID 是 `droidspaces_lkm`，会替换上游模块；`updateJson` 已删除，避免被通用
  GKI 包自动覆盖。
- userns 是 vendored 的真实实现，但内核本身没有 `CONFIG_USER_NS=y`，`setns` 等
  路径可能不完整；不要当完整安全边界。
- `droid_lkm_pids` / `droid_lkm_cpu` 用 kprobe + 运行时符号解析，最坏是加载失败；
  可用 `ko_switch` 关掉排查。
- `vkms` 没有 GPU 后端，Mesa 会落回 `llvmpipe`（CPU 软件渲染），不要当性能方案。
- `ko_switch` / `route` 改动都要**重启**才生效。
- 首次刷入请保留 fastboot / recovery 回滚手段。
