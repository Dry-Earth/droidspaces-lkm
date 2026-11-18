## v0.1.27

### 修复

**`droid_lkm_pids` 不再在 kprobe 原子上下文里睡眠（修 `scheduling while atomic`
重启）。** `ctl_subtree_pre()` 是 pre-handler，却用 `kernfs_find_and_get()` 判断
memory 是否已启用；该调用会 `down_read(&kernfs_rwsem)`，一旦有竞争就 `schedule`。
实测（PHZ110 / Anland 5.x / 6.1.157）在 systemd 写 `cgroup.subtree_control` 时打出
`BUG: scheduling while atomic ... ctl_subtree_pre [droid_lkm_pids]`，随后 preempt
计数被破坏，连锁看门狗重启。改为**原子观测表**：见过 `+memory` 的 cgroup 记进
`ctl_mem_seen[]`（`spin_lock_irqsave`），`-memory` 与 `cgroup_rmdir` 清条目；盲区只有
「模块加载前就已启用 memory 的 cgroup」，退回老行为（rewrite 后 `-EFAULT`），不再
panic。

### 新增

**显示路线（route）三态**：`auto` / `anland6` / `desktop5`。MediaTek 且无旧配置
时，安装/更新用音量键选择（上 = Anland 6.x，下 = 标准桌面 5.x；读不到键 =
`auto`）；升级默认保留原选择。可用 WebUI 或 `action.sh route auto|anland6|
desktop5` 随时修改，重启生效；非 MTK 设备一律 `auto`，WebUI 隐藏「切换路线」
页签。语义：`anland6` 挂 `mali_nsfix` 且不装 vkms；`desktop5` 强制装 vkms 且不装
`mali_nsfix`。

**WebUI 重做**：Material You 风格 + 底栏四页签（主页 / 切换路线 / 诊断 / 关于），
MD3 与 MIUIx 两套主题、19 个语言 locale、内联图标；关于页放仓库与 5.x / 6.x 两个
懒人包跳转。配套 `action.sh` 增加显示链路诊断（`/dev/mali0`、`mali_kbase`、render
node、`nshf_*`）与机器可读 `nshf_status`。

### 文档与说明

- README（中英）明确 vkms / mali_nsfix 的适用路线与 5.x / 6.x 差异，补齐安装期
  路线提示、WebUI 验证、`route` 文件与安全约束（pids 原子上下文、布局绊线、
  WebUI 只做本地 root exec）。
- 排障新增「显示路线问题」与历史 `scheduling while atomic` 条目。

### CI

- 静态检查覆盖 route 链路（安装器/加载器/操作页/WebUI）与既有 pids 睡眠调用回归
  守卫；构建矩阵与打包流程不变。

### 验证

- 7 个 KMI 全量构建 + 打包通过；小测（单桌面 × 双架构 × 双语言）通过。
- pids 修复与 route/WebUI 在 OPPO PHZ110（MTK）与 2410CRP4CG（Qualcomm）上核对。

---

## v0.1.27

### Fixed

**`droid_lkm_pids` no longer sleeps inside a kprobe handler (fixes the
`scheduling while atomic` reboot).** `ctl_subtree_pre()` is a pre-handler but used
`kernfs_find_and_get()` to check whether memory was already enabled; that call takes
`down_read(&kernfs_rwsem)` and can schedule under contention. Measured on PHZ110 /
Anland 5.x / 6.1.157: systemd writes `cgroup.subtree_control`, the kernel prints
`BUG: scheduling while atomic ... ctl_subtree_pre [droid_lkm_pids]`, the preempt
counter is corrupted, and the watchdog reboots. It now uses an atomic observation
table (`ctl_mem_seen[]` guarded by `spin_lock_irqsave`, cleared by `-memory` and
`cgroup_rmdir`). Only blind spot: cgroups where memory was enabled before this module
loaded fall back to the old behaviour (`-EFAULT`), never a panic.

### Added

**Display route with three values**: `auto` / `anland6` / `desktop5`. On MediaTek
devices without an existing config, install/update asks with a volume-key prompt
(VolUp = Anland 6.x, VolDown = standard desktop 5.x; no key read = `auto`), and
upgrades keep the previous choice. The route can be changed any time from the WebUI
or `action.sh route auto|anland6|desktop5`; reboot to apply. Non-MTK devices always
use `auto` and the Route tab is hidden. Semantics: `anland6` arms `mali_nsfix` and
never loads vkms; `desktop5` forces vkms and does not load `mali_nsfix`.

**WebUI redesign**: Material You style with a four-tab bottom bar (Home / Route /
Diagnostics / About), MD3 and MIUIx themes, 19 locales and inline icons; About links
the repository and both one-click packs. `action.sh` gained display-chain
diagnostics (`/dev/mali0`, `mali_kbase`, render node, `nshf_*`) and a machine-
readable `nshf_status` line.

### Documentation

- README (EN + ZH) now spells out which route uses vkms vs mali_nsfix, the 5.x/6.x
  split, the install-time prompt, WebUI verification, the `route` file, and the
  safety constraints (atomic-context pids handlers, layout tripwire, WebUI only
  doing local root exec).
- Troubleshooting gains "display route problems" and the historical
  `scheduling while atomic` entry.

### CI

- Static checks cover the route chain (installer/loader/action/WebUI) plus the
  regression guard against sleeping calls in pids handlers. Build matrix and
  packaging are unchanged.

### Verified

- Full 7-KMI build + package green; small test (one desktop × two architectures ×
  two languages) green.
- pids fix and route/WebUI checked on OPPO PHZ110 (MediaTek) and 2410CRP4CG
  (Qualcomm).
