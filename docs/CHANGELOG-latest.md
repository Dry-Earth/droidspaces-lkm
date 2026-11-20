## v0.1.28

### 修复

**`update.json` 指向的 changelog 不再丢英文段。** `scripts/gen_release_meta.py`
切版本条目时只按传入的 `--version` 原样匹配标题，而两份 changelog 的标题形状
不同：`docs/CHANGELOG.md` 是 `## v0.1.28`，`docs/CHANGELOG.en.md` 是
`## 0.1.28 - 2026-11-20`（不带 `v`）。于是 `--version v0.1.28` 在英文那份上
永远匹配不到，`docs/CHANGELOG-latest.md` 静默丢掉整段英文——KernelSU 更新
弹窗只剩中文。现在两种形状都试。

### 新增

**「操作」按钮新增 Docker / iptables 能力诊断（[#5](https://github.com/misaka5202/droidspaces-lkm/issues/5)）。**
从 `/proc/config.gz` 读 `CONFIG_NF_TABLES`、`CONFIG_BRIDGE_NETFILTER`、
`CONFIG_IP_NF_IPTABLES`、`CONFIG_NETFILTER_XTABLES_COMPAT`、`CONFIG_IP_NF_NAT`，
如实报出并给一行机器可读的 `nft_status`。这条诊断回答的是用户实际卡住的地方：

```
  [--]   没有 nf_tables —— iptables-nft 与本内核无法通信，请改用 iptables-legacy
  [OK]   legacy iptables + IPv4 NAT（docker --bridge=none --network=host 可用）
  [--]   docker bridge 拿不到 NAT（没有 BRIDGE_NETFILTER）—— 请用 --network=host
  nft_status nf_tables=no legacy=yes ipv4_nat=y bridge_netfilter=no
```

**「操作」按钮新增 tmpfs ACL/xattr 诊断（[#6](https://github.com/misaka5202/droidspaces-lkm/issues/6)）。**
读 `CONFIG_TMPFS_XATTR` 与 `CONFIG_TMPFS_POSIX_ACL`，让用户一眼看到「容器内
`setfacl` / `setcap` 会不会失败」。（该诊断的代码自 `4f8ed4be` 起就在仓库里，
但那两次提交都晚于 v0.1.27 tag，所以已发布的包里没有它——本版本第一次把它
发出去。）

### 文档与说明

- **README §10.5：Docker 起不来的完整排查**（中英文）。两个根因都是编译期内核
  配置，任何内核模块都补不齐：七个 GKI KMI 的 `gki_defconfig` 全都没有
  `CONFIG_NF_TABLES`（`iptables-nft` 没有可用的 netfilter ABI），也没有
  `CONFIG_BRIDGE_NETFILTER`（GKI 树里连 `br_netfilter.c` 都没有，docker 默认的
  bridge 模式因此拿不到 NAT）。给出两条可行路径：宿主
  `dockerd --bridge=none` + 容器 `--network=host`（与上游 `lkm4ctr` 手册一致），
  或在容器内切 `iptables-legacy`。
- **部署文档 §11.1：容器内 tmpfs 的 setfacl / setcap**（[#[6](https://github.com/misaka5202/droidspaces-lkm/issues/6)）。
  给出四条容器侧规避：静态 `resolv.conf`、`security.wrappers = { }`、关掉
  bpf-firewall，以及用 `lxc.mount.entry` 把 `/run` 预挂到 ACL/xattr 可用的
  data 分区。
- WebUI 的性能与开机状态改进（缓存刷新、开机选项开关、黑名单提示、两次点击
  确认重启）在 [PR #7](https://github.com/misaka5202/droidspaces-lkm/pull/7) 中，
  等待真机回归后再合入——本版本**不含**这部分改动。

### 引用

- [#5 — Docker 启动失败：failed to create NAT chain DOCKER](https://github.com/misaka5202/droidspaces-lkm/issues/5)
- [#6 — tmpfs xattr missing on MEIZU 21 Pro](https://github.com/misaka5202/droidspaces-lkm/issues/6)
- [PR #7 — WebUI speed/UX + boot-state handling](https://github.com/misaka5202/droidspaces-lkm/pull/7)

---

## 0.1.28 - 2026-11-20

### Fixed

**The changelog behind `update.json` no longer loses its English half.**
`scripts/gen_release_meta.py` sliced the version entry by matching the
`--version` argument verbatim, but the two changelogs use different heading
shapes: `docs/CHANGELOG.md` writes `## v0.1.28`, `docs/CHANGELOG.en.md` writes
`## 0.1.28 - 2026-11-20` (no `v`). So `--version v0.1.28` never matched the
English file and `docs/CHANGELOG-latest.md` silently dropped the whole English
section — the KernelSU update dialog showed Chinese only. Both shapes are now
tried.

### Added

**The Action button now reports Docker / iptables capability
([#5](https://github.com/misaka5202/droidspaces-lkm/issues/5)).** It reads
`CONFIG_NF_TABLES`, `CONFIG_BRIDGE_NETFILTER`, `CONFIG_IP_NF_IPTABLES`,
`CONFIG_NETFILTER_XTABLES_COMPAT` and `CONFIG_IP_NF_NAT` from
`/proc/config.gz`, prints the verdict and one machine-readable `nft_status`
line. It answers the question users actually hit:

```
  [--]   nf_tables absent — iptables-nft cannot talk to this kernel; use iptables-legacy
  [OK]   legacy iptables + IPv4 NAT (docker --bridge=none --network=host works)
  [--]   docker bridge NAT unavailable (no BRIDGE_NETFILTER) — use --network=host
  nft_status nf_tables=no legacy=yes ipv4_nat=y bridge_netfilter=no
```

**The Action button now reports tmpfs ACL/xattr capability
([#6](https://github.com/misaka5202/droidspaces-lkm/issues/6)).** It reads
`CONFIG_TMPFS_XATTR` and `CONFIG_TMPFS_POSIX_ACL`, so it is visible at a
glance whether `setfacl` / `setcap` will fail inside a container. (The code
has been in the tree since `4f8ed4be`, but both that commit and the
documentation commit landed after the v0.1.27 tag, so no published package
ever carried it — this release ships it for the first time.)

### Documentation

- **README §10.5: full troubleshooting for a Docker daemon that will not
  start** (both languages). Both root causes are compile-time kernel options
  that no module can supply: none of the seven GKI KMIs' `gki_defconfig`
  carries `CONFIG_NF_TABLES` (so `iptables-nft` has no netfilter ABI to talk
  to) and none carries `CONFIG_BRIDGE_NETFILTER` (`br_netfilter.c` is not even
  in the GKI tree, so Docker's default bridge network has no NAT there
  either). Two workable paths are given: host-side
  `dockerd --bridge=none` plus `--network=host` in the container (as the
  upstream `lkm4ctr` manual documents), or switching the container to
  `iptables-legacy`.
- **Deploy guide §11.1: container tmpfs `setfacl` / `setcap`**
  ([#6](https://github.com/misaka5202/droidspaces-lkm/issues/6)). Four
  container-side workarounds: a static `resolv.conf`, `security.wrappers =
  { }`, turning bpf-firewall off, and pre-mounting `/run` from an
  ACL/xattr-capable data partition via `lxc.mount.entry`.
- WebUI performance and boot-state handling (cached refresh, boot option
  switches, blacklist notice, two-tap reboot) live in
  [PR #7](https://github.com/misaka5202/droidspaces-lkm/pull/7), pending
  on-device regression — this release does **not** contain them.

### References

- [#5 — Docker fails to start: failed to create NAT chain DOCKER](https://github.com/misaka5202/droidspaces-lkm/issues/5)
- [#6 — tmpfs xattr missing on MEIZU 21 Pro](https://github.com/misaka5202/droidspaces-lkm/issues/6)
- [PR #7 — WebUI speed/UX + boot-state handling](https://github.com/misaka5202/droidspaces-lkm/pull/7)
