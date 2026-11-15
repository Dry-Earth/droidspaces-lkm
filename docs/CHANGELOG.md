# Changelog

## 版本号说明

这个项目**还没有正式版本**。目前所有发布都是 GitHub pre-release（预览版）。

早期开发阶段误用了 `1.0.x` 这套版本号，看起来像是已经稳定。那些构建没有经过
跨机型回归，发布后也已经全部删除。为了让版本号如实反映成熟度，版本重新从
`0.1.0` 开始，早期构建按 `0.0.x` 归档在这里——**它们从未打过 tag**，保留下来
只是因为每一步修的是什么值得记。

`versionCode` 用日期编码（`v0.1.0` → `20261115`）。原因是老的 `1.0.x` 用的是
`10001`–`10003` 这种小数字；如果新版本还用 `100`，KernelSU 更新器会认为
100 < 10003 而不推送更新。日期编码天然单调递增，不会再因为版本号重置而倒退。

## v0.1.7 — vkms 真正的失败原因：不是加载时序，是 DEBUG_FS

`versionCode` 20261122。

v0.1.5 我判断 vkms 失败是"drm.ko 还没加载"的时序问题，加了重试。**这个判断是错的**，
重试不可能解决。真因是：

```make
# drivers/gpu/drm/Makefile
drm-$(CONFIG_DEBUG_FS) += drm_debugfs.o drm_debugfs_crc.o
```

`drm_debugfs_create_files()` 和 `drm_crtc_add_crc_entry()` **只在
`CONFIG_DEBUG_FS=y` 的内核里存在**。GKI 的 `gki_defconfig` 没有显式打开
DEBUG_FS（它也没有默认值），所以相当一部分真机是 `n`——那些内核里这两个符号
压根不存在。而 GKI 的 `CONFIG_DRM=y` 是编进内核的，所以这和 drm 加载不加载无关。

vkms 用到两处，都是**纯调试功能**：

| 位置 | 用途 |
|---|---|
| `vkms_composer.c` | CRC 上报（给 igt 之类的调试工具） |
| `vkms_drv.c` | debugfs 里展示 vkms 配置 |

容器要的是 `/dev/dri/renderD128` 这个 render node，和这两件事无关。所以构建时
把两处调用去掉（`scripts/patch_vkms_debugfs.py`），vkms 就能在 DEBUG_FS 开或关的
内核上加载。

实测（6.1）：打补丁后 vkms 的未定义符号里不再有 `drm_debugfs*` / `drm_crtc_add_crc_entry`，
加载后在 `/dev/dri/` 下正常建出 `renderD128`，`/sys/class/drm/renderD128/device`
指向 `vkms`——render node 功能完好。

代价：debugfs 配置展示和 CRC 上报没有了。对容器用途无影响。

## v0.1.6 — uart_guard：容器读串口属性不再打挂宿主

`versionCode` 20261121。

用户开 `enable_hw_access` 跑容器后，启动时整机 panic 重启。panic log：

```
Unable to handle kernel NULL pointer dereference at 0x54
pc : __mutex_lock+0xd8
lr : __mutex_lock_slowpath
     mutex_lock
     uart_get_info        <- drivers/tty/serial/serial_core.c
     type_show            <- 读 /sys/class/tty/ttyS3/type
     dev_attr_show -> sysfs_kf_seq_show -> __arm64_sys_read
Comm: (udev-worker)
```

**根因不在本模块**：串口的 sysfs 属性都会 `lock port->mutex`，而
`uart_get_info()` 假设 `dev_get_drvdata(dev)` 一定是一个可用的 `struct
tty_port`——上游至今没有这个检查。实测本机 `ttyS3`（蓝牙串口
`11004000.serial`，被 `platform:btmtk_uart.0` 消费）的 `tty_port` mutex 里
`owner` 只剩标志位、没有有效 task_struct 指针（`owner == 8`），于是
`__mutex_lock` 把它当指针读 → `8 + 0x4c = 0x54` 崩溃。`ttyS0/S1/S2` 则完全正常。

