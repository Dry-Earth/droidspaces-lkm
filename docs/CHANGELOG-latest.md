## v0.1.23

`versionCode` 由构建时写入（`YYYYMMDDHHMM`，见 `.github/workflows/build.yml`）。

### 修复

### 修复

**`versionCode` 超出 int32 范围，KernelSU 从未能解析。**

KernelSU 的 `Module.kt` 将 `versionCode` 声明为 `Int`，`Downloader.kt` 用
`.toInt()` 解析。此前 `build.yml` 生成的值为 `%Y%m%d%H%M`（12 位），
本应为 `202611170004`，超出 `Integer.MAX_VALUE` (2147483647) 94 倍，
`.toInt()` 抛出 `NumberFormatException`，更新检查失败。

v0.1.22（`202611161425`）同样超出范围，因此该问题自引入以来一直存在。

改为 `YYYYMMDDnn`：

```
versionCode = YYYYMMDD * 100 + 小时 * 4 + 分钟 / 15
```

取值范围 `2026111700`–`2026111795`，上限 2,026,117,995 < 2,147,483,647，
每日 96 个槽位。超出范围时构建直接失败。分 KMI 包改为读取
`dist/version-code.txt`，与全 KMI 包使用同一个值。
`scripts/gen_release_meta.py` 增加 int32 上限校验。


**符号兼容层扩展到全部七个 KMI。** v0.1.22 仅覆盖 MID 层（5.15 / 6.1），
OLD（5.10）与 NEW（6.6 / 6.12）的兼容清单缺少相应条目。

`lkm4ctr` 的 VFS 类静态导入（`nm -u` 实测）：

| KMI | 层 | v0.1.22 | v0.1.23 | 降幅 |
|---|---|---|---|---|
| android12-5.10 | OLD | 29 | 1 | −97% |
| android13-5.10 | OLD | 29 | 1 | −97% |
| android13-5.15 | MID | 29 | 1 | −97% |
| android14-5.15 | MID | 29 | 1 | −97% |
| android14-6.1 | MID | 6 | 2 | −67% |
| android15-6.6 | NEW | 37 | 2 | −95% |
| android16-6.12 | NEW | 40 | 2 | −95% |

统计范围为 VFS 辅助函数类（`d_` / `i_` / `inode` / `clear_` / `vfs_` / `iget` /
`percpu_` 等前缀），不含全部未定义符号。残余项为 `__percpu_down_read` 与
`percpu_counter_add_batch`，属内核内置原语，无裁剪先例。

新增覆盖的符号（均经 `nm -u` 确认不再静态导入）：`d_instantiate`、`d_obtain_alias`、
`d_splice_alias`、`d_add`、`d_make_root`、`d_path`、`ihold`、`clear_inode`、
`clear_nlink`、`drop_nlink`、`inc_nlink`、`set_nlink`、`inode_init_once`、
`unlock_new_inode`、`iget5_locked`、`ilookup5`、`init_special_inode`、
`inode_set_flags`、`inode_init_owner`、`setattr_prepare`、`touch_atime`、
`sync_filesystem`、`vfs_fsync`、`vfs_fsync_range`、`truncate_inode_pages_final`、
`current_umask`、`in_group_p`、`capable_wrt_inode_uidgid`、`notify_change`、
`finish_open`、`generic_read_dir`、`backing_file_user_path`、`get_next_ino`、
`__insert_inode_hash`。

**`capable_wrt_inode_uidgid`（issue #2 根因）。** 由 `vendor/fs/overlayfs/inode.c`
调用。经 Meizu 21 Pro（6.1.25）boot.img 提取的 `__ksymtab_strings`（6594 项）确认：
该内核导出 `lkm4ctr` 需要的 207 个符号中的 206 个，唯一缺失项即为本符号。
已为 OLD / MID / NEW 三层分别配置重定向。

**macvlan。** `dev_mc_add`、`dev_mc_del`、`netdev_is_rx_handler_busy`、
`dev_forward_skb`、`eth_header_cache`、`eth_header_cache_update` 改为同名转发
函数 + 运行时解析。v0.1.22 将 `dev_mc_add_excl` 改写为 `dev_mc_add`，但后者在
部分内核同样未导出，未解决问题。

**vkms。** `drmm_crtc_init_with_planes` 替换为 `drm_crtc_init_with_planes`。
两者签名一致（均为 variadic），上游均 `EXPORT_SYMBOL`。CRTC 由
`drm_mode_config_cleanup()` 统一释放。

**droid_lkm_cpu / droid_lkm_pids。** `cgroup_add_dfl_cftypes` 改为运行时解析
（`cpu_ksym()` / `kallrecon_klp()`），与同模块内已有的 `cgroup_rm_cftypes`
处理方式一致。

### 新增

**`scripts/gen_vfs_compat.py`。** 从内核 BTF 提取函数原型，生成指针声明、
同名转发函数与解析表。用于新增符号，避免手工书写签名错误。

**`scripts/verify_against_bootimg.py`。** 从 `boot.img` 提取 `__ksymtab_strings`，
与 `.ko` 的未定义符号表比对，输出每个模块的缺失项。

