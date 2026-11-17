# Changelog

This is the English changelog. Entries before v0.1.23 exist only in Chinese;
see [CHANGELOG.md](CHANGELOG.md). Version numbering rationale is documented
there as well.

## v0.1.24

### Fixed

**The `get_fs_type("overlay")` override is now disabled by default.**

That hook redirected every global `get_fs_type("overlay")` lookup to the module's
own overlayfs. When the running kernel already has `CONFIG_OVERLAY_FS` this is not
needed, but it does contend for the same VFS state as other modules that operate at
that layer — notably NoMount (`nomount.ko`, which hijacks `s_d_op` / `d_op` /
`d_revalidate`; see `nm_hijack_dentry_ops`).

The two together produce dentries whose `d_op` and `d_fsdata` disagree. Observed
panic:

```
Unable to handle kernel NULL pointer dereference at virtual address 0x10
pc : ovl_dentry_revalidate_common+0x38/0xac
Call trace:
  ovl_dentry_revalidate_common
  ovl_dentry_revalidate
  path_openat
  __arm64_sys_openat
  vendor_kernel_hook_openat [lkm4ctr]
```

i.e. a plain `openat` on an overlayfs file finds `dentry->d_fsdata` NULL.

Controlled by the `overlay_override` module parameter (bool, default `N`). To use
the vendored implementation on a kernel without overlayfs:

```sh
insmod lkm4ctr.ko overlay_override=Y
```

When disabled, `vns_ovl_init()` is skipped entirely (no `ovl_inode` slab is
created) and `vns_ovl_exit()` is guarded by `vns_ovl_ready`. Diagnostics report the
current state:

```
overlay_override: off (running kernel's overlayfs in use)
```

### Changed

`vns_ovl_exit()` guards `kmem_cache_destroy()` against NULL and clears the pointer.

### Security audit fixes

The whole-repo audit produced these hardening changes. None of them is a
regression fix; they close paths that were reachable but had not been hit.

**Refuse the overlayfs takeover when VFS symbol resolution failed.**
`vns_ovl_vfs_compat_resolve()` deliberately continues past individual failures
(the lite variant depends on that: an early return made `mq_init_ns` fail with
`-ENOMEM`). But with `overlay_override=Y`, the `#define` form
`(*vns_ovl_vfsc_notify_change)(...)` becomes a **NULL call** when a pointer did
not resolve, and the same-name forwarders silently no-op the permission and
attribute operations the vendored overlayfs relies on. Resolution stays
non-fatal; only the *takeover* is now refused, falling back to the running
kernel's own overlayfs. New accessor `vns_ovl_vfs_compat_resolve_failed()` lives
in `glue/vendor_kernel_ovl_vfs_compat.c` (part of `LKM4CTR_BASE_OBJS`, so both
the full and lite builds link it).

**Never free a trampoline without a real grace period.** `hk_wait_tasks_rcu()`
used to return `void` and merely warn when `synchronize_rcu_tasks` could not be
resolved; its callers freed anyway. A core already running inside the trampoline
then hit a use-after-free. It now returns whether a grace period actually
elapsed, and all three release sites (`hk_inline_unhook`, `hk_inline_exit`,
`shadow_inline_remove`) keep the trampoline instead — the pending entry also
blocks `rmmod`, so the outcome is a bounded leak and a refused unload, never a
dangling executable page. `shadow_inline_remove()` previously used plain
`synchronize_rcu()`, which does not wait for a CPU that already fetched the
detour; it uses the tasks-RCU helper like the rest of the engine. Applied to
both engine copies (`extra/devtmpfs/hk/` and the `glue/hk/` copy in patch 0005).
`hk_binder.c` was left alone — it is dead code, absent from every object list.

**GPL source snapshot applied the local patches to the wrong path.**
`git -C /tmp/src/lkm4ctr apply "PWD/$p"` was missing the `$` (literal `PWD`),
and the trailing `2>/dev/null || true` swallowed every failure — so the source
tarball shipped *without* the 0001–0010 patches while the `.ko` files came from
patched sources, silently. Now resolves `"$PWD"/patches/*.patch` and fails the
job on error.

**A root script wrote through a world-writable path.**
`action.sh`'s `/proc` mount probe used `/data/local/tmp/.dsp_proctest`, where any
user could pre-create a symlink and have root's `mount` follow it onto an
attacker-chosen target. Moved to `/mnt` (root-owned) with an explicit `-L` guard,
and `rm -rf` replaced by `mkdir`/`rmdir`.

**Reclaimed cgroup entries were removed after a stale check.**
In both `pids_reap_fn()` and `cpu_tick()`, the "should reclaim" test ran outside
the mutex while the writer (`pids_max_write` / `cpu_max_write`, holding that mutex
throughout) can reactivate the very same entry — reuse keeps the same pointer and
just clears `dead`, so the existing `xa_load(...) == p` recheck did not exclude
it. The condition is now re-evaluated under the lock before erasing.

**`msg()` rejects `%n`.** Templates are static in-repo strings, so `%n` could not
reach the format position; the guard is defense in depth against a future
template or an accidental external value.

### Verified

Full KMI matrix (all seven) builds green, including the aggregate module and the
lite variant, confirming the new accessor links in both. Device smoke test on
PHZ110 (MT6989, `6.1.157`): PID/IPC/UTS/user/net/cgroup namespaces, in-container
`/proc` mount (214 nodes), devtmpfs, `/dev/dri/renderD128`, veth creation, binder
nodes, emulated `pids.max`/`cpu.max`, and the export-symbol check (0 missing of
781 rows) all pass, with no kernel anomalies in `dmesg`.

## v0.1.23

`versionCode` is written at build time (`YYYYMMDDnn` = date*100 + hour*4 + minute/15,
see `.github/workflows/build.yml`). It must fit in int32.

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
