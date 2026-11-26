# cgroup Limits Emulation (`--cpus` / `--pids-limit`)

[中文](README.zh-CN.md)

Makes Droidspaces' `--cpus` and `--pids-limit` functional on stock kernels
built with `CONFIG_CFS_BANDWIDTH=n` and `CONFIG_CGROUP_PIDS=n`.

Verified on OPPO Find X7 (MT6989, `6.1.157-android14-11`, KMI `android14-6.1`).

```
droid_lkm_pids.ko   ported from Plan B of ai-luo2006/droidspaces-6.12-pmb110
droid_lkm_cpu.ko    time-slice throttling, original implementation
```

---

## Motivation

| Feature | Kernel state | Symptom |
|---|---|---|
| `--pids-limit` | `CONFIG_CGROUP_PIDS=n`; the pids subsystem does not exist | Writing `pids.max` fails; the preflight check reports failure |
| `--cpus` | `CONFIG_CFS_BANDWIDTH=n`; `cpu.max` write path and enforcement (`tg_set_cfs_bandwidth`, `throttle_cfs_rq`) are compiled out entirely | Writing `cpu.max` fails; the preflight check reports failure |

Both configurations remove code at compile time. An LKM cannot re-enable removed
code paths; it can only emulate them — supplying the interface, the accounting,
and the enforcement.

---

## pids module (Plan B, ported from 6.12)

Four layers, matching upstream structure:

| Layer | Mechanism |
|---|---|
| Visibility | kretprobe on `cgroup_controllers_show` / `proc_cgroupstats_show`, appending `"pids cpu"` |
| Files | `cgroup_add_dfl_cftypes(memory_cgrp_subsys, ...)` to attach `pids.max`, `pids.current`, `pids.stats` |
| Enforcement | **inline-first** on `cgroup_can_fork`: on limit the wrapper returns `-EAGAIN` without running the original body; `cgroup_post_fork` increments; `cgroup_exit` decrements. Falls back to kprobe when inline cannot be installed (module parameter `route`: `0` auto / `1` inline / `2` kprobe) |
| Translation | kprobe on `cgroup_subtree_control_write`: strip `+pids` / `+cpu`, substitute `+memory` where required |

Fork rejection returns `-EAGAIN` to userspace without executing the original
function, so the errno matches what a real controller would produce. The three
enforcement hooks are hit on every fork/exit, which is why they are inline-first:
a kprobe costs an exception round trip per hit.
controller would produce.

Constraints:

- **Layout self-check.** `struct css_set` begins with
  `subsys[CGROUP_SUBSYS_COUNT]`. The runtime controller count is read from
  `cgroup_subsys[]` and used to correct the offset. Two independent checks
  (`init_css_set.dfl_cgrp`, `init_task.cgroups`) must both pass, otherwise the
  fork probes are not installed.
- **Repeated `+pids` enable returns EFAULT.** The translation layer rewrites the
  buffer only when memory is not yet enabled; when it is, the write buffer is
  cleared and the call returns without effect.
- **Never sleep in a kprobe handler.** The "is memory already enabled?" check
  must not use `kernfs_find_and_get()`: it goes through
  `down_read(&kernfs_rwsem)` and can schedule, while a pre-handler runs in
  atomic context with preemption and interrupts disabled. Measured on PHZ110 /
  Anland 5.x as `BUG: scheduling while atomic` followed by watchdog reboot.
  The module now trusts only its own observation table: any cgroup whose write
  mentioned `+memory` (including a direct user write, which passes through the
  same hook) is remembered, and later `+pids` writes consult that table. The
  table is guarded by `spin_lock_irqsave`; `-memory` and `cgroup_rmdir` clear
  entries. Only blind spot: cgroups where memory was enabled before this module
  loaded - those fall back to the old behaviour (`-EFAULT` after rewrite), never
  a panic.
- **The visibility layer must also advertise `cpu`.** Droidspaces reads
  `cgroup.controllers` to select the v2 path. Advertising only `pids` routes
  `--cpus` through the v1 path, which then fails.

### On-device verification

```
$ dmesg | grep droid_lkm_pids
layout verified: controllers=7 (built against 7)
pids limit enforcement active (emulated pids controller)

# manual test, pids.max=5
iteration 1 current=2 ... iteration 4 current=5   <- reaches the limit
iteration 5 current=2 ... refused=3                <- rejected

# Droidspaces container, --pids-limit=64
pids.max = 64
after 60 forks: refused=2
in container: /bin/sh: can't fork: Resource temporarily unavailable
```

---

## cpu module (original implementation)

CFS bandwidth enforcement is absent from the kernel, so this module substitutes
time-slice throttling:

```
cpu.max file    attached to the memory subsystem; parses "<quota_us> <period_us>"
accounting      delayed_work samples every 10 ms: walks the cgroup subtree,
                accumulates task_sched_runtime() in ns
window check    window_used = accumulated - window_base; over quota when >= quota
over quota      css_task_iter walks tasks and sends SIGSTOP
window end      reset base, send SIGCONT
```

### Failure modes encountered

Each of these produced a panic or a silent no-op during development.

1. **hrtimer context panic.** `filp_open` enters the VFS layer, which cannot be
   called from hrtimer interrupt context; it faults in `do_mem_abort` and panics.
   Moved to `delayed_work` (process context).