Android 自己没有 udev，没人读这些属性；容器里的 udev 枚举 `/sys/class/tty`
逐个读属性，第一次踩上就 panic。

**做法**：新增 `uart_guard` 模块，在两个入口挂 kprobe，校验 `tty_port` 状态，
异常就直接返回 `-ENODEV`，不进函数体：

| 钩子 | 覆盖 |
|---|---|
| `uart_get_info` | `port_show` / `type_show` / `uartclk_show` / `irq_show` 等 **13 个**属性 |
| `console_show` | 唯一**不走** `uart_get_info`、自己直接锁 mutex 的那个 |

校验三项：`port` 为 NULL、不在内核直接映射区、或 `mutex.owner` 里的任务指针
不是合法内核地址。

实测（6.1.157 / MT6989）：

- 全量遍历所有 tty 的全部 uart 属性 **56 次读取**，`ttyS3` 的 12 个属性被
  全部拦截返回 `-ENODEV`，**设备存活，无 panic**
- 健康设备（`ttyS0`/`ttyS2`）不受影响，`console` 正常返回 `N`，零误拦

这是**兜底**不是根治：根因在串口驱动与蓝牙驱动的 `tty_port` 生命周期上，
本模块只保证"读到它不会把整机打挂"。想彻底避免可以不设 `enable_hw_access`，
或只在容器内遮蔽 `/sys/class/tty/ttyS3`。

## v0.1.5 — vkms 的加载时序

`versionCode` 20261120。

v0.1.4 之后 5.10 的 7 个产物里 6 个已完全干净，只剩 `vkms` 还引用
`drm_crtc_add_crc_entry`。这个符号在 5.10 是**导出**的，问题不在导出，
而在于它属于 `drm.ko` 的**模块依赖**：`service.sh` 跑在 late_start，drm 未必
已就绪，insmod 只会报 "Unknown symbol"。

改成失败后重试 5 次（间隔 2 秒），而不是一次就放弃。

## v0.1.4 — 修掉 5.10 上"全部模块装不上"

`versionCode` 20261119。**5.10 用户必须升级。**

用户反馈 5.10 上每个模块都报：

```
Unknown symbol __stack_chk_guard (err -2)
```

原因是**栈保护金丝雀的寻址模式不匹配**。arm64 有两种：

| 模式 | 金丝雀位置 | 需要全局符号吗 |
|---|---|---|
| `CONFIG_STACKPROTECTOR_PER_TASK=y` | task_struct + sp_el0 偏移 | **不需要** |
| 否则 | 全局 `__stack_chk_guard` | 需要 |

5.10 GKI 的 `arch/arm64/kernel/process.c` 写得很直白：

```c
#if defined(CONFIG_STACKPROTECTOR) && !defined(CONFIG_STACKPROTECTOR_PER_TASK)
EXPORT_SYMBOL(__stack_chk_guard);
#endif
```

真机是 PER_TASK 模式，**导出表里根本没有这个符号**。而 DDK 给 5.10 的那棵树如果
判定不出 `-mstack-protector-guard=sysreg` 支持，会退回全局模式——编出来的 .ko 就
带着这个符号，到真机上全部 insmod 失败。

修法：构建脚本检测内核树的 guard 模式，不是 per-task 就给模块加
`-fno-stack-protector`（金丝雀没了，但能装——这是唯一能保证可加载的选项）。

另外两处 5.10 专有符号问题：

- **`cgroup_rm_cftypes`**：5.10 里存在但**没有** `EXPORT_SYMBOL_GPL`（6.1 才加），
  所以 `droid_lkm_pids` / `droid_lkm_cpu` 在 5.10 上也必然失败。改成运行时用
  `kallrecon_klp()` 解析；解析不到就**不安装** cftype——否则卸载时摘不掉，
  cgroup 子系统会留着指向已卸载模块的悬空指针（UAF）。
- **`drm_crtc_add_crc_entry`**：5.10 里是导出的，但它属于 `drm.ko` 的模块依赖，
  post-fs-data 阶段 drm 可能还没就绪。这一条尚未处理，见下。