**`lkm4ctr_lite`。** 不含 vendored overlayfs 的变体（`VNS_LITE=1`）。`service.sh`
优先加载完整版，失败时回退。适用于裁掉 overlayfs 独占符号的内核。

**崩溃现场采集。** `post-fs-data.sh` 检测 `/sys/fs/pstore/`，非空时复制到
`/data/adb/droidspaces_lkm.d/pstore-<timestamp>.txt`。

### 变更

**构建期符号检查。** `scripts/build_modules.sh` 的 `BAD_SYMS` 清单由 12 项扩至
53 项；新增 `MUST_NOT_APPEAR` 15 项硬性检查，命中即 `exit 1`。

**`zram-lkm`。** 增加构建期导出检查（见该仓库 `2ba41c3`）。

### 版本变体

| 符号 | 变化 | 处理 |
|---|---|---|
| `kmem_cache_alloc_lru` | 6.10 起为宏，符号名 `_noprof` | 条件条目宏 + 同名函数 |
| `__percpu_counter_init` | 6.6 起为 `_many`（多 `nr_counters`） | 条件条目宏 + 同名函数 |
| `d_tmpfile` | 6.7 起更名 `d_mark_tmpfile` | 条件条目宏 |
| `d_parent_ino` | 6.12 新增 | 条件条目宏 + 同名函数 |
| `generic_encode_ino32_fh` | 6.9 新增 | 条件条目宏 |

符号由内核头文件的 `static inline` 调用时，`#define` 无法覆盖（内联体在
compat 头之前解析），须使用同名转发函数。`generic_read_dir`、`kmem_cache_alloc_lru`、
`__percpu_counter_init_many`、`percpu_counter_destroy_many`、`d_parent_ino` 属此类。

### 验证

- 七个 KMI 构建通过；`BAD_SYMS` 检查结果全部为 0。
- Meizu 21 Pro（6.1.25）：10 个模块，缺失 0。数据源为报告者提供的 `boot.img`。
- PHZ110（MediaTek mt6989 / 6.1.157）：10 个模块，缺失 0。数据源为
  `/proc/kallsyms` 的 `__ksymtab_` 条目（22081 项）。
- PHZ110 实机加载：`macvlan` 模块 `insmod` 成功（`rc=0`），
  `ip link add ... type macvlan` 成功；容器能力检查 8/8 通过，`Unknown symbol` 计数 0。

### 已知问题

- issue #1（Redmi Note 12 Turbo / 5.10.269）报告的无限重启未复现确认。
  该设备 `/sys/fs/pstore` 为空，表明为挂起而非 panic；需报告者后续反馈。
- issue #3 / #4（6.12.23-android16-5）报告的符号已修复，但缺少对应设备内核，
  未做同类验证。

---

## v0.1.23

`versionCode` is written at build time (`YYYYMMDDHHMM`, see
`.github/workflows/build.yml`).

### Fixed

### Fixed

**`versionCode` exceeded int32 range; KernelSU has never been able to parse it.**

KernelSU declares `versionCode` as `Int` in `Module.kt` and parses it with
`.toInt()` in `Downloader.kt`. `build.yml` previously generated `%Y%m%d%H%M`
(12 digits); this release would have produced `202611170004`, which exceeds
`Integer.MAX_VALUE` (2147483647) by a factor of 94, causing
`NumberFormatException` and aborting the update check.

v0.1.22 (`202611161425`) was equally out of range, so this has been broken since
the scheme was introduced.

Changed to `YYYYMMDDnn`:

```
versionCode = YYYYMMDD * 100 + hour * 4 + minute / 15
```

Range `2026111700`–`2026111795`, maximum 2,026,117,995 < 2,147,483,647, 96 slots
per day. The build fails if the value would overflow. Per-KMI packages now read
`dist/version-code.txt` instead of computing their own timestamp.
`scripts/gen_release_meta.py` now rejects a versionCode above int32.


**Symbol compatibility extended to all seven KMIs.** v0.1.22 covered only the
MID tier (5.15 / 6.1); the compat lists for OLD (5.10) and NEW (6.6 / 6.12) were
missing the corresponding entries.

VFS-class static imports of `lkm4ctr` (`nm -u`):

| KMI | Tier | v0.1.22 | v0.1.23 | Change |
|---|---|---|---|---|
| android12-5.10 | OLD | 29 | 1 | −97% |
| android13-5.10 | OLD | 29 | 1 | −97% |
| android13-5.15 | MID | 29 | 1 | −97% |
| android14-5.15 | MID | 29 | 1 | −97% |
| android14-6.1 | MID | 6 | 2 | −67% |
| android15-6.6 | NEW | 37 | 2 | −95% |
| android16-6.12 | NEW | 40 | 2 | −95% |

Scope is VFS helper functions (`d_`, `i_`, `inode`, `clear_`, `vfs_`, `iget_`,
`percpu_` prefixes), not all undefined symbols. The remaining entries are
`__percpu_down_read` and `percpu_counter_add_batch`, both kernel core
primitives with no trimming precedent.

