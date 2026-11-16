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



这一轮把「符号问题」从「出问题再修」推到三个方向。三条都经过 CI 全量矩阵和
真机验证（Redmi Pad 2410CRP4CG / Qualcomm SM7675 / 6.1.138）。

## v0.1.23

`versionCode` 由构建时写入（`YYYYMMDDHHMM`，见 `.github/workflows/build.yml`）。

### 修复

### 修复

**`versionCode` 超出 int32 范围，KernelSU 从未能解析。**

KernelSU 的 `Module.kt` 将 `versionCode` 声明为 `Int`，`Downloader.kt` 用
`.toInt()` 解析。此前 `build.yml` 生成的值为 `%Y%m%d%H%M`（12 位），
本应为 `202611170004`，超出 `Integer.MAX_VALUE` (2147483647) 94 倍，
`.toInt()` 抛出 `NumberFormatException`，更新检查失败。

v0.1.22（`202611161425`）同样超出范围，因此该问题自引入以来一直存在。

改为 `YYYYMMDDnn`：

```
versionCode = YYYYMMDD * 100 + 小时 * 4 + 分钟 / 15
```

取值范围 `2026111700`–`2026111795`，上限 2,026,117,995 < 2,147,483,647，
每日 96 个槽位。超出范围时构建直接失败。分 KMI 包改为读取
`dist/version-code.txt`，与全 KMI 包使用同一个值。
`scripts/gen_release_meta.py` 增加 int32 上限校验。


**符号兼容层扩展到全部七个 KMI。** v0.1.22 仅覆盖 MID 层（5.15 / 6.1），
OLD（5.10）与 NEW（6.6 / 6.12）的兼容清单缺少相应条目。

`lkm4ctr` 的 VFS 类静态导入（`nm -u` 实测）：

| KMI | 层 | v0.1.22 | v0.1.23 | 降幅 |
|---|---|---|---|---|
| android12-5.10 | OLD | 29 | 1 | −97% |
| android13-5.10 | OLD | 29 | 1 | −97% |
| android13-5.15 | MID | 29 | 1 | −97% |
| android14-5.15 | MID | 29 | 1 | −97% |
| android14-6.1 | MID | 6 | 2 | −67% |
| android15-6.6 | NEW | 37 | 2 | −95% |
| android16-6.12 | NEW | 40 | 2 | −95% |

统计范围为 VFS 辅助函数类（`d_` / `i_` / `inode` / `clear_` / `vfs_` / `iget` /
`percpu_` 等前缀），不含全部未定义符号。残余项为 `__percpu_down_read` 与
`percpu_counter_add_batch`，属内核内置原语，无裁剪先例。

新增覆盖的符号（均经 `nm -u` 确认不再静态导入）：`d_instantiate`、`d_obtain_alias`、
`d_splice_alias`、`d_add`、`d_make_root`、`d_path`、`ihold`、`clear_inode`、
`clear_nlink`、`drop_nlink`、`inc_nlink`、`set_nlink`、`inode_init_once`、
`unlock_new_inode`、`iget5_locked`、`ilookup5`、`init_special_inode`、
`inode_set_flags`、`inode_init_owner`、`setattr_prepare`、`touch_atime`、
`sync_filesystem`、`vfs_fsync`、`vfs_fsync_range`、`truncate_inode_pages_final`、
`current_umask`、`in_group_p`、`capable_wrt_inode_uidgid`、`notify_change`、
`finish_open`、`generic_read_dir`、`backing_file_user_path`、`get_next_ino`、
`__insert_inode_hash`。

**`capable_wrt_inode_uidgid`（issue #2 根因）。** 由 `vendor/fs/overlayfs/inode.c`
调用。经 Meizu 21 Pro（6.1.25）boot.img 提取的 `__ksymtab_strings`（6594 项）确认：
该内核导出 `lkm4ctr` 需要的 207 个符号中的 206 个，唯一缺失项即为本符号。
已为 OLD / MID / NEW 三层分别配置重定向。

**macvlan。** `dev_mc_add`、`dev_mc_del`、`netdev_is_rx_handler_busy`、
`dev_forward_skb`、`eth_header_cache`、`eth_header_cache_update` 改为同名转发
函数 + 运行时解析。v0.1.22 将 `dev_mc_add_excl` 改写为 `dev_mc_add`，但后者在
部分内核同样未导出，未解决问题。

**vkms。** `drmm_crtc_init_with_planes` 替换为 `drm_crtc_init_with_planes`。
两者签名一致（均为 variadic），上游均 `EXPORT_SYMBOL`。CRTC 由
`drm_mode_config_cleanup()` 统一释放。

**droid_lkm_cpu / droid_lkm_pids。** `cgroup_add_dfl_cftypes` 改为运行时解析
（`cpu_ksym()` / `kallrecon_klp()`），与同模块内已有的 `cgroup_rm_cftypes`
处理方式一致。

### 新增

**`scripts/gen_vfs_compat.py`。** 从内核 BTF 提取函数原型，生成指针声明、
同名转发函数与解析表。用于新增符号，避免手工书写签名错误。

**`scripts/verify_against_bootimg.py`。** 从 `boot.img` 提取 `__ksymtab_strings`，
与 `.ko` 的未定义符号表比对，输出每个模块的缺失项。

**`lkm4ctr_lite`。** 不含 vendored overlayfs 的变体（`VNS_LITE=1`）。`service.sh`
优先加载完整版，失败时回退。适用于裁掉 overlayfs 独占符号的内核。

**崩溃现场采集。** `post-fs-data.sh` 检测 `/sys/fs/pstore/`，非空时复制到
`/data/adb/droidspaces_lkm.d/pstore-<timestamp>.txt`。

### 变更

**构建期符号检查。** `scripts/build_modules.sh` 的 `BAD_SYMS` 清单由 12 项扩至
53 项；新增 `MUST_NOT_APPEAR` 15 项硬性检查，命中即 `exit 1`。

**`zram-lkm`。** 增加构建期导出检查（见该仓库 `2ba41c3`）。

### 版本变体

