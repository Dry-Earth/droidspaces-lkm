# hummer 精确内核构建（OnePlus Ace 5 Pro / LineageOS 24）

这是 [misaka5202/droidspaces-lkm](https://github.com/misaka5202/droidspaces-lkm) 的
fork，增加了**按设备精确内核**构建的通道。上游已同步到 `89cbefc`（v0.1.29，
ko_switch + i18n + lkm4ctr-lite），合并提交 `77901a4`。

构建只使用 OTA `build-manifest.xml` 钉住的工具，不包含 DDK 容器路径。

## 已验证结果

| 项目 | 值 |
|---|---|
| 设备 | OnePlus Ace 5 Pro（`hummer`） |
| ROM | LineageOS 24.0，20261120 OTA |
| 内核 | `6.6.144-4k-g01ee97578159` |
| kernel commit | `01ee97578159bc9cb2a60f559d20510ce33add6a` |
| `droidspaces check` | **全部 ✓**（PID / IPC / userns / CPU limit / Process limit） |
| userns | 真实 `struct user_namespace`：`unshare -Ur true` = 0，`uid_map` = `0 0 65536` |
| 模块加载 | 本次应编的全部模块加载成功，`boot-completed` 正常，无卡死 |
| App 识别 | `/proc/<init>/status` 有 `NSpid: <host> 1`，Droidspaces 显示“运行中” |

发布记录：

| Release | ZIP sha256 | 说明 |
|---|---|---|
| `hummer-manifest-45852211799` | `74cc0089958e594498264c9b7d85ff5b6a7ee8b84e2f462f66f45b6877693575` | 真实 userns |
| `hummer-manifest-45861110289` | `080163934d558c17209b10cd58de7f02d195c2df47e9812ca9fe4c9e0ffe378a` | + NSpid 模拟 |
| `hummer-manifest-45862609906` | 同上 | + config-driven 模块集合（本机 config 下产物相同） |

## 工具来源（全部来自 manifest）

| 工具 | manifest 项目 | revision |
|---|---|---|
| clang | `platform/prebuilts/clang/host/linux-x86` | `29182889…`（clang-r596125） |
| make / bison / flex | `platform/prebuilts/build-tools` | `9b6c8c6a…` |
| pahole / kernel tools | `kernel/prebuilts/build-tools` | `811c6e29…` |
| boot.img 解包 | `platform/system/tools/mkbootimg` | `4a27dd13…` |
| 内核 / modules | `LineageOS/android_kernel_oneplus_sm8750{,-modules}` | `01ee9757…` / `e05c031c…` |

宿主只安装 LineageOS 构建文档要求的系统包（`build-essential`、`libssl-dev`、
`python3`、`perl`、`rsync` 等）；KDIR 与所有 `.ko` 都用 manifest 里的 clang
在 runner 上原生编译。

## 模块集合：内核缺什么才补什么

`scripts/build_modules.sh` 读解包出来的原厂 config（`build-config/stock.config`），
已启用的能力直接跳过，不再重复编一份同功能模块：

| 模块 | 跳过条件（原厂 config） |
|---|---|
| `lkm4ctr`（核心） | 始终构建 |
| `uart_guard`（tty 安全兜底） | 始终构建 |
| `devtmpfs_lkm` | `CONFIG_DEVTMPFS=y/m` |
| `macvlan` | `CONFIG_MACVLAN=y/m` |
| `ip6table_nat` | `CONFIG_IP6_NF_NAT` + `CONFIG_IP6_NF_TARGET_MASQUERADE` |
| `droid_lkm_pids` | `CONFIG_CGROUP_PIDS=y/m` |
| `droid_lkm_cpu` | `CONFIG_CFS_BANDWIDTH=y/m` |
| `vkms` | `CONFIG_DRM_VKMS=y/m` |

同时构建 `lkm4ctr-lite`（不带 vendored overlayfs 的回退版）和 `mali_nsfix`
（仅 Mali 设备会加载）。产物完整性检查按同一份 config 计算“本次应有”的模块，
不再硬编码 8 个；缺少任何一个都会让这一格红，避免发出残缺的包。

本机（20261120 LineageOS 内核）上述 CONFIG 全部为 n，所以实际仍编全部模块。

## 工作流

GitHub → Actions → **`[hummer] Build from manifest tools`** → Run workflow。

| 输入 | 说明 |
|---|---|
| `boot_img_url` | OTA 的 `boot.img` |
| `manifest_url` | 同一 OTA 的 `build-manifest.xml` |
| `publish_release` | 成功后发 Release |

首次冷缓存约 30 分钟；`tools/`（约 1.2 GiB）和 `ccache` 都会缓存，后续重跑明显更快。
OTA 后只要内核 commit 变了（`uname -r` 的 `g...` 变化），就换两个 URL 重跑。

## 相对上游的改动

| 文件 | 作用 |
|---|---|
| `.github/workflows/build-hummer-manifest.yml` | 构建入口（manifest 工具、AOSP 解包、无 DDK） |
| `ci/build-kdir-host.sh` | 用 manifest clang 在 runner 上编精确 KDIR |
| `ci/build-hummer-modules-host.sh` | 用精确 KDIR 编模块 |
| `ci/fetch-manifest-tools.sh` | 按 manifest revision 下载工具链 |
| `ci/parse-manifest.py` | 解析 kernel / modules / clang / build-tools / mkbootimg |
| `ci/adapt-lkm4ctr.py` | 适配厂商内核的 `backing_file_open(const struct file *, …)` |
| `ci/package-hummer.py` | 打包整份 `module/`（脚本 + i18n + WebUI），删掉 `updateJson` |
| `scripts/build_modules.sh` | config-driven 模块集合、`KSRC_OVERRIDE`、`LKM4CTR_DIR` |
| `patches/0012-nspid-status.patch` | 补 `proc_pid_status` 的 NStgid/NSpid/NSpgid/NSsid |

上游 patch（`0001`–`0011`）按顺序原样应用；`0012` 必须最后应用。

### 为什么需要 0012

Droidspaces 用 `/proc/<pid>/status` 的 `NSpid` 最后一位是否为 `1` 判断容器 init。
本机内核 `CONFIG_PID_NS=n`，`fs/proc/array.c` 里整段 NS 输出被编译掉，即使
lkm4ctr 用的是真实 `copy_pid_ns`，App 也看不到 NSpid。0012 用 `shadow_hook`
挂 `proc_pid_status`，按 `pid->numbers[]` 重建这段输出（逻辑与内核一致），
只对 `pid->level > ns->level` 的进程追加，宿主进程不受影响。

## 安装

1. 先卸载/停用旧的 `droidspaces_lkm`、`droidspaces_hummer`、phDroid 等
   namespace 模块并**重启**。
2. KernelSU 安装 `droidspaces-lkm-hummer-arm64.zip`，重启。
3. 验证：

```sh
su -c 'cat /data/adb/droidspaces_lkm.log'
su -c 'lsmod | grep -E "lkm4ctr|devtmpfs_lkm|droid_lkm|uart_guard"'
su -c '/data/local/Droidspaces/bin/droidspaces check'
su -c 'grep NSpid /proc/<容器init的宿主pid>/status'
```

4. userns 验证（应为真实映射，不是模拟）：

```sh
su -c 'unshare -Ur sh -c "id -u; cat /proc/self/uid_map"'
```

5. 验证模拟的 cgroup 限制（`--cpus` / `--pids-limit` 需要同时给 `--memory`）：

```sh
su -c 'droidspaces --name=box --rootfs=<rootfs> --memory=512M --cpus=0.5 --pids-limit=64 start'
su -c 'cat /sys/fs/cgroup/droidspaces/box/cpu.max'
su -c 'cat /sys/fs/cgroup/droidspaces/box/pids.max'
```

## WebUI / 模块开关

打包内容包含上游的 WebUI（`webroot/`）。KernelSU 里点模块的“打开”即可使用；
逐个模块的加载开关写在 `/data/adb/modules/droidspaces_lkm/ko_switch`，格式
`<name>=<0|1>`，WebUI 会读写这个文件。旧的 `disable_pids` / `disable_cpu`
文件仍兼容，但优先级低于 `ko_switch`。

## 维护

- **升级判断**：上游发 Release，或提交改了 `scripts/build_modules.sh`、
  `patches/*.patch`、`extra/**/*.c`、或 `cyanmint/lkm4ctr` 的 HEAD 时才需要重编；
  纯文档提交不需要。
- **同步上游**：`git merge upstream/master`，冲突时保留 `ci/`、`scripts/build_modules.sh`、
  `patches/0012-nspid-status.patch`、hummer workflow 的本地修改，其余取上游。
- **patch 顺序**：`git apply` 按文件名字典序；本 fork 的 patch 必须编号在
  上游最后一个 patch 之后（当前 `0012`）。
- **OTA**：内核变化后必须重跑工作流，否则模块 vermagic 不匹配。

## 已知限制

- 只支持 `target-release` 记录的这一颗内核（当前 `6.6.144-4k-g01ee97578159`）。
- 模块 ID 是 `droidspaces_lkm`，会替换上游模块；`updateJson` 已删除，避免被
  通用 GKI 包自动覆盖。
- `service.sh` 会在开机时加载 `droid_lkm_pids` / `droid_lkm_cpu`（kprobe + 运行时
  符号解析）。若遇到卡开机，可在模块目录写 `disable_pids` / `disable_cpu` 后重启排查。
- userns 是 lkm4ctr 里 vendored 的真实 `struct user_namespace`，但内核本身没有
  `CONFIG_USER_NS=y`，`setns` 等部分路径可能不完整；不要把它当成完整安全边界，
  不要把不可信程序放进去。
- 首次刷入请保留 fastboot / recovery 回滚手段。
