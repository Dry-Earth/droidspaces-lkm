# hummer 精确内核构建（OnePlus Ace 5 Pro / LineageOS 24）

这是 [misaka5202/droidspaces-lkm](https://github.com/misaka5202/droidspaces-lkm) 的
fork，只增加了一条**按设备精确内核构建**的通道，以及两处厂商 ABI 适配。

上游已同步到 `42897af`（v0.1.21 + 5 个纯文档提交），合并提交为 `ddf7c81`。
文档同步不改变任何 `.ko`、脚本或补丁。

## 已验证结果

| 项目 | 值 |
|---|---|
| 设备 | OnePlus Ace 5 Pro（`hummer`） |
| ROM | LineageOS 24.0（20261113 OTA） |
| 内核 | `6.6.144-4k-g01ee97578159` |
| kernel commit | `01ee97578159bc9cb2a60f559d20510ce33add6a` |
| `droidspaces check` | **全部 ✓**（PID / IPC / userns / CPU limit / Process limit 也通过） |
| 模块加载 | 8/8，开机 `boot-completed` 正常，无卡死报告 |
| Release | `hummer-43771876793` |
| ZIP sha256 | `eb386a9bf1e738eab62d9f5bce2ce95a6c6755c1489c95bc0c96a7c6ebe66586` |

产物：`droidspaces-lkm-hummer-arm64.zip`（仅 arm64、仅这一颗内核）。

## 为什么需要这个 fork

上游 `build.yml` 用 DDK 镜像里的**通用 GKI** `android15-6.6` KDIR 编译。同一个 KMI
不代表厂商内部 ABI 一致；hummer 的内核裁掉了不少导出符号和配置。

旧的上游包（v0.1.16–v0.1.18 的 6.6 包）甚至**没有包含 `lkm4ctr.ko`**，所以刷入后
只有原生功能是 ✓，PID / IPC / userns / CPU limit 一定是 ✗——这也是这个 fork 出现
的直接原因。

本 fork 改为：

1. 从 OTA 的 `boot.img` 提取真实 `.config`、`uname -r` 和原厂 clang 版本；
2. 用 `LineageOS/android_kernel_oneplus_sm8750` 的精确 commit 编出 KDIR；
3. 用这个 KDIR + 精确内核源码运行上游的 `scripts/build_modules.sh`；
4. 用上游的 `module/` 模板打包，KMI 仍标为 `android15-6.6`，`service.sh` 可正确选中。

## 相对上游的改动

| 文件 | 作用 |
|---|---|
| `ci/build-kdir.sh` | 在 DDK 容器里用原厂 clang + 设备 config 编精确 KDIR |
| `ci/parse-manifest.py` | 从 OTA manifest 解析 kernel / modules / clang revision |
| `ci/build-hummer-modules.sh` | 用精确 KDIR / 内核源码调用 `build_modules.sh` |
| `ci/adapt-lkm4ctr.py` | 适配厂商内核的 `backing_file_open(const struct file *, …)` |
| `ci/package-hummer.py` | 打包 KernelSU ZIP，删除 `updateJson`，避免被通用包覆盖 |
| `scripts/build_modules.sh` | 增加 `KSRC_OVERRIDE`，让 vkms/macvlan 取自目标内核树 |
| `extra/cgrouplimits/cpu_mod.c` | 补 `MODULE_IMPORT_NS(VFS_internal_…)` |
| `.github/workflows/build-hummer-exact.yml` | 上述流程的 CI |

## 构建

GitHub → Actions → **`[hummer] Build exact-KDIR modules`** → Run workflow：

| 输入 | 说明 |
|---|---|
| `boot_img_url` | OTA 的 `boot.img` |
| `manifest_url` | 同一 OTA 的 `build-manifest.xml` |
| `ddk_release` | 默认 `20260828` |
| `publish_release` | 成功后发 Release |

首次冷缓存约 28 分钟；ccache 会保存，后续重跑通常几分钟。OTA 后只要内核 commit
变了（`uname -r` 的 `g...` 变化），就换两个 URL 重跑。

## 安装

1. 先卸载/停用旧的 `droidspaces_lkm`、`droidspaces_hummer`、phDroid 等
   namespace 模块，**重启**。
2. KernelSU 安装 `droidspaces-lkm-hummer-arm64.zip`，重启。
3. 验证：

```sh
su -c 'cat /data/adb/droidspaces_lkm.log'
su -c 'lsmod | grep -E "lkm4ctr|devtmpfs_lkm|droid_lkm"'
su -c 'droidspaces check'
```

4. 验证模拟的 cgroup 限制（`--cpus` / `--pids-limit` 需要同时给 `--memory`）：

```sh
su -c 'droidspaces --name=box --rootfs=<rootfs> --memory=512M --cpus=0.5 --pids-limit=64 start'
su -c 'cat /sys/fs/cgroup/droidspaces/box/cpu.max'
su -c 'cat /sys/fs/cgroup/droidspaces/box/pids.max'
```

## 维护

- **升级判断**：上游发新 Release（v0.1.22+），或提交改到
  `scripts/build_modules.sh`、`patches/*.patch`、`extra/**/*.c`、或
  `cyanmint/lkm4ctr` 的 HEAD 时才需要重编；纯文档提交不需要。
- **同步文档**：本 fork 保留上游 `README.md` / `README.zh-CN.md` / `docs/`，
  合并上游时只合文档文件，不覆盖 `ci/`、`scripts/`、`extra/` 的本地修改。
- **OTA**：内核变化后必须重跑工作流，否则模块 vermagic 不匹配，会退回“只缺几项”。

## 已知限制

- 只支持 `target-release` 记录的这一颗内核（当前 `6.6.144-4k-g01ee97578159`）。
- 模块 ID 是 `droidspaces_lkm`，会替换上游模块；`updateJson` 已删除，避免被
  通用 GKI 包自动覆盖。
- `service.sh` 会在开机时加载 `droid_lkm_pids` / `droid_lkm_cpu`（kprobe + 运行时
  符号解析）。若遇到卡开机，可在模块目录放 `disable_pids` / `disable_cpu` 后重启排查。
- `lkm4ctr` 会改写内核入口；userns 不是完整安全边界，不要把不可信程序放进去。
- 首次刷入请保留 fastboot / recovery 回滚手段。