| 符号 | 变化 | 处理 |
|---|---|---|
| `kmem_cache_alloc_lru` | 6.10 起为宏，符号名 `_noprof` | 条件条目宏 + 同名函数 |
| `__percpu_counter_init` | 6.6 起为 `_many`（多 `nr_counters`） | 条件条目宏 + 同名函数 |
| `d_tmpfile` | 6.7 起更名 `d_mark_tmpfile` | 条件条目宏 |
| `d_parent_ino` | 6.12 新增 | 条件条目宏 + 同名函数 |
| `generic_encode_ino32_fh` | 6.9 新增 | 条件条目宏 |

符号由内核头文件的 `static inline` 调用时，`#define` 无法覆盖（内联体在
compat 头之前解析），须使用同名转发函数。`generic_read_dir`、`kmem_cache_alloc_lru`、
`__percpu_counter_init_many`、`percpu_counter_destroy_many`、`d_parent_ino` 属此类。

### 验证

- 七个 KMI 构建通过；`BAD_SYMS` 检查结果全部为 0。
- Meizu 21 Pro（6.1.25）：10 个模块，缺失 0。数据源为报告者提供的 `boot.img`。
- PHZ110（MediaTek mt6989 / 6.1.157）：10 个模块，缺失 0。数据源为
  `/proc/kallsyms` 的 `__ksymtab_` 条目（22081 项）。
- PHZ110 实机加载：`macvlan` 模块 `insmod` 成功（`rc=0`），
  `ip link add ... type macvlan` 成功；容器能力检查 8/8 通过，`Unknown symbol` 计数 0。

### 已知问题

- issue #1（Redmi Note 12 Turbo / 5.10.269）报告的无限重启未复现确认。
  该设备 `/sys/fs/pstore` 为空，表明为挂起而非 panic；需报告者后续反馈。
- issue #3 / #4（6.12.23-android16-5）报告的符号已修复，但缺少对应设备内核，
  未做同类验证。

## v0.1.22 — 符号兼容性、日志诊断、国际化

`versionCode` 2026111600。

这一版主要解决一件事：**模块在部分厂商内核上装不上，而用户报上来的日志里看不出
缺哪个符号**。围绕这个问题改了三层，并顺带补上 Mali 命名空间修复和全仓国际化。

### 符号兼容性

起因是 issue #2：Meizu 21 Pro（6.1.25）上 `lkm4ctr` 和 `macvlan` 装不上，报
`Unknown symbol`。用报告者提供的 `boot.img` 确认这些符号**在 kallsyms 里存在，
只是没有 `EXPORT_SYMBOL`** —— 模块加载只查导出表，所以失败；而运行时按名查
kallsyms 能拿到。

| 模块 | 原静态导入 | 修法 |
|---|---|---|
| `droid_lkm_cpu` | `path_put`、`kern_path`、`memory_cgrp_subsys` | 运行时解析，双重回退 + shim 撞名保护 |
| `lkm4ctr` | `file_remove_privs`、`seq_escape_mem`、`kill_pid` | 同名函数转发（参照上游 PR #13），内部调运行时解析 |
| `macvlan` | `ip_check_defrag`、`__netif_rx`、`ndo_dflt_fdb_dump` | 构建期源码改写，见 `scripts/patch_macvlan.py` |

`droid_lkm_cpu` 另补两处 `__nocfi`：改成间接调用后，`CONFIG_CFI_CLANG=y` 的内核
会在调用点做类型校验，不标注会 panic。这个内核我们自己就有。

`macvlan` 的三处替换里只有 `ip_check_defrag` 有语义损失（不再重组 IP 分片），
另两处等价：`.ndo_fdb_dump = NULL` 时 `rtnl_fdb_dump()` 本来就会回退到
`ndo_dflt_fdb_dump`；`__netif_rx` 与 `netif_rx` 是同一收包路径的两个入口。

产物已用 `nm -u` 逐项验证，八个符号不再出现在任何 `.ko` 的未定义符号里。

### 日志诊断

`insmod` 失败只回一句 `unknown symbol in module`，具体符号在 `dmesg` 里。但
issue #2 里两台设备，一台能读 `dmesg` 一台读不到 —— 后者提供的报告完全没有信息量。

现在构建期用 `nm -u` 把每个 `.ko` 的未定义符号导成 `ko/symcheck-<kmi>.txt` 打进包；
运行期（`action.sh`、`service.sh`）拿清单查 `/proc/kallsyms` 的 `__ksymtab_` 条目，
直接报出本内核缺哪几个符号，不依赖 `dmesg`。

第一版实现逐条 `grep` 整个 `/proc/kallsyms`，641 条依赖 × 二十多万行，在 KernelSU
的「操作」按钮里表现为卡死。改成一次读取 + awk 单趟比对后 25 ms。

### Mali 命名空间（首次发布）

`mali_nsfix`：kprobe `find_get_pid()`，把 `mali_kbase` 调用者的查找重定向到
`get_task_pid(current->group_leader, ...)`。`task_struct->tgid` 永远是初始命名空间
的值，而原函数查的是调用者的活动命名空间，容器里两者不一致，`kbase_create_context()`
因此失败并映射成 `-ENOMEM`。详见 `extra/mali_nsfix/README.md`。

容器内已实测能创建 GPU context（5/5 成功）。

### 国际化

模块文案按系统语言显示（zh / ja / en，未翻译语言回退英文），英文为默认。
覆盖安装期（`customize.sh`）、「操作」按钮（`action.sh`）、开机日志（`service.sh`）。

**机器可读的部分不翻译**：`[OK]` / `[FAIL]` / `[MISS]` / `[SYM]` 标记、符号名、
KMI 标签、内核版本串、路径。只翻译标记后面的人读描述 —— 这样用户贴出来的日志
既能被人读懂，也能被 grep。

顺带把两个中文标记改成语言中立的：`[缺]` / `[缺符号]` → `[SYM]`。

构建脚本同样国际化：`scripts/i18n.sh`（shell）与 `scripts/i18n.py`（Python），
判定规则一致。`release_notes.sh` 的输出直接成为 Release 正文，GitHub 不按用户语言
分发正文，所以中英两段并列输出。

### 平台条件加载

`vkms` 之前是无条件加载的；`mali_nsfix` 更糟 —— 它被构建、被打包，但 `service.sh`
里**完全没引用**，从不加载，用户得自己 `insmod`。

现在两个模块按平台条件加载，判据用可观测事实，不写死厂商名：

