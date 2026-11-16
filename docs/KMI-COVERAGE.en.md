# Module × KMI coverage

**8 modules × 7 KMIs = 56/56, all present.**

[**English**](KMI-COVERAGE.en.md) | [简体中文](KMI-COVERAGE.md)

| Module | 12-5.10 | 13-5.10 | 13-5.15 | 14-5.15 | 14-6.1 | 15-6.6 | 16-6.12 |
|------|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `lkm4ctr` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `devtmpfs_lkm` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `macvlan` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `ip6table_nat` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `vkms` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `droid_lkm_pids` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `droid_lkm_cpu` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `uart_guard` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |

Download the combined `droidspaces-lkm-arm64-<version>.zip` (picks the right build at boot
from the kernel release), or a per-KMI `droidspaces-lkm-<kmi>-arm64.zip`.

> **Do not trust the CI job status alone.** Since v0.1.20 the build fails the job
> when any of the eight modules is missing, but before that a partial build could
> still show green. The authoritative check is the artifact list — see
> [How to verify coverage](#how-to-verify-coverage).

## How each module is built

Every KMI is compiled against **its own kernel tree** (the DDK image's
`/opt/ddk/src/<kmi>`), never a copy shared across versions:

| Module | Source |
|--------|--------|
| `vkms` | `drivers/gpu/drm/vkms/` + the `DRIVER_RENDER` patch + CRC/DEBUG_FS stubbing |
| `macvlan` | `drivers/net/macvlan.c` |
| `lkm4ctr` | upstream repo (carries its own version adaptation) |
| `devtmpfs_lkm` | implemented here |
| `ip6table_nat` | implemented here (three signature branches: 5.10 / 5.15 / 6.1+) |
| `droid_lkm_pids` / `droid_lkm_cpu` | `extra/cgrouplimits/` (shares the layout probe in `common.c`) |
| `uart_guard` | `extra/uart_guard/` (kprobes, no version-dependent code) |

## The vkms `DRIVER_RENDER` patch

Upstream vkms declares `driver_features = MODESET | ATOMIC | GEM` — no
`DRIVER_RENDER`. `drm_dev_register()` only allocates a render minor when that
flag is present, so an unpatched vkms creates a card but **no**
`/dev/dri/renderD<N>`:

```
crw-rw-rw- 226,   1  card1          <- present
                                     <- renderD128 missing
```

Wayland compositors go through `gbm_create_device()` + `drmOpenRender()`, which
need exactly that render node. Without it they stop at:

```
CRIT: Couldn't open a gbm device   (OpenGL.cpp:351)
```

With the flag, the same module provides both halves:

```
crw-rw----  system system   226,   0  card0        (vendor display controller)
crw-rw-rw-  root   graphics 226,   1  card1        <- vkms KMS pipeline
crw-rw-rw-  root   graphics 226, 128  renderD128   <- vkms render node
```

`DRIVER_RENDER` only permits creating the render minor; it does not change
vkms's ioctl set.

The patch is applied by `scripts/patch_vkms_driver_features.py`, and
`build_modules.sh` **re-checks** that `DRIVER_RENDER` is actually present in the
file before compiling — if it is not, no artifact is shipped.

### The second vkms patch: CRC / DEBUG_FS

Upstream `vkms_composer.c` calls `drm_crtc_add_crc_entry()`, which lives in
`drivers/gpu/drm/drm_debugfs_crc.o` — and that object is gated by
`drm-$(CONFIG_DEBUG_FS)` in the DRM Makefile. **GKI's `gki_defconfig` never
enables `DEBUG_FS`**, so the symbol simply does not exist:

```
insmod: failed to load vkms.ko: Unknown symbol drm_crtc_add_crc_entry (err -2)
```

`scripts/patch_vkms_debugfs.py` removes those call sites. The script is
*tolerant per version*: a target whose vkms source has no such code counts as
success (5.10), a match is rewritten, and a mismatch skips the module rather
than forcing a bad patch.

## API differences between 5.10 and 5.15+

`ip6table_nat` needs three branches, split at two points:

| API | 5.10 | 5.15+ | 6.1+ |
|-----|:---:|:---:|:---:|
| `ip6t_do_table` | `(skb,state,table)` | same as 5.10 | `(priv,skb,state)` |
| `ip6t_register_table` | 5 args (+`**res`) | 4 args | 4 args |
| `ip6t_unregister_table_exit` | `(net,table)` | `(net,name)` | `(net,name)` |
| `xt_register_template` | **absent** | present | present |
| `xt_find_table` | **absent** | present | present |

On 5.10 the table already lives in `net->ipv6.ip6table_nat`, so registration
retrieves it from that field instead of calling `xt_find_table`; `module_init`
also builds the table once for `init_net` rather than going through the
template mechanism.

## Build traps

All of these were hit during development and are handled in the scripts:

| Symptom | Cause |
|---------|-------|
| Every KMI "succeeds" but zero vkms artifacts | `build_modules.sh` recorded the failure and still `exit 0` (deliberately, so one KMI cannot block the others) — **a green matrix does not mean complete artifacts** |
| `vkms` loads but there is no renderD128 | the patch's inline-heredoc regex was eaten by shell escaping (`[^,\n]` became a real newline), so the patch silently did nothing |
| `Circular <mod>.o <- <mod>.o dependency dropped` | a single-file module wrote `<mod>-y := <mod>.o`; when the source name equals the module name kbuild infers it, and the extra line becomes a self-dependency |
| `'LINUX_VERSION_CODE' is not defined` | missing `<linux/version.h>`; `-Werror,-Wundef` fails the build |
| `unknown type name 'u8'` | the forward declaration landed in a header force-included via `-include`, before `u8` is defined |
| `-Wgcc-compat` complains about `for (int i = ...)` | older KMI Makefiles use `-std=gnu89` together with `-Werror` |
| `linux/mnt_idmapping.h: No such file` | that header only appeared in 6.3; the compat layer maps `nop_mnt_idmap` to `init_user_ns`, so a version guard on the include is enough |
| `No such file or directory` without saying what is missing | copying `if_macvlan.h` into the module directory does not satisfy `#include <linux/if_macvlan.h>`; it must resolve from the kernel include path |

## How to verify coverage

**Do not look at the CI job status.** Look at the actual `.ko` list in the
release:

```bash
gh release view <tag> --json assets -q '.assets[].name' \
  | grep -E '\.ko$' | sed 's/-android[0-9]*-[0-9.]*\.ko$//' | sort | uniq -c
```

Or unzip each per-KMI package and count:

```bash
for z in droidspaces-lkm-android*.zip; do
  echo "$z: $(unzip -l "$z" | grep -c '\.ko$') modules"
done
```

Each package must contain **8** `.ko` files.

## On-device verification

`android14-6.1` (MediaTek SoC, GKI 6.1) verified on real hardware:

```
$ insmod vkms-android14-6.1.ko
[drm] Initialized vkms 1.0.0 20180514 for vkms on minor 1

$ ls -la /dev/dri/
crw-rw-rw-  root graphics 226,   1  card1
crw-rw-rw-  root graphics 226, 128  renderD128

$ droidspaces --name=vtest --anland --gpu start
Container: vtest (RUNNING)   HW access: GPU   Anland: enabled
inside the container: crw-rw---- root droidspaces-gpu 226, 128 renderD128
```

`ip6table_nat` resolves its own symbols at load time:

```
[ip6t-nat-shim] self-resolved 9/9 symbols
```