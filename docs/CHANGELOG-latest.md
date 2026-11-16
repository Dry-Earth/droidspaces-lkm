## v0.1.23

### 修复

- 符号兼容层扩展到全部七个 KMI。`lkm4ctr` 的 VFS 类静态导入从
  29/29/29/29/6/37/40 降至 **1/1/1/1/2/2/2**
  （android12-5.10 / 13-5.10 / 13-5.15 / 14-5.15 / 14-6.1 / 15-6.6 / 16-6.12）。
- `capable_wrt_inode_uidgid`（issue #2 根因）：经 Meizu 6.1.25 的 boot.img
  确认，是 `lkm4ctr` 在该内核上唯一缺失的符号。已为三层分别配置重定向。
- `macvlan`：`dev_mc_add`、`dev_mc_del`、`netdev_is_rx_handler_busy`、
  `dev_forward_skb`、`eth_header_cache`、`eth_header_cache_update`
  改为同名转发函数 + 运行时解析。
- `vkms`：`drmm_crtc_init_with_planes` 替换为 `drm_crtc_init_with_planes`
  （签名一致，上游均导出）。
- `droid_lkm_cpu` / `droid_lkm_pids`：`cgroup_add_dfl_cftypes` 改为运行时解析。

### 新增

- `lkm4ctr_lite`：不含 vendored overlayfs 的变体。overlayfs 独占符号被裁剪时
  自动回退，保留 PID/IPC/UTS namespace。
- 崩溃现场采集：`post-fs-data.sh` 检测 `/sys/fs/pstore/` 并保存。
- `scripts/gen_vfs_compat.py`：从内核 BTF 生成符号转发层。
- `scripts/verify_against_bootimg.py`：从 boot.img 提取导出表，验证模块可用性。

### 变更

- 构建期符号检查：`BAD_SYMS` 12 → 53 条；新增 `MUST_NOT_APPEAR` 15 条硬检查。

### 已知问题

- issue #1（Redmi Note 12 Turbo / 5.10.269）：无限重启未复现确认。该设备
  `/sys/fs/pstore` 为空，属挂起而非 panic。
- issue #3 / #4（6.12.23-android16-5）：符号已修复，缺对应设备内核，未做同类验证。

---
完整记录见 [CHANGELOG.md](CHANGELOG.md)。
