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