## v0.1.25

### 修复

**`register_kprobe` 系列改为可选。** 内核没导出这四个探针 API（或没编
`CONFIG_KPROBES`）时，`droid_lkm_pids` / `droid_lkm_cpu` 会直接 Unknown symbol
整个装不上。现在它们经 KallRecon 运行时解析，解析不到就按 best-effort 跳过
探针 —— 模块照常加载，只是限额/显示功能降级。

**回收循环在锁内重验条目状态。** `pids_reap_fn()` 与 `cpu_tick()` 原来在
mutex 外判断"该回收"，而从判断到拿锁之间，写 `pids.max` / `cpu.max` 的一方
（全程持锁）可能把同一条目重新激活；现在拿锁后重算条件再摘除。

### 性能

**`cgroup_can_fork` / `cgroup_post_fork` / `cgroup_exit` 改 inline 优先。**
这三个每次 fork/exit 都命中，kprobe 每命中一次要陷一次异常（约 1-3 us），
inline 是一条 `b` 指令。装不上 inline 时自动退回 kprobe。

**新增 `route` 模块参数**（只读）：`0` auto（默认，inline 优先）、
`1` inline only、`2` kprobe only（改动前行为）。用于同机 A/B 与一键回退。

### 变更

**KallRecon 三份副本合并为 `extra/kallrecon/`。** devtmpfs、net_ip6nat、
cgrouplimits 原先各拷贝一份且已分叉，现在共用一份（构建期 staging 进各模块
目录，因为 kbuild 的 `M=` 不接受跨目录对象）。

**hk 引擎提升为公共目录 `extra/hk/`**，devtmpfs 与 cgrouplimits 共用。

**`mali_nsfix` 增加 `struct module` 布局自校验，并实测了开销。**

`within_module()` 读的是 `struct module` 的 `core_layout` 字段偏移，而模块按
DDK 头文件编译、设备内核是厂商编的 —— 任何改动该结构体的配置都会让偏移错位。
错位时假阴性只是不重定向；**假阳性会把无关的 `find_get_pid(nr)` 改写成调用者
自己的 group leader**，于是 `waitid` / `kill` / `pidfd_open` 拿到错误任务，
且不产生任何报错。现在装钩子前先自校验（本模块两个地址必须判为落在
`THIS_MODULE` 内，且 `core_layout.size` 合理），不通过就拒绝加载。

计数导出为 `nshf_seen` / `nshf_hits`，可直接读，不用卸载模块。真机实测
（PHZ110 / MT6989 / 6.1.157）：60 秒全系统拦截 5 次，累计 1800 次中 44 次是
Mali 调用者；按每次陷入 1-3 µs 折合 **0.000008% - 0.000025% CPU**。

**`vkms` 改为默认不加载**，需要时在模块目录放 `enable_vkms`。实测卸掉
`vkms` 后 anland 的 `waylandbridge` 仍用 `/dev/mali0` 正常渲染上屏
（`renderD128` 的 fd 数为 0），Mali 平台不需要它；而它提供的 render node
背后没有 GPU，一旦被当作渲染后端只会落回 llvmpipe（CPU）。

**写了一版 ftrace 后端，最终没有保留。** 它在七个 KMI 上都编译通过，但每一个
都编译成了空：DDK 构建树与设备内核都是 `# CONFIG_FUNCTION_TRACER is not set`，
没有 `__fentry__` 调用点可 patch。加上面实测的 kprobe 开销（十万分之几 CPU），
这条路没有价值，作为死代码删掉而不是发布。

**死代码清理**：`hk_binder.c` / `hk_lsm.c` 未被任何 Makefile 链入，移除。

### 验证

全 KMI 矩阵编译通过。真机（PHZ110 / 6.1.157）确认三个 hook 实际走 inline
路由，pids 记账与 kprobe 版行为一致。

---

## v0.1.25

### Fixed

**The `register_kprobe` family is now optional.** When the kernel exports none of
the four probe APIs (or has `CONFIG_KPROBES` disabled), `droid_lkm_pids` /
`droid_lkm_cpu` used to fail to load with `Unknown symbol`, taking the limit and
display layers down with them. They are now resolved at runtime through
KallRecon; when resolution fails the probes are skipped best-effort and the
module still loads.

**The reclaim loops re-check entry state under the lock.** `pids_reap_fn()` and
`cpu_tick()` tested "should reclaim" outside the mutex, while the writer
(`pids.max` / `cpu.max`, holding that mutex) can reactivate the very entry in
between. The condition is now re-evaluated after the lock is taken.

### Performance

**`cgroup_can_fork` / `cgroup_post_fork` / `cgroup_exit` are inline-first.**
All three are hit on every fork/exit; a kprobe costs an exception round trip
(~1-3 us) per hit, an inline detour is one `b` instruction. When inline cannot be
installed it falls back to kprobe automatically.

**New `route` module parameter** (read-only): `0` auto (default, inline first),
`1` inline only, `2` kprobe only (the pre-change behaviour). For A/B on one
device and one-command rollback.

### Changed

**The three KallRecon copies are consolidated into `extra/kallrecon/`.**
devtmpfs, net_ip6nat and cgrouplimits had each carried a copy and they had
diverged; they now share one (staged into each module directory at build time,
because kbuild's `M=` rejects out-of-tree objects).

**The hk engine moved to the shared `extra/hk/`**, used by both devtmpfs and
cgrouplimits.

**`mali_nsfix` gained a `struct module` layout self-check, and its cost was
measured.** `within_module()` reads `core_layout` fields out of `struct module`,
but the module is built against the DDK headers while the device kernel is the
vendor's build, so any config that changes that struct shifts the offsets. A
false negative merely leaves the redirect off; **a false positive rewrites an
unrelated `find_get_pid(nr)` to the caller's own group leader**, so `waitid`,
`kill` or `pidfd_open` receive the wrong task, with no error logged. The probe is
now armed only after a self-check passes (two of the module's own addresses must
classify as inside `THIS_MODULE`, and `core_layout.size` must be plausible).

Counters are exported as `nshf_seen` / `nshf_hits` and readable without
unloading. Measured on PHZ110 / MT6989 / 6.1.157: 5 interceptions per 60 s
system-wide, 44 of 1800 cumulative being Mali callers; at 1-3 us per trap that is
**0.000008% - 0.000025% CPU**.

**`vkms` no longer loads by default**; create `enable_vkms` in the module
directory to load it. Measured: with `vkms` removed, anland's `waylandbridge`
still renders and presents through `/dev/mali0` (the `/dev/dri/renderD128` fd
count is zero), so Mali platforms do not need it — and the render node it
provides has no GPU behind it, so using it as a rendering backend only falls back
to llvmpipe on the CPU.

**An ftrace backend was written and then dropped.** It compiled on all seven KMIs
but compiled to nothing on every one: both the DDK tree and the device kernel
have `# CONFIG_FUNCTION_TRACER is not set`, so there are no `__fentry__` call
sites to patch. Combined with the measured kprobe cost above, the path had no
value, so it was removed rather than shipped as dead code.

**Dead code removed**: `hk_binder.c` / `hk_lsm.c` were linked by no Makefile.

### Verified

Full KMI matrix builds green. On device (PHZ110 / 6.1.157) all three hooks are
confirmed on the inline route, and pids accounting matches the kprobe build.