构建脚本还加了**产物符号自检**：编完逐个 `.ko` 查未定义符号里有没有
`__stack_chk_guard` / `cgroup_rm_cftypes` / `drm_crtc_add_crc_entry` /
`_trace_android_vh_*`，在 CI 就报出来，不再等用户装上才发现。

## v0.1.3 — 修掉 "unknown symbol" 的真正来源

`versionCode` 20261118。

大量用户反馈 `insmod` 报 `unknown symbol in module, or unknown parameter`。
之前只处理了"KMI 选错"这一种，但真正的元凶是另一件事：

`include/linux/percpu-rwsem.h` 里的内联函数**无条件**调用两个 Android vendor hook：

```c
_trace_android_vh_record_pcpu_rwsem_starttime()
_trace_android_vh_record_pcpu_rwsem_time_early()
```

只要模块里有代码走 percpu-rwsem（本项目 vendored 的 overlayfs 用
`inode_lock()` 就会走到），编译出的 .ko 就带这两个**未定义符号**。它们由
`CONFIG_ANDROID_VENDOR_HOOKS` 生成，**不是所有厂商内核都开**——没开的内核上，
模块根本加载不了。

实测三份产物都带着它，不是某个 KMI 特有：

| 产物 | starttime | time_early |
|---|---|---|
| android12-5.10 | 未定义 | — |
| android14-6.1 | 未定义 | 未定义 |
| android16-6.12 | 未定义 | — |

顺带澄清一个误判：**这和 kprobe 无关**。模块对 `register_kprobe` 是运行时用
kallsyms 解析的，不是链接依赖，未定义符号表里根本没有 kprobe 相关项。

修法是在模块内提供 **weak 空实现**：内核导出同名符号时行为不变，没导出时引用
解析到本地空函数，模块照常加载。这两个 hook 只用于 rwsem 争用计时统计，空实现
不改变任何锁语义。

## v0.1.2 — 把 "unknown symbol" 拆开

`versionCode` 20261117。

用户反馈里最常见的一句是 `insmod: unknown symbol in module, or unknown
parameter`。这是内核把所有装不上的情况合并成的一句话，它不告诉你是哪一种，
用户和我们都在猜。现在三件事分开：

- **vermagic 对不上**（装错 KMI）：加载前就拒绝，打印两个版本号
- **内核没导出某个符号**（KMI 对但厂商裁了）：把内核日志里的
  `Unknown symbol <名字> (err -2)` 抄进模块日志
- **unknown parameter**（传了模块没声明的参数）：先用 `.ko` 校验参数，
  不支持的记警告并忽略，不再因此让整个模块加载失败

README 中英文都补了「排障」章节，直接对着这三种情况写。

## v0.1.1 — 开机循环保护真正生效

`versionCode` 20261116。

v0.1.0 的开机保护有个设计漏洞：计数器在 `service.sh` 跑完就清零，而模块正是
在 `service.sh` 里 insmod 的。实际发生过的情况是「service.sh 报了完成 → 之后
整个系统卡死」，那时计数器已经被清掉，保护完全不会触发。

清零点改到 `boot-completed.sh`——KernelSU 在系统真正启动完成后才调用它，那时
zygote 和 system_server 都已经起来，卡死不会被误判成成功。只有走到这一步才算
这次开机真的成功，否则连续 3 次后自动禁用。

另外 `action.sh` 的 devtmpfs 检查修了：`/proc/filesystems` 的格式是
`nodev<TAB>devtmpfs`，文件系统名在第二列，原来用 `^devtmpfs` 永远匹配不到，
所以「操作」按钮一直报「devtmpfs 未注册」，而 `droidspaces check` 显示
`[✓] devtmpfs support`。现在还会额外标出挂载后的节点数——`devtmpfs_probe=2`
只注册不建节点，所以是 0，如实显示。

## v0.1.0 — 第一个打过 tag 的预览版

`versionCode` 20261115。

