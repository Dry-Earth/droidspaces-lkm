# hummer 精确内核构建（OnePlus Ace 5 Pro / LineageOS 24）

这是 [misaka5202/droidspaces-lkm](https://github.com/misaka5202/droidspaces-lkm) 的
fork，增加了**按设备精确内核**构建的通道。上游已同步到 `42897af`
（v0.1.21 + 5 个纯文档提交），合并提交为 `ddf7c81`。

构建只使用 OTA `build-manifest.xml` 钉住的工具，不再包含 DDK 容器路径。

## 已验证结果

| 项目 | 值 |
|---|---|
| 设备 | OnePlus Ace 5 Pro（`hummer`） |
| ROM | LineageOS 24.0（20261113 OTA） |
| 内核 | `6.6.144-4k-g01ee97578159` |
| kernel commit | `01ee97578159bc9cb2a60f559d20510ce33add6a` |
| `droidspaces check` | **全部 ✓**（PID / IPC / userns / CPU limit / Process limit） |
| 模块加载 | 8/8，`boot-completed` 正常，无卡死报告 |

发布：

| Release | ZIP sha256 |
|---|---|
| `hummer-manifest-43875314497` | `74cc0089958e594498264c9b7d85ff5b6a7ee8b84e2f462f66f45b6877693575` |

## 工具来源（全部来自 manifest）

| 工具 | manifest 项目 | revision |
|---|---|---|
| clang | `platform/prebuilts/clang/host/linux-x86` | `29182889…`（clang-r596125） |
| make / bison / flex | `platform/prebuilts/build-tools` | `9b6c8c6a…` |
| pahole / kernel tools | `kernel/prebuilts/build-tools` | `811c6e29…` |
| boot.img 解包 | `platform/system/tools/mkbootimg` | `4a27dd13…` |
| 内核 / modules | `LineageOS/android_kernel_oneplus_sm8750{,-modules}` | `01ee9757…` / `e05c031c…` |

宿主只安装 LineageOS 构建文档要求的系统包（`build-essential`、`libssl-dev`、
`python3`、`perl`、`rsync` 等）；KDIR 和 8 个 `.ko` 都用 manifest 里的 clang
在 runner 上原生编译。

## 工作流

GitHub → Actions → **`[hummer] Build from manifest tools`** → Run workflow：

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
| `ci/build-kdir-host.sh` | 用 manifest clang 在 runner 上编精确 KDIR |
| `ci/build-hummer-modules-host.sh` | 用精确 KDIR 编 8 个模块 |
| `ci/fetch-manifest-tools.sh` | 按 manifest revision 下载 clang / build-tools / kernel-build-tools / mkbootimg |
| `ci/parse-manifest.py` | 解析 kernel / modules / clang / build-tools / mkbootimg |
| `ci/adapt-lkm4ctr.py` | 适配厂商内核的 `backing_file_open(const struct file *, …)` |
| `ci/package-hummer.py` | 打包 KernelSU ZIP，删除 `updateJson` |
| `scripts/build_modules.sh` | 支持 `KSRC_OVERRIDE` / `LKM4CTR_DIR` |
| `extra/cgrouplimits/cpu_mod.c` | 补 `MODULE_IMPORT_NS(VFS_internal_…)` |
| `.github/workflows/build-hummer-manifest.yml` | 构建入口 |

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
- **同步文档**：本 fork 保留上游 `README.md` / `README.zh-CN.md` / `docs/`；
  合并时只合文档，不覆盖 `ci/`、`scripts/`、`extra/` 的本地修改。
- **OTA**：内核变化后必须重跑工作流，否则模块 vermagic 不匹配。

## 已知限制

- 只支持 `target-release` 记录的这一颗内核（当前 `6.6.144-4k-g01ee97578159`）。
- 模块 ID 是 `droidspaces_lkm`，会替换上游模块；`updateJson` 已删除，避免被
  通用 GKI 包自动覆盖。
- `service.sh` 会在开机时加载 `droid_lkm_pids` / `droid_lkm_cpu`（kprobe + 运行时
  符号解析）。若遇到卡开机，可在模块目录放 `disable_pids` / `disable_cpu` 后重启排查。
- `lkm4ctr` 会改写内核入口；userns 不是完整安全边界，不要把不可信程序放进去。
- 首次刷入请保留 fastboot / recovery 回滚手段。
