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