Newly covered symbols (all confirmed absent from `nm -u`): `d_instantiate`,
`d_obtain_alias`, `d_splice_alias`, `d_add`, `d_make_root`, `d_path`, `ihold`,
`clear_inode`, `clear_nlink`, `drop_nlink`, `inc_nlink`, `set_nlink`,
`inode_init_once`, `unlock_new_inode`, `iget5_locked`, `ilookup5`,
`init_special_inode`, `inode_set_flags`, `inode_init_owner`, `setattr_prepare`,
`touch_atime`, `sync_filesystem`, `vfs_fsync`, `vfs_fsync_range`,
`truncate_inode_pages_final`, `current_umask`, `in_group_p`,
`capable_wrt_inode_uidgid`, `notify_change`, `finish_open`, `generic_read_dir`,
`backing_file_user_path`, `get_next_ino`, `__insert_inode_hash`.

**`capable_wrt_inode_uidgid` (root cause of issue #2).** Called from
`vendor/fs/overlayfs/inode.c`. Confirmed against the `__ksymtab_strings` table
(6594 entries) extracted from a Meizu 21 Pro (6.1.25) `boot.img`: that kernel
exports 206 of the 207 symbols `lkm4ctr` needs, and this is the only missing one.
Redirection is configured per tier (OLD / MID / NEW).

**macvlan.** `dev_mc_add`, `dev_mc_del`, `netdev_is_rx_handler_busy`,
`dev_forward_skb`, `eth_header_cache`, `eth_header_cache_update` now use
same-name forwarding functions with runtime resolution. v0.1.22 rewrote
`dev_mc_add_excl` as `dev_mc_add`, which is also unexported on some kernels.

**vkms.** `drmm_crtc_init_with_planes` replaced with
`drm_crtc_init_with_planes`. Both have identical variadic signatures and are
`EXPORT_SYMBOL`'d upstream. CRTCs are released by `drm_mode_config_cleanup()`.

**droid_lkm_cpu / droid_lkm_pids.** `cgroup_add_dfl_cftypes` now resolved at
runtime (`cpu_ksym()` / `kallrecon_klp()`), matching the existing handling of
`cgroup_rm_cftypes` in the same modules.

### Added

**`scripts/gen_vfs_compat.py`.** Extracts function prototypes from kernel BTF
and generates pointer declarations, same-name forwarding functions and a
resolution table. Prevents hand-written signature errors.

**`scripts/verify_against_bootimg.py`.** Extracts `__ksymtab_strings` from a
`boot.img`, compares it against a `.ko`'s undefined symbols, and reports missing
entries per module.

**`lkm4ctr_lite`.** Variant without the vendored overlayfs (`VNS_LITE=1`).
`service.sh` loads the full build first and falls back on failure. Targets
kernels that trim overlayfs-only symbols.

**Crash capture.** `post-fs-data.sh` checks `/sys/fs/pstore/` and, when
non-empty, copies the contents to
`/data/adb/droidspaces_lkm.d/pstore-<timestamp>.txt`.

### Changed

**Build-time symbol checks.** `BAD_SYMS` in `scripts/build_modules.sh` expanded
from 12 to 53 entries; `MUST_NOT_APPEAR` added with 15 entries and a hard
`exit 1` on match.

**`zram-lkm`.** Added build-time export check (commit `2ba41c3` in that repo).

### Version variants

| Symbol | Change | Handling |
|---|---|---|
| `kmem_cache_alloc_lru` | macro since 6.10, symbol renamed `_noprof` | conditional entry macro + same-name function |
| `__percpu_counter_init` | `_many` since 6.6 (extra `nr_counters`) | conditional entry macro + same-name function |
| `d_tmpfile` | renamed `d_mark_tmpfile` since 6.7 | conditional entry macro |
| `d_parent_ino` | added in 6.12 | conditional entry macro + same-name function |
| `generic_encode_ino32_fh` | added in 6.9 | conditional entry macro |

When a symbol is called from a kernel header's `static inline` body, `#define`
cannot intercept it (the inline is parsed before the compat header); a same-name
forwarding function is required. `generic_read_dir`, `kmem_cache_alloc_lru`,
`__percpu_counter_init_many`, `percpu_counter_destroy_many` and `d_parent_ino`
fall into this category.

### Verification

- All seven KMIs build; `BAD_SYMS` reports zero for each.
- Meizu 21 Pro (6.1.25): 10 modules, 0 missing. Source: `boot.img` supplied by
  the reporter.
- PHZ110 (MediaTek mt6989 / 6.1.157): 10 modules, 0 missing. Source:
  `__ksymtab_` entries from `/proc/kallsyms` (22081 total).
- PHZ110 live load: `macvlan` `insmod` succeeded (`rc=0`);
  `ip link add ... type macvlan` succeeded; 8/8 capability checks passed;
  `Unknown symbol` count 0.

### Known issues

- issue #1 (Redmi Note 12 Turbo / 5.10.269): reported infinite reboot not
  reproduced. `/sys/fs/pstore` was empty on that device, indicating a hang
  rather than a panic. Awaiting further reports.
- issue #3 / #4 (6.12.23-android16-5): reported symbols fixed, but no matching
  device kernel was available for equivalent verification.
