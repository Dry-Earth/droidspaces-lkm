# mali_nsfix

[中文](README.zh-CN.md)

Redirect `find_get_pid()` calls made by the Mali `kbase` driver so that GPU
context creation works from inside a PID namespace, without rebuilding the
vendor module.

## Problem

`kbase_create_context()` (`drivers/gpu/arm/midgard/context/mali_kbase_context.c`)
does:

```c
kctx->tgid  = current->tgid;              /* initial PID-namespace value */
rcu_read_lock();
pid_struct  = find_get_pid(kctx->tgid);   /* searched in current's namespace */
if (pid_struct) {
    task = pid_task(pid_struct, PIDTYPE_PID);
    if (task) { get_task_struct(task); kctx->task = task; }
    else     { err = -ESRCH; }
    put_pid(pid_struct);
} else {
    dev_err(dev, "Failed to get pid pointer for %s/%d", current->comm, current->pid);
    err = -ESRCH;
}
rcu_read_unlock();
if (unlikely(err))
    return NULL;
```

`task_struct->tgid` is always the value in the initial namespace, while
`find_get_pid()` resolves through `find_vpid()`, which searches the caller's
active namespace. For a container process the two disagree, the lookup fails,
`kbase_create_context()` returns `NULL`, and `kbase_file_create_kctx()` maps
that to `-ENOMEM` — so userspace never sees `-ESRCH` and the only evidence is
the `dmesg` line above.

Android's own processes are unaffected: for them both values name the same
task.

The failure chain is indirect, which is why it gets misread as a userspace or
EGL problem:

```
mali: Failed to get pid pointer for <comm>/<pid>     (dmesg)
  -> kbase_create_context() = -ESRCH
  -> kbase_file_create_kctx() maps it to -ENOMEM
  -> eglInitialize()/Vulkan init fails (EGL_NOT_INITIALIZED / no context)
  -> compositor starts with no GPU and dies or shows a blank screen
```

