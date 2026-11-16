# `extra/` — loadable modules

[中文](README.zh-CN.md)

Out-of-tree modules built by `scripts/build_modules.sh` for each supported KMI.
None requires a kernel rebuild or a boot image flash.

| Directory | Output | Purpose |
|---|---|---|
| `cgrouplimits/` | `droid_lkm_pids.ko`, `droid_lkm_cpu.ko` | Emulate the pids controller and `cpu.max` on kernels built with `CONFIG_CGROUP_PIDS=n` / `CONFIG_CFS_BANDWIDTH=n` |
| `devtmpfs/` | `devtmpfs_lkm.ko` | Port of `drivers/base/devtmpfs.c` for kernels built with `CONFIG_DEVTMPFS=n` |
| `mali_nsfix/` | `mali_nsfix.ko` | Redirect the Mali `kbase` driver's `find_get_pid()` so GPU contexts can be created inside a PID namespace |
| `net_ip6nat/` | `ip6table_nat.ko` | IPv6 NAT for container networks |
| `uart_guard/` | `uart_guard.ko` | Guard serial sysfs reads against an uninitialised `tty_port` |

## Handling unexported kernel symbols

Several of these modules need kernel functions that vendor kernels may not export.
Four distinct techniques are in use; which one applies depends on the symbol and
on the kernel's configuration.

| Technique | Used by | Notes |
|---|---|---|
| `KallRecon` (`kr/`) name lookup into the kallsyms table | `devtmpfs`, `cgrouplimits` | Works for symbols that exist but lack `EXPORT_SYMBOL`. `devtmpfs_lkm` needs 18 such symbols. |
| Module parameters carrying addresses read from `/proc/kallsyms` at load time | `net_ip6nat` | KASLR changes addresses every boot, so they cannot be baked in. 9 functions. |
| Definition of same-named forwarding functions that call a runtime-resolved address | `lkm4ctr` (upstream patch `0009`) | Lets every caller — including inline expansions from kernel headers — link to the local definition, so no static import is produced. |
| Source rewriting at build time | `macvlan` | `scripts/patch_macvlan.py` removes three symbol dependencies whose semantics permit substitution. |

Any function that reaches a resolved address through an indirect call must be
annotated `__nocfi`; `CONFIG_CFI_CLANG=y` kernels otherwise trap on the call.

`scripts/build_modules.sh` emits `symcheck-<kmi>.txt` alongside the `.ko` files.
It lists every undefined symbol each module imports, so a device can be checked
against its own export table without relying on `dmesg`.

## Per-module documentation

- [`cgrouplimits/README.md`](cgrouplimits/README.md) ([中文](cgrouplimits/README.zh-CN.md))
- [`mali_nsfix/README.md`](mali_nsfix/README.md) ([中文](mali_nsfix/README.zh-CN.md))

`devtmpfs/`, `net_ip6nat/`, and `uart_guard/` are documented by their source
headers.