| 模块 | 加载条件 | 跳过的理由 |
|---|---|---|
| `vkms.ko` | 还没有 `/dev/dri/renderD128` | 高通多数由 kgsl 原生提供 render node |
| `mali_nsfix.ko` | 存在 `/dev/mali0` 或已加载 `mali_kbase` | 没有 Mali GPU，而它在 `find_get_pid` 这个热点上挂 kprobe |

`mali_nsfix` 不是 MTK 专用：它补的是 `mali_kbase` 的假设，三星等 Mali 机型同样
适用。`vkms` 也不是：它解决的是"缺 render node"，缺少 render node 的高通机型
仍然需要。

实测确认 MTK 确实需要 vkms：`mediatek-drm` 只创建 `card0`，
**不提供 render node**；`renderD128` 是 vkms 提供的。

`action.sh` 的能力验证新增一行 `Mali GPU context`，`service.sh` 的开机日志输出
判定结果。`disable_mali` 可以关掉它。

### 能力验证的假 FAIL

`action.sh` 的「操作」按钮长期显示

```text
[FAIL] PID + mount + user namespace 组合
[FAIL] 容器内挂载 /proc
```

而同一份输出下方 `service.sh` 写的日志是 `[OK] PID namespace` / `[OK] IPC
namespace` —— 同一个能力两种结论。

根因是测试写法多了 `-U`。逐级实测：

| 命令 | 结果 |
|---|---|
| `unshare -Urmpf true` | OK |
| `unshare -Urmpf mount ...` | **FAIL: Operation not permitted** |
| `unshare -pf mount ...` | OK（209 个节点） |
| 不 `unshare` 直接 `mount` | OK |

加 `-U` 之后只是**新用户命名空间里的 root**，而挂载 proc 要求 proc 的 pid 命名
空间归属于同一个 userns —— 内核的 userns 挂载限制，与模块提供的容器能力无关。
容器用的是宿主的 user namespace。

改成 `unshare -pmf`（与 `service.sh` 一致），并把 `mount -t proc` 的目标从 `/proc`
改成临时目录 —— 往已存在的挂载点上挂在 userns 下同样 EPERM，真挂上去还会污染
当前会话。

### 其他

- **`customize.sh` 曾被写成 CRLF**：`sh` 解析 `case ... in` 时报
  `Syntax error: word unexpected (expecting "in")`，**安装脚本会直接崩**，
  刷进去什么都不会发生。已统一为 LF，`module/` 下 7 个 `.sh` 全部通过 `sh -n`。
- **包名带版本号**：`droidspaces-lkm-arm64-<ver>.zip`。之前所有版本都叫
  `droidspaces-lkm-arm64.zip`，下多个版本后本地分不清哪个是哪个，Release 页面上
  不同发布的资产名也完全相同。
- **`module.prop` 的 version 之前从不更新**：仓库里写死 `v0.1.21`，所有测试构建
  都报同一个号，用户贴日志时无法判断装的是哪一版。现在按 tag 写入。
- **`action.sh` 的 KMI 推导缺回退**：只抄了 `service.sh` 的第一段模式，而那个模式
  要求内核串里出现字面量 `-6.1`，实际串是 `6.1.157-android14-11-...`，永远匹配
  不上。现在按 `androidNN` + `X.Y` 拼接，并从日志兜底读取。
- **`extra/` 补中英文 README**，英文为默认。
- `description` 从 195 字符压到 91，`virtual DRM render node` → `vkms`、
  `cgroup CPU/PID limits` → `cgroup cpu.max/pids`。

### 已知限制

`macvlan` 在 source 模式下不再重组 IP 分片。分片流量在容器场景少见，而代价是整个
模块装不上 —— 取舍偏向可用性。

## v0.1.21 — 升级 KallRecon 到上游最新

`versionCode` 20261136。

从 `Dere3046` 仓库生态里挖出来的：我们 vendored 的 KallRecon 对应上游
`b258fb6`（10-06），而上游已经到 `cec011b`（10-22）。

### 差距

| 文件 | 我们 | 上游 |
|---|---|---|
| `discover.c` | 28100 B | **33513 B**（+16%） |
| `discover.h` | 204 B | 654 B |
| `core.c` | 2030 B | 2517 B |
| `hint.c` | 1857 B | 1910 B |

`access` / `fastboot` / `slide` / `symbol` / `variant` / `anchor.S` 完全一致。

### 上游多出来的东西

- **`kr_setup_token_table()`** —— token_table 自校验。取 `token_table['0']`
  读一个字节，必须真的是字符 `'0'` 才认这张表：

  ```c
  if (safe_read(&c, (void *)(h->token_table + off0), 1) || c != '0') {
      kr_fail_set(KALLRECON_HINT_INVALID);
      return 0;
  }
  ```

  猜错 token table 是 kallsyms 解析失败的主要原因之一，这个自校验直接排掉。
- **`kr_check_ti_strong()`** —— 更强的 token_index 校验
- **`kr_layout_from_offsets()`** / `kr_commit_offsets()` —— 偏移提交
- **`hint.c`** 把 `kr_fail` 从普通变量改成 `atomic_t`，`kr_fail_set` 用
  `atomic_cmpxchg`（原来是非原子的 check-and-set，多核会竞态）

### 为什么值得升

那位 5.10 用户的内核是 `marble@github-actions` 用 clang 22 重编的
`5.10.269-gki-g658b84f13496-dirty` —— **自定义内核正是 kallsyms 布局最容易
偏离标准 GKI 的情况**，而 KallRecon 能不能在它上面正确找到 kallsyms，是我们
所有模块能不能工作的前提。

### 兼容性

上游的改动对调用方**纯新增**（新函数 + `KS_*` 宏），没有删除。

`discover.c` 里新增的 `raana/` 并行扫描引擎是 `#ifdef KALLRECON_RAANA`
条件编译的，我们不定义它 —— 自动走原有 legacy 扫描路径，不需要引入 raana。

### 验证

两个模块重新编译通过；`readelf -sW` 确认 `kr_setup_token_table` 和
`kr_layout_from_offsets` 已链入产物；重定位自检 0 错。

### 另外挖到的一条（已核实，不是问题）

`inte.ko_oplus` 里有 OPPO 内核安全模块的 872 行逆向源码。它的行为：

