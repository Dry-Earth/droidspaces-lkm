# hummer 精确内核构建（OnePlus Ace 5 Pro / LineageOS 24）

这是 [misaka5202/droidspaces-lkm](https://github.com/misaka5202/droidspaces-lkm)
的 fork，只加了一条**按设备精确内核构建**的通道。

## 为什么需要它

上游的 `build.yml` 用 DDK 镜像里的 `android15-6.6` 通用 GKI KDIR 编译。同一个
KMI 不代表厂商内部 ABI 一致：OnePlus Ace 5 Pro（`hummer`）的内核是

```text
6.6.144-4k-g01ee97578159
```

厂商裁掉了不少导出符号和配置。通用 GKI 编出来的 `lkm4ctr.ko` 能过
`struct module` 尺寸检查，但 `insmod` 时会因符号/CRC 不匹配失败，于是
`droidspaces check` 里 PID / IPC / userns / CPU limit 仍然是 ✗，而原生就有的
devtmpfs / macvlan / IPv6 NAT 是 ✓。

本分支把 `scripts/build_modules.sh` 的 `KSRC` 和 KDIR 换成**用你这台机器的
boot.img 编出来的精确内核**，其余流程（`lkm4ctr` 源码 + `patches/`、模块模板、
`service.sh` 的 KMI 选择、vcms/macvlan 从内核源码取）保持不变。

## 构建

GitHub → Actions → **`[hummer] Build exact-KDIR modules`** → Run workflow：

| 输入 | 说明 |
|---|---|
| `boot_img_url` | OTA 的 `boot.img` |
| `manifest_url` | 同一 OTA 的 `build-manifest.xml` |
| `ddk_release` | 默认 `20260828` |
| `publish_release` | 成功后发 Release |

流程：

1. 解析 manifest 里 kernel / modules / clang 的精确 revision；
2. 从 `boot.img` 提取真实 config / `uname -r` / 原厂 clang 版本；
3. 用原厂 clang 编出精确 KDIR（`kernel/out`）；
4. 克隆 `cyanmint/lkm4ctr` 并应用本仓库 `patches/*.patch`；
5. 用精确 KDIR + 精确内核源码执行 `scripts/build_modules.sh`；
6. 用本仓库 `module/` 模板打包成 `droidspaces-lkm-hummer-arm64.zip`。

产物里的模块名是 `*-android15-6.6.ko`，`service.sh` 从 `uname -r` 推出
`android15-6.6` 后加载它们。

## 安装

1. 先在 KernelSU 里卸载/停用旧的 `droidspaces_lkm`，重启。
2. 安装 `droidspaces-lkm-hummer-arm64.zip`，重启。
3. 看日志：

```sh
su -c 'cat /data/adb/droidspaces_lkm.log'
su -c 'droidspaces check'
```

## 注意

- `module.prop` 里的上游 `updateJson` 已删掉，避免 KernelSU 用通用 GKI 包覆盖
  这个精确构建。
- 首次构建是新仓库的冷 ccache，KDIR 约 25–30 分钟；之后的 OTA 只有内核 commit
  变化时才需要重跑。
- `build_modules.sh` 要求 8 个模块齐全才会返回 0；本分支的打包脚本只强制要求
  `lkm4ctr`（PID/IPC 的关键），其余缺失会在 `build-info.txt` 里列出来。
- 仍然不是零风险：模块会改写内核入口，第一次装请保留可回滚手段。