Checking `/proc/config.gz` will not tell you this: it can be stale, and the
relevant question ("does the running driver resolve pids in the caller's
namespace?") is a runtime property. Verify on the device, as above.

## Fix

A kprobe on `find_get_pid()`. When the caller's return address lies inside a
module whose name starts with `mali_kbase`, the call is redirected to
`get_task_pid(current->group_leader, PIDTYPE_PID)`.

The replacement returns the same task the vendor patch obtains with
`current->group_leader`, and the reference it takes is balanced by the
driver's own `put_pid()`. Because a host process would have resolved to its
group leader anyway, redirecting unconditionally for kbase callers needs no
namespace test: it is a no-op on the host and the fix in a container.

Caller attribution uses `within_module()`, a `static inline` in `module.h`
that resolves `struct module` layout at compile time. No symbol lookups, no
dependency on the vendor module's own symbols.

## Dry run (first-install preflight)

`nshf_activate=0` loads the module **without arming anything**:

```sh
insmod mali_nsfix.ko nshf_activate=0
```

It still validates `struct module`, proves the hook point exists by
registering and immediately unregistering a kprobe on `find_get_pid()`,
resolves `mali_kbase` if it is present, and exports what it found. Nothing is
redirected, so this is the safe way to answer "would this work here?" on an
unverified device. The module stays resident and removable.

State is readable without unloading:

```sh
P=/sys/module/mali_nsfix/parameters
cat $P/nshf_active      # 1 = kprobe armed, 0 = dry-run / not armed
cat $P/nshf_probe_ok    # 1 = find_get_pid probe registration succeeded
cat $P/nshf_layout_valid# 1 = struct module layout self-check passed
cat $P/nshf_driver      # bound module name, "(none)" if not loaded yet
cat $P/nshf_seen        # intercepted calls since load (approximate)
cat $P/nshf_hits        # calls actually redirected (approximate)
```

The module package wires this up: `touch <module dir>/mali_nsfix_dryrun`
before boot loads `nshf_activate=0`; `action.sh doctor` prints the same state
plus a machine-readable `nshf_status ...` line. Default (`nshf_activate=1`)
is unchanged behaviour.

## Why not rebuild `mali_kbase.ko`

That path needs the vendor driver source, symbol CRC matching against the
running kernel, and either replacing the module in `vendor_dlkm` or
`rmmod`-ing a driver Android is actively using. The second option panics on
the next GPU fence, because the hardware composer can still hold a fence when
the old module goes away. A kprobe needs none of that and survives an OTA.

## Measured

OPPO PHZ110, MediaTek MT6989, `mali_kbase_mt6989_r44`, Android 17, kernel
6.1.157, Droidspaces 7.2.0. `test/kbase_ctx_test.c` run from inside the
container:

| state | VERSION_CHECK | SET_FLAGS | `dmesg` |
| --- | --- | --- | --- |
| module not loaded | 0, API 1.0 | **-1, `errno=12` (ENOMEM)** | `Failed to get pid pointer for ctx/14508` |
| module loaded | 0, API 1.0 | **0, context created** | nothing |

Five consecutive runs with the module loaded: 5/5 succeeded, zero
`Failed to get pid pointer` lines. Also verified as uid 1000 rather than root.

## Overhead

Interception counters are exported as module parameters, so the cost can be
read without unloading:

```sh
cat /sys/module/mali_nsfix/parameters/nshf_seen   # every intercepted call
cat /sys/module/mali_nsfix/parameters/nshf_hits   # calls actually redirected
```

Measured on the device above, 60-second window:

```
nshf_seen:  +5 in 60 s      (0.083 calls/s system-wide)
nshf_hits:  +0 in 60 s      (no GPU context was created during the window)
cumulative: 1800 intercepted, 44 redirected  (2.4% are Mali callers)
```

At 1-3 us per kprobe trap that works out to **0.000008% - 0.000025% CPU**.
`find_get_pid()` is not a hot function: five calls per minute across the whole
system. None of them are on the per-frame GPU path - `kbase_create_context()`
calls it once per context, and workload submission does not call it at all, so
rendering throughput is unaffected.

## Why not ftrace

ftrace would avoid the breakpoint and the single-step, and with
`FTRACE_OPS_FL_IPMODIFY` the handler could rewrite `regs->pc` the way livepatch
does. It is not available here:

```
DDK build tree:  # CONFIG_FUNCTION_TRACER is not set
device kernel:   # CONFIG_FUNCTION_TRACER is not set
```

Without `CONFIG_FUNCTION_TRACER` the compiler inserts no `__fentry__` call
sites, so dynamic ftrace has nothing to patch. `CONFIG_HAVE_DYNAMIC_FTRACE_WITH_REGS`
being `y` only means the architecture supports the technique, not that it is
enabled.

An ftrace backend was written and compiled successfully on all seven KMIs, but
it compiled to nothing on every one of them. It was removed rather than shipped
as dead code. Revisit only if a target kernel has `CONFIG_FUNCTION_TRACER=y` -
and note that the measured kprobe cost above makes that unlikely to be worth
the complexity.

## Prior art

The bug and the source-level fix are not new. What is new here is the delivery:
a standalone module that fixes a stock driver at runtime.

- **Droidian / Halium porting notes** (public 2026-07-28),
  [porting-notes.md §3](https://github.com/note10lite-droidian/docs/blob/main/docs/research/porting-notes.md):
  documents the same `find_get_pid(kctx->tgid)` failure for Waydroid/Anbox on
  Mali and the source fix `get_pid(task_tgid(current))`, which they report is
  present in some vendor DDK drops (`bv_r26p0`/`bv_r32p1`/`bv_r38p1`).
  If your device's driver already contains that fix, this module redirects
  calls that would have succeeded anyway - harmless, but also unnecessary.
- **shr-distribution/meta-smartphone** (2026-10-18),
  [commit 1c9d86e](https://github.com/shr-distribution/meta-smartphone/commit/1c9d86e1e8af42483507e1e894f8c75ad6f8692a):
  rebuilds `mali_kbase_mt6789.ko` and loads it from a `vendor_dlkm-override`
  directory ahead of the container, so the vendor init finds it already
  loaded. Same bug; still needs driver source, matching CRCs and a rebuilt
  `.ko`.
- **[live-gpu-driver](https://github.com/insterbridge/live-gpu-driver)**:
  a KernelSU/APatch module that swaps *userspace* GPU drivers with bind mounts.
  Its limitation section states the kernel-side driver cannot be swapped live -
  which is exactly why redirecting the call is the practical route on Mali.
- **[Shikochin/Droidspaces-LKM](https://github.com/Shikochin/Droidspaces-LKM)**:
  the other Droidspaces LKM. It supplies PID/IPC namespaces, devtmpfs and user
  namespaces, but nothing for Mali. The dry-run convention, fingerprint gating
  idea and `validation.json` release evidence were borrowed from it (see
  `ORIGIN`).

## Risks and limits

These are the ways this module gives a wrong answer rather than an error. Each
one has been considered; none is addressed by adding a symbol lookup.

### struct module layout mismatch

`within_module()` is a static inline reading `core_layout` fields out of
`struct module`. The module is built against the DDK headers, the kernel on the
device is the vendor's build, and anything that changes `struct module` shifts
those offsets. The test device has `CONFIG_MODULE_SCMVERSION=y`, a vendor
addition absent from the DDK tree.

Wrong offsets mean wrong caller classification. A false negative just leaves the
redirect off. A false positive is the dangerous one: an unrelated
`find_get_pid(nr)` gets rewritten to the caller's own group leader, so `waitid`,
`kill` or `pidfd_open` receive a pid for the wrong task. No error is logged; the
caller acts on the wrong process.

`nshf_layout_ok()` guards this before the probe is armed: two of the module's own
addresses must classify as inside `THIS_MODULE`, and the core text size must be a
plausible allocation. It cannot prove the layout is byte-exact - a partially
shifted struct could still pass - so it is a tripwire, not a proof. It is
recorded in `nshf_layout_valid`.

The size read follows whichever layout the build headers use: `core_layout`
before 6.4, `mem[MOD_TEXT]` from 6.4 on (upstream replaced `struct
module_layout` with the `mem[]` array). The guard therefore compiles on every
supported KMI; the runtime tripwire decides whether it holds.

### mali_kbase built into vmlinux

`nshf_resolve_mali()` walks the module list. A kernel with `CONFIG_MALI` built
in rather than as a module has no entry to find, so the lookup fails, the module
loads, and nothing is redirected. There is no error - GPU context creation keeps
failing exactly as it did before. Built-in kbase cannot be handled from a module
without knowing its text range by other means.

### CONFIG_KPROBES not set

`register_kprobe` would not exist and the module fails to load with
`Unknown symbol register_kprobe`. That one is at least visible.

### Counters are approximate

`nshf_seen` and `nshf_hits` are plain `unsigned long` incremented from every CPU
without serialisation. Concurrent hits are lost. Use them to judge order of
magnitude, not to account exactly.

### Lazy resolution cost when the driver never appears

If `mali_kbase` is not present at load time the handler walks the module list on
each intercepted call until it is found. That walk is why the resolved pointer
is cached. `nshf_resolve_left` caps it at 4096 attempts and then stops looking;
on the test device (about 5 interceptions per minute) that is far longer than any
boot.

### Verified on one device

Everything here was measured on OPPO PHZ110 / MT6989 / `6.1.157-android14-11`
with `mali_kbase_mt6989_r44`. Other vendor Mali drivers, other kernels and
built-in configurations are untested.

## ioctl numbers

`VERSION_CHECK` on this build is `0xC0048034`, not `0xC0048000`
(`_IOWR(0x80, 0, 4)`). The nr-0 form returns `-EPERM` — the driver keeps that
slot for the reserved variant. `SET_FLAGS` is `0x40048001` and needs a valid
pointer to a `u32`; passing `NULL` yields `-EFAULT`.

## Scope

This unblocks GPU context creation only. Userspace still has to load the
vendor driver into the container and provide a render node; that is the
libhybris path, and it is independent of this module.

## Build

Built in-tree against a DDK kernel tree like the other modules in `extra/`:

```sh
make -C "$KDIR" M="$PWD" modules
```

## Test

```sh
# inside the container
gcc -O2 -static -o kbase_ctx_test test/kbase_ctx_test.c
./kbase_ctx_test

# on the host, with/without the module
rmmod mali_nsfix && droidspaces --name=Debian run -- /kbase_ctx_test
insmod mali_nsfix.ko && droidspaces --name=Debian run -- /kbase_ctx_test
```