- **每小时 SHA256 校验 `sys_call_table`** —— 我们完全不碰 syscall 表
  （`nm lkm4ctr.ko | grep sys_call_table` = 0），不会触发
- **校验每个加载的 .ko 的 SHA256、比对白名单** —— 我们的模块不在白名单，
  会被记一条 `unknown ko` 事件到 `/proc`，但**只记录，不 panic、不阻断**

所以 OPPO 设备上我们的模块是安全的；那条「MTK 内核保护把系统打挂」的归因
应该另有其因，不是 inte.ko。

## v0.1.20 — 修 6.6/6.12 的 lkm4ctr（它们从来没编出来过）

`versionCode` 20261135。

v0.1.19 加的「8 个模块一个都不能少」检查立刻暴露了一个**一直存在**的缺口：

```
[FAIL] android15-6.6  缺少模块: lkm4ctr
[FAIL] android16-6.12 缺少模块: lkm4ctr
```

之前构建脚本容忍单个模块失败（带 warning 继续），所以 Android 15（6.6）和
Android 16（6.12）的用户从来就没拿到过主模块 —— 拿到的包里只有 6 个外围模块。

### 根因

`glue/vendor_hook_stubs.c` 里的弱定义按 ≤6.1 的签名写死了：

```
vendor_hook_stubs.c:44: error: conflicting types for
'_trace_android_vh_record_pcpu_rwsem_starttime'
```

这些 Android vendor hook 的**签名和存在性都随内核版本变**。逐分支核对
AOSP `kernel/common` 的 `include/trace/hooks/dtask.h`：

| 内核 | `starttime` | `time_early` | `rdheld_starttime` |
|---|---|---|---|
| ≤6.1 | `(task_struct *, ulong)` | `(ulong, percpu_rwsem *)` | — |
| 6.6 | `(percpu_rwsem *, ulong)` | **已移除** | 新增 |
| 6.12 | `(percpu_rwsem *, ulong)` | 已移除 | 已移除 |

### 修法

按 `LINUX_VERSION_CODE` 分别给定义：

- `starttime`：6.6 起第一个参数从 `task_struct *` 换成 `percpu_rw_semaphore *`
- `time_early`：只在 6.6 之前定义
- `rdheld_starttime`：只在 6.6 这一代定义

全部仍是 `__weak`：内核导出了就用内核的，没导出才用空实现。这两个 hook 只用于
rwsem 争用时间统计，空实现不改变任何锁语义。

### 验证

8 个补丁依次应用 + 编译通过；CI 上 android15-6.6 / android16-6.12 两个作业
现在都能产出 lkm4ctr。

## v0.1.19 — v0.1.18 的模块包缺了 pids/cpu

`versionCode` 20261134。**v0.1.18 的包只有 6 个模块，缺 droid_lkm_pids 和
droid_lkm_cpu，立刻升级。**

### 怎么回事

v0.1.18 加了构建期重定位自检 `reloc_audit()`，但我把**函数定义放在了调用点之后**：

```
scripts/build_modules.sh: line 242: reloc_audit: command not found
##[warning]droid_lkm_pids @ android12-5.10 符号类型自检失败，已删除产物
```

bash 是顺序执行的，调用时函数还不存在 → 自检永远"失败" → 每个 KMI 的
pids / cpu 产物都被当成有问题删掉了。所有 KMI 都受影响，不只是 5.10。

自检的失败分支是「删产物 + 跳过」，所以构建本身还是绿的 —— 这是这次没被发现的原因。

### 修法

把 `reloc_audit()` 的定义挪到 `log()`/`warn()` 之后（第 39 行），调用在 270 行。
顺序正确后：

| 产物 | 审计结果 |
|---|---|
| v0.1.17 的 pids（好） | ✅ 通过 |
| v0.1.16 的 pids（坏） | ✅ 拦下，报 `kallrecon_klp` |

用真实产物验证过，不是只靠推理。

### 教训

**自检的失败分支不能悄悄删产物然后让构建继续绿。** 这次如果有「产物数少于预期
就失败」的断言，问题在 CI 就会暴露，而不是等我下完包才发现少两个模块。

已加：各 KMI 的产物数量在打包前会校验，少一个就红。

## v0.1.18 — 构建期自检：抓「符号类型写错」

`versionCode` 20261133。**不改运行时行为**，只是让 v0.1.15 那类事故不能再流出去。

### 背景

v0.1.15 我把 `kallrecon_klp`（函数指针**变量**）声明成了函数，符号名对得上所以
链接过得去，运行时却跳到数据地址执行，写坏内存后在 `_regulator_disable` 崩。
构建全程无错、无警告。

**C 的类型检查跨编译单元看不到声明不一致**，`-Werror` 也抓不到。唯一的发现方式是
看最终产物的**重定位类型**：

| | 重定位 | 含义 |
|---|---|---|
| 正确 | `ADR_PREL_PG_HI21` + `LDST64` | 从内存取出指针值，再间接调用 |
| 错误 | `CALL26` | 直接 call 到那个数据变量的地址 |

### 加了什么

`scripts/build_modules.sh` 里的 `reloc_audit()`：

```
模块内定义为 OBJECT（数据）的符号  ∩  CALL26（函数调用）的目标  = 可疑
```

交集非空就判该产物有问题：记日志、**删掉产物**、跳过，不让它进 zip。

接在 pids/cpu 两个模块的产物复制处（这两个是最容易出现跨 TU 声明不一致的，
因为它们共用 `kr/` 的 KallRecon）。

### 方法验证过

拿已知有问题的 v0.1.16 产物跑这个审计：

```
✅ 审计有效，抓到: kallrecon_klp
```

再跑修复后的 v0.1.17：

```
✅ 没有「对数据符号 CALL26」的情况
   （pids: 80 个 OBJECT / 66 个 CALL26 目标；cpu: 77 / 68）
```

## v0.1.17 — 修正 v0.1.15 引入的 panic（函数指针声明成函数）

`versionCode` 20261132。**v0.1.15 和 v0.1.16 会 panic，立刻升级。**

### 现场

真机加载到 `droid_lkm_pids` 时 panic，面包屑（v0.1.13 加的）直接点名：

```
loading = droid_lkm_pids
```

日志停在这里：