**钩子后端默认仍是 kprobe。** inline 文本改写后端已编入，但默认关闭
（`inline_hooks=0`）。它要改写 55 个函数的入口，其中包括 `__arm64_sys_openat`、
`getuid` 系列、`prepare_creds`、`get_fs_type` 这些每次系统调用或权限检查都要走的
路径。手动加载实测正常，但由 `service.sh` 在开机阶段加载时，测试机出现了整个系统
卡死（无 panic、adb 失联、管理器 ANR），且无法用手动加载复现。在定位根因之前，
默认必须是影响面更小的那个后端。想实验：

```sh
insmod lkm4ctr-android14-6.1.ko inline_hooks=1
```

不要放进开机自启。

这一版没有内核代码变化，改的是**发布与安装方式**，因为之前的形态有两个真问题：

- **zram 模块把 `.ko` 放进 `system/lib/modules/`**。KernelSU 只有在装了
  metamodule（如 meta-overlayfs）时才挂载 `system/`，没装的用户装完什么都不会
  发生，也没有任何提示。现在改放模块自己的 `ko/` 目录，直接从那里 insmod。
- **CI 与发布耦合**。CI 绿灯就能产出 Release，意味着一次没经过真机验证的提交
  也可能被推到用户面前。现在 `ci.yml` 只编译、产物留 artifact；`release.yml`
  只在打 tag 时运行，并且强制 `--prerelease`。

模块目录也按 KernelSU 模块规范重整：脚本统一用 `MODDIR=${0%/*}`，不再硬编码
`/data/adb/modules/<id>`；`customize.sh` 不再依赖 `set_perm` 这类 Magisk 安装器
辅助函数；新增 `action.sh`，「操作」按钮可以直接给出加载状态和能力自检结果。

新增**开机循环保护**（`post-fs-data.sh`）：模块会往内核里 insmod 并改写函数
入口，万一某个版本在特定内核上 panic，后果是重启 -> 再 panic -> 无限循环，
只能靠物理按键进安全模式。现在每次开机计数 +1，`service.sh` 走完流程后清零；
连续 3 次没走到成功就自动创建 `disable`，让设备能正常开机。

另外修了 KMI 识别：通用 GKI 内核（如 `5.10.269-gki-...`）的内核串里没有
`androidN` 子串，之前会识别失败，然后**随手挑一个别的 KMI 的 .ko 去加载**，
报 `unknown symbol`，把真因掩盖掉。现在改成内核版本优先推导，并且拒绝跨 KMI
猜测。

## 0.0.4 — 早期构建，从未打 tag

Finishes the inline hook backend and closes two hazards in the code that
enables it. Compile-verified only: the handset was offline for this release.

### Everything goes inline

v1.0.2 shipped a hybrid: inline where the trampoline landed within a `b`'s
reach, kprobe otherwise. The near allocation was too narrow -- it only searched
a few windows below the target and its distance test was written in unsigned
arithmetic. It now searches both directions at four distances (4MB, 16MB, 64MB,
112MB), keeps an allocation only if `hk_branch_reachable()` accepts it, and
otherwise falls back to the absolute detour and then to kprobe. With the
4-byte-window path working, syscall wrappers that previously had to fall back
(`__arm64_sys_msgget` and its siblings) install inline too.

### Hazards fixed in the near allocator

- **The search window could land on the kernel image.** vmalloc's vmap tree only
  tracks regions vmap itself handed out; the kernel image's static mapping is
  invisible to it, so `__vmalloc_node_range` will happily return pages inside
  `_text.._end` if asked. A trampoline there would overwrite live kernel code.
  Windows are now clamped to stop at `_text` from below and start at `_end` from
  above.
- The unsigned distance comparison is replaced with a signed
  `hk_branch_reachable()`, which is what the value means.

### Build fix

`hk_patch.c` declared `pte_t old` / `bool was_ro` after a statement, which
android12-5.10 / 13-5.10 / 13-5.15 / 14-5.15 reject under
`-Wdeclaration-after-statement`. Those four KMIs silently lost `lkm4ctr` while
the job still reported success.

## 0.0.3 — 早期构建，从未打 tag