2. **CFI trap panic.** With `CONFIG_CFI_CLANG=y`, indirect calls through
   function pointers resolved via KallRecon trip the CFI check. Every function
   containing such a call is annotated `__nocfi`.

3. **SELinux denies reading `cpu.stat` through the VFS (EACCES).** `filp_open`
   cannot open cgroup files under the module's domain. Switched to kernel
   internal data.

4. **`struct cgroup.bstat` offset mismatch.** The device kernel is at a
   different commit than the local tree; layout validation passed but `bstat`
   read as zero. Replaced with per-task `task_sched_runtime` accumulation.

5. **Sample interval equal to window period.** With a 100 ms tick and a 100 ms
   period, every sample either set the base or reset the window, so the quota
   check was never reached. Tick reduced to 10 ms.

### On-device verification

```
$ dmesg | grep droid_lkm_cpu
layout ok: controllers=7 bstat_off=984
over quota (62593 >= 50000), SIGSTOP     <- --cpus=0.5, over within window
window reset, SIGCONT
over quota (57774 >= 50000), SIGSTOP
window reset, SIGCONT

ps inside container shows T (stopped)    <- processes actually frozen
```

---

## Known limitations

| Item | Detail |
|---|---|
| Migrated processes are not counted | Accounting covers processes forked inside the cgroup; a process migrated in is not counted. Diverges from a real controller. |
| cpu uses time slices, not smooth throttling | SIGSTOP is coarser than CFS throttling; a process can be paused for the remainder of a window. |
| 10 ms accounting granularity | Accurate for busy loops; may miss short bursts. |
| `rmmod` clears configuration | `cpu.max` / `pids.max` must be written again after reload. Restarting the container through Droidspaces suffices. |
| Freezing sends SIGSTOP only | SIGSTOP cannot be caught or ignored, so this covers all container processes. |

---

## Loading

```bash
su -c 'insmod /data/local/tmp/droid_lkm_pids.ko'
su -c 'insmod /data/local/tmp/droid_lkm_cpu.ko'

# unload (stop containers first)
su -c 'rmmod droid_lkm_cpu; rmmod droid_lkm_pids'
```

Load order is irrelevant. Both modules must be present when Droidspaces creates
a container; otherwise the limit write fails and is skipped, and the container
must be restarted to retry.

---

## Building

```bash
# WSL, kernel tree at ~/zram/common (6.1.157)
bash /mnt/c/nomount/wsl/build_pids.sh
bash /mnt/c/nomount/wsl/build_cpu.sh
```

Requirements: clang 20, a configured kernel tree with `out/`, and KallRecon
from `net_ip6nat/kr/` copied into this directory.

## Files

```
extra/cgrouplimits/
├── Makefile
├── pids_mod.c          pids emulation (6.12 Plan B port, plus "cpu" in visibility layer)
├── cpu_mod.c           cpu.max time-slice throttling
└── kr/                 KallRecon (copied from net_ip6nat/kr)
```

## Shared code (`common.c`)

Both modules originally carried their own cgroup layout validation. Of the
901 / 902 lines, only 15% were byte-identical — the cpu copy was derived from
the pids one, and `cpu_mod.c` still carries the comment "same approach as
droid_lkm_pids". The real defect was that validation strength had diverged:

| Check | pids | cpu (before) |
|---|---|---|
| `init_css_set.dfl_cgrp == &cgrp_dfl_root.cgrp` | yes | yes |
| `init_task.cgroups == &init_css_set` | yes | **missing** |

With only the first check, a miscalculated `task_struct.cgroups` offset writes
into the wrong memory on the fork path, and the resulting corruption surfaces
far from the faulting access.

Both are now in `common.c` / `common.h`:

```
ctl_read_ptr()         safe kernel pointer read (copy_from_kernel_nofault)
ctl_is_kptr()          kernel pointer range test
ctl_anchors_resolve()  resolve the four layout anchor symbols
ctl_subsys_count()     count real controllers in cgroup_subsys[]
ctl_layout_probe()     correct compile-time offsets, run both checks
```

Both modules call `ctl_layout_probe()`, so the cpu side gains the second check
it previously lacked.

`common.o` is linked into both `.ko` files; the modules remain independent and
can be inserted and removed separately. This duplication is intentional, as
with `kr/` (KallRecon is likewise linked into each).

## Why IPC key indexing does not use the kernel rhashtable

`struct ipc_namespace` is allocated by the module with `kzalloc` using the
compile-time `sizeof`, but `rhashtable_init()` is a kernel function that
initialises the embedded `key_ht` inside `ids[]` according to the **kernel's**
`struct rhashtable` layout. If the target kernel's structure is larger than the
one used at build time, the initialisation writes past the end of the allocation
— heap corruption that surfaces as a random panic or hang.

(`Dere3046/_patchHarmony` issue #12 measured a `0x18` difference on an MT6989
`6.1.145`: `sizeof(ipc_ids)` 272 versus 280, three times.)

Resolution: `vendor/ipc/` replaces key indexing with a module-private singly
linked list (`ipc_keylist_lookup/insert/unlink/clear`), so
`nm -u *.ko | grep rhashtable` reports nothing. SysV IPC object counts inside a
container are small, making linear scan cost negligible in exchange for complete
insensitivity to kernel structure layout.