```
[OK] lkm4ctr / devtmpfs_lkm / ip6table_nat / macvlan / vkms
← 正在加载 droid_lkm_pids
```

panic 位置：

```
pc : _regulator_disable+0x68/0x20c
lr : _regulator_disable+0x64/0x20c
```

**崩在电源管理路径**——和 pids 毫无关系，这是典型的内存被写坏之后在别处踩雷。

### 根因

`kallrecon_klp` 在 `kr/core.h` 里的真实类型是**函数指针变量**：

```c
extern unsigned long (*kallrecon_klp)(const char *name);
```

我在 v0.1.15 新建的 `common.c` 里写成了**函数**：

```c
extern unsigned long kallrecon_klp(const char *name);   // ← 错
```

符号名相同，所以**链接过得去**，但运行时语义完全不同：

| | 重定位 | 实际行为 |
|---|---|---|
| v0.1.16（坏） | `R_AARCH64_CALL26` | 直接 `call` 到**存放指针的那个数据变量的地址**，等于执行随机指令 |
| 修复后 | `R_AARCH64_PREL_PG_HI21` + `LDST64` | 先从内存**取出指针值**，再间接调用 |

从 release 产物直接对比可以复现这个差异（`readelf -rW droid_lkm_pids.ko | grep kallrecon_klp`）。

### 修法

1. 声明改成 `extern unsigned long (*kallrecon_klp)(const char *name);`
2. **加了判空**：它在 `kr` 初始化完成前是 `NULL`，直接调用会跳到 0
3. 去掉 `common.c` 里的 `EXPORT_SYMBOL_GPL`（它是链进别的模块的 `.o`，不是独立模块）
4. 去掉 `common.c` 里的 `MODULE_LICENSE`（模块信息只由主源文件提供）

### 验证

修复后两个模块的符号/重定位：

```
readelf -sW  → OBJECT GLOBAL kallrecon_klp      （数据符号）
readelf -rW  → ADR_PREL_PG_HI21 + LDST64        （取指针值再间接调用）
```

### 教训

**跨编译单元引用全局符号时，类型必须和定义处完全一致。** 符号名对得上就不会有链接错误，
错的是运行时语义——而且错法极其隐蔽：不崩在调用点，崩在几十毫秒之后某个无关的
内核路径上。

`EXTRA_CFLAGS += -Werror` 抓不到这种错，因为它不是类型检查能发现的（跨 TUs，
C 语言只看声明）。唯一可靠的防线是**核对定义处的声明**，以及 `readelf` 看重定位类型。

## v0.1.16 — KMI 判代际改用出厂 API level

`versionCode` 20261131。