The hook engine no longer runs on kprobe on stock firmware. Same functionality,
different mechanism, plus one privilege escalation that the v1.0.1 audit
introduced.

### The hook backend

`shadow_hook` picks its backend at compile time: ftrace when the kernel has
`CONFIG_FUNCTION_TRACER && CONFIG_DYNAMIC_FTRACE`, otherwise a kprobe
pre_handler that rewrites the trapped pc. Vendor GKI kernels commonly build
FUNCTION_TRACER out -- this device reports `# CONFIG_FUNCTION_TRACER is not
set` -- so kprobe was what actually ran on stock firmware.

kprobe works, but it costs a BRK exception on entry plus a second one from the
kretprobe the engine installs for in-flight tracking, on every hooked call. The
hot hooks (fork, clone, clone3, vfork, unshare, setns, copy_namespaces,
copy_creds, prepare_creds, wake_up_new_task, mount_capable) are all on the
process-creation path. It also occupies the kprobe slot for that address, which
KernelSU/SUSFS and vendor modules share.

An inline hook writes a jump over the entry instead: no exception, no handler,
no shared slot. The displaced instructions are relocated into a trampoline and
that trampoline becomes `hook->original`, so a replacement calling "original"
never lands on the patched prologue -- which removes the recursion guard the
other two backends need.

Two things made this less routine than it sounds:

- **A 20-byte detour cannot patch a syscall wrapper.** The absolute jump is
  `bti jc ; ldr x17,#8 ; br x17 ; .quad target`. `__arm64_sys_msgget` is a
  `bti`, two register moves and a tail `b`, so the branch sits at offset 12 and
  a five-instruction window does not fit. The first attempt let the module
  install 14 hooks and then fail on this one with `-EOPNOTSUPP`, rolling the
  whole init back.
- **A 4-byte `b` cannot reach the general vmalloc area.** With
  `CONFIG_ARM64_VA_BITS=39` the module region ends at `0xffffffc800000000`
  while this kernel's KASLR-randomised text sits around `0xffffffde1b7ceac8` --
  about 95 GB apart, far outside the ±128MB a `b` encodes. That is why the
  kernel itself ships `CONFIG_ARM64_MODULE_PLTS`.

The engine now allocates the trampoline in the vmalloc gap just below the
target (`[addr-112MB, addr-4MB]`) and, when that lands, patches the entry with
a single `b`: 4-byte window, one instruction relocated, no BTI landing pad, no
literal pool. Every hooked function takes that path, syscall wrappers included.
If the near allocation fails the old 20-byte detour is used, and if even that
fails the hook falls back to kprobe -- a tight vmalloc gap degrades instead of
breaking.

### Privilege escalation fixed

- `mount_capable` is now corrected only for filesystems carrying
  `FS_USERNS_MOUNT`. v1.0.1 taught it to substitute `ns_capable(current_userns)`
  whenever the real check failed and `fc->user_ns` was init, but the real
  function has two arms: a global `capable(CAP_SYS_ADMIN)` for filesystems the
  kernel deliberately keeps out of user namespaces, and
  `ns_capable(fc->user_ns)` for the ones it allows. Since `fc->user_ns` is
  pinned to init under `CONFIG_USER_NS=n`, the old condition could not tell
  them apart, and a container root could mount ext4 and anything else behind a
  block device.

### Verified

- All 7 KMIs build.
- On the device before this change: 578 us/fork with the kprobe backend versus
  485 us/fork with the module unloaded, min-of-8. The inline figures for this
  release were not measured -- the handset dropped off USB before the run.

## 0.0.2 — 早期构建，从未打 tag

Security audit of the C code. Three findings, all fixed. Nothing here changes
how the modules are used; they close holes that only mattered once a container
was running untrusted workloads.

**Privilege escalation**

