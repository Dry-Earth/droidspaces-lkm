## v0.1.24

### 修复

**`get_fs_type("overlay")` 劫持改为默认关闭。**

该 hook 把全局的 `get_fs_type("overlay")` 全部重定向到模块自带的 overlayfs。
运行内核已有 `CONFIG_OVERLAY_FS` 时这不是必要功能，却会和其它在 VFS 层动手脚
的模块争用同一块状态 —— 典型是 NoMount（`nomount.ko`，劫持 `s_d_op` / `d_op` /
`d_revalidate`，见 `nm_hijack_dentry_ops`）。

两者叠加会产生 `d_op` 与 `d_fsdata` 不配对的 dentry。实测崩溃：

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

即一次普通 `openat` 访问 overlayfs 上的文件时，`dentry->d_fsdata` 为空。

改为模块参数 `overlay_override`（bool，默认 `N`）。需要在没有 overlayfs 的内核上
使用自带实现时：

```sh
insmod lkm4ctr.ko overlay_override=Y
```

未启用时 `vns_ovl_init()` 不执行（不创建 `ovl_inode` slab），`vns_ovl_exit()` 有
`vns_ovl_ready` 保护。诊断输出会报告当前状态：

```
overlay_override: off (running kernel's overlayfs in use)
```

### 变更

`vns_ovl_exit()` 的 `kmem_cache_destroy()` 增加 NULL 保护并清空指针。

### 安全性审计修复

全仓库审计带来的一批加固。这些都不是回归修复，而是堵上「可达但尚未被触发」
的路径。

**符号解析失败时拒绝接管 overlayfs。**
`vns_ovl_vfs_compat_resolve()` 刻意对单个符号失败继续执行（精简版依赖这一点：
提前返回会让 `mq_init_ns` 以 `-ENOMEM` 失败）。但在 `overlay_override=Y` 下，
宏形式 `(*vns_ovl_vfsc_notify_change)(...)` 在指针未解析时就是**对 NULL 的调用**，
同名转发函数还会把 vendored overlayfs 依赖的权限/属性操作静默变成空操作。
解析本身仍然非致命；现在只拒绝「接管」这一步，退回运行内核自带的 overlayfs。
新增访问器 `vns_ovl_vfs_compat_resolve_failed()` 位于
`glue/vendor_kernel_ovl_vfs_compat.c`（属 `LKM4CTR_BASE_OBJS`，full/lite 都能链接）。

**没有真正等到宽限期就不释放 trampoline。**
`hk_wait_tasks_rcu()` 原本返回 `void`，`synchronize_rcu_tasks` 解析不到时只警告，
调用方照样释放——已跑进 trampoline 的 CPU 随即 use-after-free。现在它返回
是否真的等到了宽限期，三处释放点（`hk_inline_unhook`、`hk_inline_exit`、
`shadow_inline_remove`）改为保留该页；pending 条目同时会挡住 `rmmod`，所以结果
是有界泄漏 + 拒绝卸载，绝不会留下悬空可执行页。`shadow_inline_remove()` 原来
用普通 `synchronize_rcu()`，等不到已取跳板、还没被调度走的 CPU，现改用与引擎
其余部分一致的 tasks-RCU helper。两份引擎副本（`extra/devtmpfs/hk/` 与
0005 里的 `glue/hk/`）都改了。`hk_binder.c` 未动——它是死代码，不在任何 obj 列表里。

**GPL 源码快照把本地补丁打到了错误路径。**
`git -C /tmp/src/lkm4ctr apply "PWD/$p"` 少了 `$`（字面量 `PWD`），末尾的
`2>/dev/null || true` 又吞掉全部失败——源码包实际**没带** 0001–0010 补丁，而
`.ko` 来自打过补丁的源码，且毫无报错。现改为解析 `"$PWD"/patches/*.patch`，
失败即中断任务。

**root 脚本经由全局可写路径写入。**
`action.sh` 的 `/proc` 挂载探针用 `/data/local/tmp/.dsp_proctest`，任何用户都能
预置符号链接，让 root 的 `mount` 跟到攻击者选定的目标上。已移到 `/mnt`
（root 独有）并加 `-L` 兜底检查，`rm -rf` 换成 `mkdir`/`rmdir`。

**回收 cgroup 条目前用了过期判断。**
`pids_reap_fn()` 与 `cpu_tick()` 的「该回收」判断都在 mutex 之外，而写方
（`pids_max_write` / `cpu_max_write`，全程持同一把 mutex）可以把同一条目重新激活
——复用沿用同一个指针、只清 `dead`，原有的 `xa_load(...) == p` 复校验挡不住它。
现在改为拿锁后重算条件再 erase。

**`msg()` 拒绝 `%n`。** 模板是仓库内静态字符串，`%n` 进不了格式位；这道守卫属于
纵深防御，防将来有人塞入带 `%n` 的模板或误传外部值。

### 验证

全 KMI 矩阵（7 个）全部编译通过，含聚合模块与精简变体，证明新访问器在两种构建下
都能链接。真机冒烟（PHZ110 / MT6989 / `6.1.157`）：PID/IPC/UTS/user/net/cgroup
命名空间、容器内挂 `/proc`（214 节点）、devtmpfs、`/dev/dri/renderD128`、veth 创建、
binder 节点、仿真 `pids.max`/`cpu.max`、导出符号检查（781 行中缺失 0）全部通过，
`dmesg` 无内核异常。

---

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