来自 [Dere3046/_patchHarmony](https://github.com/Dere3046/_patchHarmony) 提交
`f7c757e`（他们那边是 issue #6）。

### 问题

内核串里没有 `androidNN` 时（那位 5.10 用户的
`5.10.269-gki-g658b84f13496-dirty` 就是），我们靠 `ro.build.version.release`
在 `android12-5.10` / `android13-5.10` 之间猜。

**但 `release` 会跟着 OTA 升级走，而 KMI 固定在设备出厂那一代。**

典型故障：一台出厂 android13 的设备升到 Android 16 之后，`release=16`，
映射出 `android16`，而候选集是 `{android12, android13}` —— 一个都不匹配，
于是退回到"取第一个"，也就是 android12-5.10。**代际选错了。**

（选错不会炸机，insmod 会因符号版本不符失败，但用户看到的是"模块装不上"。）

### 修法

改用 `ro.board.first_api_level`（出厂 API level，OTA 不会改它），
拿不到再退 `ro.product.first_api_level`：

| 值 | 代际 |
|---|---|
| 31 / 32 | android12 |
| 33 | android13 |
| 34 | android14 |
| 35 | android15 |
| 36 | android16 |
| 37 | android17 |
| `YYYYMM`（厂商格式） | android(YYYY - 2009) |

都拿不到才退回 `release` / `sdk` —— 它们会漂，但比没有强。

### 实测

本机就是这个问题的活样本：

```
ro.board.first_api_level = 34   → android14  ✅ 与内核 6.1 一致
ro.build.version.release = 17   → android17  ❌ ROM 伪造
ro.build.version.sdk     = 37   → android17  ❌ 同上
```

六个真实场景的映射全部正确，包括那位 5.10 用户的
`5.10.269-gki-g...` + `first_api_level=33` → **android13-5.10**。

## v0.1.15 — 清掉 7476 行死代码，pids/cpu 抽出共享层

`versionCode` 20261130。纯内部整理，不改运行时行为。

### 一、删除从未参与构建的目录（-7476 行）

| 目录 | 行数 | 为什么是死代码 |
|---|---|---|
| `extra/pids/` | 1066 | **和 `cgrouplimits/pids_mod.c` 是两套完整的 pids 控制器实现**。构建脚本只引用 `cgrouplimits` 那份 |
| `extra/net_macvlan/` | 2136 | macvlan 实际从**内核树自带** `drivers/net/macvlan.c` 编译 |
| `extra/net_macvlan_61/` | 1845 | 同上，另一份副本 |
| `extra/vkms/` | 1894 | vkms 实际从**内核树自带** `drivers/gpu/drm/vkms` 编译 |
| `extra/vgem/` | 535 | 从未被任何地方引用 |

顺带清掉 `extra/cgrouplimits/` 里被提交进仓库的编译产物
（`.ko` / `.o` / `.mod` / `.mod.c` / `Module.symvers` / `modules.order`），
以及 `module/service.sh` 里指向已删目录的过时注释。

### 二、pids / cpu 抽出共享层

`pids_mod.c`（901 行）和 `cpu_mod.c`（902 行）原先各自实现了一整套
cgroup 布局校验，但只有 **15% 的行逐字相同** —— 因为 cpu 那份是照着 pids
抄的（`cpu_mod.c` 里还留着注释「同 droid_lkm_pids 的做法」）。

**真正的问题是校验强度已经漂移：**

| 校验 | pids | cpu（改前） |
|---|---|---|
| `init_css_set.dfl_cgrp == &cgrp_dfl_root.cgrp` | ✅ | ✅ |
| `init_task.cgroups == &init_css_set` | ✅ | ❌ **缺失** |

只做第一重时，如果 `task_struct.cgroups` 的偏移算错，会在 fork 路径上写坏
内存，而且现场离肇事点很远——和 rhashtable 那个坑是同一性质。

新增 `common.c`（138 行）+ `common.h`（91 行），提供：

```c
ctl_read_ptr()        安全读内核指针（nofault）
ctl_is_kptr()         判内核指针
ctl_anchors_resolve() 解析 cgroup_subsys / init_css_set / cgrp_dfl_root / init_task
ctl_subsys_count()    数 cgroup_subsys[] 里真实的控制器数
ctl_layout_probe()    修正编译期偏移 + 两重校验
```

`pids_mod.c` 901→861，`cpu_mod.c` 902→880，两边都调 `ctl_layout_probe()`，
**cpu 侧因此自动获得之前缺失的第二重校验**。

`common.o` 分别链进两个 `.ko`（`droid_lkm_pids-y := pids_mod.o common.o ...`），
**两个模块仍然各自独立、可以单独 insmod / rmmod** —— 这一点和 `kr/`
（KallRecon）一样，是刻意的重复，不能合并。

### 三、确认过的「不是重复」

- `lkm4ctr` 不含 cgroup 控制器代码（`cgroup_add_dfl_cftypes` 0 处）→ 与
  `droid_lkm_pids` / `droid_lkm_cpu` 无功能重叠
- `lkm4ctr` 注册的是自己的 `lkm4ctr_diagfs`，**不是** devtmpfs → 与
  `devtmpfs_lkm` 无重叠
- kprobe 目标互不冲突：pids → `cgroup_controllers_show` / `proc_cgroupstats_show`；
  cpu → `cgroup_rmdir`；uart_guard → `uart_get_info` / `console_show`

### 验证

两个模块都重新编译通过，`readelf -sW` 确认 `ctl_layout_probe` 等 5 个函数
在两个 `.ko` 里都是**定义**（不是未定义引用）。

### 过程记录

改这两个文件时，我三次把 `\n` 写成真实换行导致编译失败（Python 生成代码的
老问题）。第一次编译"通过"其实是增量缓存——`cpu_mod.c` 的 .o 没重编。
删掉所有产物重新编译才暴露出来。教训：**改完必须清干净再编**。

## v0.1.14 — 甩掉内核 rhashtable（这才是 5.10 崩溃的真凶）

`versionCode` 20261129。

对照 [Dere3046/_patchHarmony](https://github.com/Dere3046/_patchHarmony) 的
**issue #12** 查出来的。那台设备是 **vivo MT6989 6.1.145**，和我们同一个 SoC 家族。

### 机制

`struct ipc_namespace` 是我们自己 `kzalloc` 的，大小按**编译期** `sizeof()` 算：

```c
ns = kzalloc(sizeof(struct ipc_namespace), GFP_KERNEL_ACCOUNT);
```

但 `rhashtable_init()` / `rhashtable_insert_slow()` 是**内核里的**函数，它们按
**内核的** `struct rhashtable` 布局去初始化嵌在 `ids[]` 里的 `key_ht`。

内核对不齐就写穿了我们自己的结构体 —— 堆破坏，表现为随机 panic 或直接卡死。
而现场离肇事点很远，几乎无法定位。

Dere3046 那台的实测差值：

```
module 编译期认为  ns @ 0x4e0
设备实际           ns @ 0x4f8     ← 差 0x18
```

24 字节 = `sizeof(struct ipc_ids)` 272 vs 280，×3（`ids[3]`）。

### 我们的情况

5.10 的 `lkm4ctr.ko` 里有 **3 个内核 rhashtable 符号**：

```
rhashtable_init
rhashtable_destroy
rhashtable_insert_slow
```

他们修好后的判据是 `nm -u | grep rhashtable` **归零**。

### 修法

我们的 SysV IPC 对象**全部由本模块自己分配、自己使用**，内核从不接触。
所以不需要内核那个哈希表 —— 用一条模块私有的单链表就够：

- `ipc_keylist_lookup/insert/unlink/clear`（util.c）
- `ipc_init_ids` 不再调 `rhashtable_init`
- `ipc_findkey` 改成线性扫描
- `ipc_addid` 改成链表头插入
- msg/sem/shm 的销毁路径改成 `ipc_keylist_clear`
- `ipc_kht_params` 整个删掉

容器里 SysV IPC 对象数量很小，线性扫描的开销可以忽略，换来的是**对内核
结构体布局完全不敏感**。

### 验证

本地构建 `nm -u lkm4ctr.ko | grep -c rhashtable` → **0**（改前 3）。

补丁编号 `0008-ipc-keylist-no-rhashtable.patch`，8 个补丁依次应用 + 编译通过。

### 为什么这可能就是 5.10 的真凶

那位用户的内核是自己用 GitHub Actions + clang 22 重编的
`5.10.269-gki-g658b84f13496-dirty`。**自定义 config 正是最容易让
`struct rhashtable` / `struct ipc_ids` 尺寸偏离标准 GKI 的情况** ——
而我们的老代码一旦被调起来就会写越界。

## v0.1.13 — v0.1.12 在真机上根本跑不起来

`versionCode` 20261128。**别再装 v0.1.12。**

v0.1.12 里我用 bash 的数组写法 `local -a cands=("$ko")` 做双代重试。
Android 的 `sh` 是 **mksh**，不认 `=()` 这个赋值形式，运行时直接：

```
service.sh[279]: syntax error: unexpected '('
```

后果是 `service.sh` 走完 KMI 识别就退出——**一个模块都不会加载**。
最要命的是 `bash -n` 查不出这个问题，因为那本来就是 bash 的语法检查器。

改成两次顺序尝试，不用数组。在真机上验证过：

```
[SKIP] uart_guard 在上次开机的黑名单里（加载它会卡死），跳过
```

（顺带说明 v0.1.12 的黑名单检查也在这次重写里被误删，一并修回。）

### 教训

模块脚本改动必须用 **mksh** 验语法，而不是 `bash -n`：

```sh
adb shell 'sh -n /data/adb/modules/droidspaces_lkm/service.sh'
```

Android 上没有独立的 `mksh` 命令，`sh -n` 就是它。

## v0.1.12 — 5.10 的三条修正 + 分模块面包屑

`versionCode` 20261127。

用户的内核是自己用 GitHub Actions 重编的：`5.10.269-gki-g658b84f13496-dirty`
（`marble@github-actions`，clang 22.1.8）。针对这台设备把 5.10 相关的疑点逐条查清。

### 一、5.10 有两代，之前只猜不验

`android12-5.10` 和 `android13-5.10` 共用同一个内核版本号。内核串里没有
`androidNN` 字样时（`5.10.269-gki-g...` 就是），只能靠属性猜，猜错就是"模块装不上"。

- `find_ko` 现在**先用 vermagic 验**精确匹配，不符就不给。
- `load_mod` 加了**换代重试**：一代 insmod 失败，自动换另一代再试一次。
  实测两代的 vermagic 都只有 `5.10` 这个粒度（我们的 ko 是 `5.10.252-dirty`），
  分辨不出来，所以运行时重试才是可靠办法。
- 顺带确认：**vermagic 在这套内核上不严格**——本机 `6.1.166-dirty` 的 ko 能装进
  `6.1.157-android14-...` 的内核，所以它不是 5.10 装不上的原因。

### 二、分模块面包屑 + 自动黑名单

之前只有一个全局计数器：连续 3 次没开机成功就整体禁用。它能救回设备，
但**说不出是哪个模块死在半路**。

现在 `service.sh` 在每个 `insmod` 前把模块名写进 `droidspaces_lkm.d/loading`
并 `sync`，成功后删掉。下次 `post-fs-data` 发现它还在，就说明上次开机是
在加载**那个具名模块**时死的：

- 写进 `blacklist`，以后直接跳过它（不再反复重启去试）
- 存一份 `crash-module.txt`
- 记进 kernel log

点「操作」按钮可以直接看到 `上次卡死: xxx` 和当前黑名单。

### 三、逐条核对过的结论（都不成立或已修）

| 说法 | 实情 |
|---|---|
| KMI 识别失败、回退到 android14-6.1 | 已在 issues/1 修掉。实测 `5.10.269-gki-g...` → `android12-5.10` |
| `__stack_chk_guard` / `cgroup_rm_cftypes` / `drm_crtc_add_crc_entry` | 已修。8/8 个 5.10 产物全部干净 |
| 6.1 的 vendor 代码在 5.10 上按 6.1 布局访问会 panic | 不成立。我们按 KMI 分别编译，结构布局来自 5.10 头文件 |
| 符号缺失 | 241 个外部符号都是标准导出符号；可疑的几个走运行时解析 |

### 四、v0.1.10 的 bugreport 说明：卡开机不是我们

`droidspaces_lkm.d/` 是**空目录**、日志只有 293 字节（只有保护触发那三行，
没有任何 `service.sh` 的记录）。也就是说在失败的那些开机里 **`service.sh`
根本没执行到**，模块一个都没加载。

所以那台 5.10 的卡开机，成因在 `post-fs-data` 之后、`late_start` 之前，
需要查别的模块。有了这版的面包屑，下次能直接给出名字。

## v0.1.11 — inline 装之前先判入口状态

`versionCode` 20261126。

对照 [Dere3046/_patchHarmony](https://github.com/Dere3046/_patchHarmony) 的实现查出来的问题：
**我们的入口状态探测写好了，但没有任何地方调用它。**

`hk_inline_probe()` 从实现那天起就是死代码——`hk_inline_apply()` 只校验参数，
从来不看入口长什么样，于是 `hk_inline_hook` 直接覆盖入口。

后果最典型的一条：**5.10/5.15 GKI 用 `-fpatchable-function-entry` 在函数入口
预留 ftrace patch 点**（`mov x9, lr`）。把它覆盖掉会破坏 ftrace 的记账，tracing
一 arm 就崩。开机阶段 ftrace 正在初始化，所以「手动 insmod 没事、开机加载卡死」
完全解释得通——这正是我们那个一直没结案的 inline 卡开机。

HooKern（他们用的引擎）对这种情况有专门的 `HK_INLINE_PATCHSITE` 状态并且在装前
拒绝。**我们同一个状态机也有，连注释都一样（"ftrace patch site at entry"），
就是没接上。**

修法：

- 新增 `hk_inline_probe_addr()` —— 按地址探测。原来 `hk_inline_probe()` 只能按
  符号名查，而 shadow_hook 自己解析符号、只有地址，所以接不上。
- `shadow_inline_install()` 在装之前调用它，`state != HK_INLINE_PLAIN` 就返回
  `-EOPNOTSUPP`，由 shadow_hook 现有的逻辑落到 kprobe。

判据与 HooKern 一致，八种状态全部覆盖：符号没解析到、入口读不出来、重定位器
拒绝、入口已有分支桩、**ftrace patch 点**、入口里有直接 `b`、窗口被别的活钩子占住。

### 顺带核对的两件事（确认我们本来就是对的）

- **写路径**：我们 inline 走的是 `hk_write_kernel()`，先查
  `hk_patch_kernel_primitive_ok()`，能用内核原语就用，够不着才退到 fixmap。
  和他们对 MTK 的结论一致（他们说「模块自己映射别名写」会被内核保护打挂，
  他们彻底删了那条路——我们的 inline 引擎本来就没走那条）。
- **CFI**：他们为 5.10/5.15 用 `#pragma clang attribute` 覆盖整个区域，因为
  `SYSCALL_DEFINE` 把函数体放在内层函数里、外层 `__nocfi` 到不了。我们代码里
  没有真正的 `SYSCALL_DEFINE` 宏，包装函数都是普通 `__nocfi` 函数，**这一条不适用**。

## v0.1.10 — 补上 v0.1.9 漏掉的证据固化

`versionCode` 20261125。**v0.1.9 的 `hang-report.txt` 永远不会生成**，别用。

v0.1.9 里 `post-fs-data.sh` 少了一段：开机时把上一轮的 `snapshot.txt` 复制成
`prev-boot.txt`。少了这一步，保护触发时就没有"卡死那次"的快照可拿，
`hang-report.txt` 永远缺失——正是最需要的那份东西。

现在补上，并且加了一条回退：`prev-boot.txt` 不存在时（比如刚从旧版升级上来
的第一轮）直接用当前的 `snapshot.txt`。

### 快照内容也加强了

`sammary` 之外新增 **模块日志尾部**：dmesg 尾部很容易被充电 / 蓝牙 / CCCI 的
刷屏占满（实测 262KB 只够 53 秒），真正要看的"service.sh 走到哪一步"会被冲掉。
现在快照自带最近 30 行模块日志，事后只看 `hang-report.txt` 一个文件就够。

### 实测：完整证据链

用真实重启验证（不是模拟）：

1. 开机跑 `service.sh` → `snapshot.txt` 5003 字节（uptime 104，8 个模块引用计数齐全）
2. 重启 → `post-fs-data` 把它复制成 `prev-boot.txt`（5003 字节 ✅）
3. 计数器超过阈值 → `hang-report.txt` 5003 字节 ✅ + `disable` ✅ + 计数器归零 ✅
4. 持久日志里两条带时间戳的记录 ✅

### 关于 panic 的一个测量结果（重要）

我用 `echo c > /proc/sysrq-trigger` 真实触发了一次 panic 来验证：

- panic 本身被 pstore 完整捕获（`Kernel panic - not syncing: sysrq triggered crash`）✅
- **但我们的日志行在 pstore 里 0 命中** ❌

原因不是日志没写进去，而是 **ramoops 只有 262KB，在这台设备上只够 53 秒**
（实测覆盖 482s → 535s）。panic 发生在 uptime 535s，而我们的日志在 415s 左右，
差 120 秒，早被冲掉了。

结论：**对开机卡死（发生在几十秒内）这个窗口够用；对"开机很久之后才崩"不够。**
所以快照文件（我们自己落盘、`sync` 过）才是主力，dmesg 只是补充。

## v0.1.9 — 让卡开机这件事有据可查

`versionCode` 20261124。

5.10 用户报了卡开机，我们收到 bugreport 之后发现**什么都查不到**：

| 想看的 | 实际 |
|---|---|
| 那次开机的内核日志 | `bootlog/dmesg.old.log` 是 840KB 全 `0x00`（KernelSU 导出失败） |
| pstore | 空 —— 卡死不是 panic，pstore 只记 panic |
| 我们的脚本日志 | 写在 `/data/local/tmp`，**bugreport 完全不抓这个目录** |
| `/data/adb` 下的文件 | 只抓 `ls -l` 列表，不抓内容 |

唯一确定的只有 `disable` 文件存在（我们的保护触发过），但**没法判断是不是我们的模块造成的**。

### 四层改造

**1. 日志同时进 kernel log**

```sh
dlog() {
    printf '%s
' "[$(date '+%m-%d %H:%M:%S')] $*" >> "$LOG"
    printf '<6>droidspaces_lkm: %s
' "$*" > /dev/kmsg
}
```

KernelSU 的 bugreport 是**按内容**导出 dmesg 的（进 `bootlog.tar.gz`），
所以进 kernel log 的日志才能被自动收走。`dlog` 必须 `return 0`——
它出现在 `test && dlog ... || dlog ...` 里，`/dev/kmsg` 不可写时返回非 0
会把成功误报成失败。

**2. 日志文件移到 `/data/adb/`，不截断而是轮转**

`/data/adb/droidspaces_lkm.log`，超过 256KB 轮转一份。

**3. 后台快照守卫（卡死现场）**

`service.sh` 加载完模块后起一个后台循环，**10 分钟内每 15 秒**把
`uptime / 负载 / 每个模块的引用计数 / renderD128 有无 / dmesg 尾部 40 行`
写进 `snapshot.txt` 并 `sync`。

`sync` 是必须的：不 sync 的话数据还在 page cache 里，卡死重启就丢了。
真卡死时，**最后一份 snapshot.txt 就是现场**。

**4. 保护触发时固化证据**

`post-fs-data.sh` 在开机最开头把上一轮的 `snapshot.txt` 复制成
`prev-boot.txt`；等计数器超过 3、准备写 `disable` 时，再把它复制成
`hang-report.txt`。这份文件不会被后续启动覆盖。

### 排查时怎么取

```sh
adb pull /data/adb/droidspaces_lkm.d/hang-report.txt   # 卡死那次最后 15 秒的状态
adb pull /data/adb/droidspaces_lkm.log                 # 跨重启的持久日志
```

没 adb 的话，点模块页的「操作」按钮，首屏直接显示：开机计数、`disable` 状态、
`hang-report.txt` 在不在、状态快照多大。

### 实测

本机（6.1）跑一遍完整 `service.sh`：

- dmesg 里出现 **30 行** `droidspaces_lkm:` 前缀的日志 ✅
- `/data/adb/droidspaces_lkm.log` 1407 字节，每行带时间戳 ✅
- `snapshot.txt` 稳定刷新（16:34:34 → 16:35:04），内容含 8 个模块的引用计数 ✅

修复过程中自己踩了一个坑：一开始用 Python 生成脚本时 `
` 被写成了**真实换行**，
awk 的格式串因此变成未闭合字符串，模块列表整段为空。现在格式串里的换行
统一用转义写法，并且实测确认有输出。

## v0.1.8 — 修 v0.1.7 把 vkms 弄丢的回归

`versionCode` 20261123。

v0.1.7 里我加的 `patch_vkms_debugfs.py` 要求**两处补丁都成功**才算通过，
而它匹配的字符串来自 6.1 的 vkms 源码：

- 6.1 / 5.15 的 vkms 有 CRC 上报 + debugfs 配置展示（两处）
- **5.10 的 vkms 只有 CRC 上报，根本没有 debugfs 那段代码**

于是在 5.10 上脚本判失败 → 构建脚本 `SKIP_VKMS=1` → **v0.1.7 的
`vkms-android12-5.10.ko` 整个缺失**。这比"装了报错"更糟：用户看到的是功能凭空消失。

改成按"这个版本的源码用不用这个符号"判断：

| 情况 | 处理 |
|---|---|
| 文件里没有这个符号 | 无事可做，算成功 |
| 有符号且调用点形状匹配 | 替换掉 |
| 有符号但形状不匹配 | 失败，跳过出货 |

第三种保留是刻意的：宁可不出货，也不要出一个"编过了但装不上"的 vkms。

实测两种源码都通过：6.1（两处都在）打补丁成功；模拟 5.10（无 debugfs）优雅跳过，
退出码都是 0。打补丁后的 vkms 仍不引用任何 DEBUG_FS 符号。

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