- `mount_capable` no longer substitutes `ns_capable()` for filesystems that do
  not carry `FS_USERNS_MOUNT`. The real check has two arms: a global
  `capable(CAP_SYS_ADMIN)` for filesystems the kernel keeps out of user
  namespaces, and `ns_capable(fc->user_ns)` for the ones it allows. Only the
  second is the `CONFIG_USER_NS=n` miscomputation worth correcting, but
  `fc->user_ns` is pinned to init in that configuration, so the old condition
  could not tell them apart. A container root could mount ext4 and anything else
  behind a block device. The fix tests `FS_USERNS_MOUNT` explicitly.

**Panic**

- `droid_lkm_cpu` and `droid_lkm_pids` now hold a reference on each cgroup they
  track, via `percpu_ref_get(&cgrp->self.refcnt)` -- what `cgroup_get()`
  compiles to. Both previously keyed an xarray on a raw `struct cgroup *` and
  relied on `copy_from_kernel_nofault` to spot a freed one, which catches
  unmapped memory but not a slab-reused cgroup whose `kn` field reads back
  non-NULL. That is how the earlier `css_task_iter_advance_css_set` NULL
  dereference happened. Readers now run under `rcu_read_lock`; the destroy path
  erases, drops the reference, calls `synchronize_rcu()` and only then frees.
- The `cgroup_rmdir` kprobe now only sets a dead flag. It used to erase and free
  inline, which raced the tick, and the pids module did not free at all -- every
  entry leaked, and a reused cgroup address let a new container inherit the old
  one's `pids.max`.
- `devtmpfs_lkm`: the trampoline relocation summed `hk_relo_len[]` over the
  instructions ahead of an operand target and indexed the table with
  `hk_insn_index()`, which returns -1 for an unrecognised class. Forward-
  referencing operands could reach an instruction not yet classified, read the
  word before the array, and write a branch to a wrong address into kernel text.
  The lookup now reports failure and the hook aborts with `-EOPNOTSUPP`. The
  staging buffer bound is pinned with a compile-time assertion so a larger
  window cannot silently overflow it.

**Also**

- Build warning-free at `W=1`; a write-only local in the CPU tick loop is gone.

## 0.0.1 — 早期构建，从未打 tag

First stable release. Every check `droidspaces check` performs now passes on a
stock 6.1.157 vendor kernel.

**Container capabilities**

- `lkm4ctr` supplies PID, UTS, IPC and user namespaces, plus SYSVIPC and
  POSIX message queues. NET and cgroup namespaces are left to the kernel when it
  already supports them.
- `devtmpfs_lkm` registers a devtmpfs filesystem for `--hw-access` containers.
- `macvlan` gives a container its own interface and MAC on the host NIC.
- `ip6table_nat` provides the IPv6 `nat` table so droidspaces can install its
  NAT66 rule.
- `vkms` provides a render node for Wayland compositors.
- `droid_lkm_pids` emulates the pids controller for `--pids-limit`.
- `droid_lkm_cpu` emulates `cpu.max` for `--cpus`.

**Fixes since the pre-1.0 builds**

- `/proc/<pid>/ns/user` is published, with `vns_userns_operations` installed on
  the init namespace first so `nsfs_evict()` cannot dereference a NULL ops.
- Mount namespaces created from a child user namespace now belong to that
  namespace instead of init, so mounts stop failing with EPERM.
- `mount_capable()` is corrected for the same reason, which is what made tmpfs
  and proc mounts work (`bind` worked earlier because it skips that check).
- NET and cgroup namespaces are no longer stubbed out on kernels that support
  them natively. `--net=macvlan` containers work as a result.
- The pids module no longer panics when a container's cgroup is removed while
  it is still being sampled.
- The `sched_cfs_bandwidth_slice_us` sysctl is registered so the CPU limit
  check reports support.

**Known limits**

- `--net=nat` containers share the host network namespace on kernels without
  native `NET_NS`. Host networking is required in that case.
- IPv6 NAT: the `nat` table and MASQUERADE target are verified; actual packet
  translation was not demonstrable on the test device.
- The `--pids-limit` counter does not include processes migrated into the
  container's cgroup.
- CPU limiting freezes with SIGSTOP rather than CFS throttling, so it is
  coarser than a kernel with `CONFIG_CFS_BANDWIDTH`.