# cgroup 限制仿真（`--cpus` / `--pids-limit`）

[English](README.md)

在 `CONFIG_CFS_BANDWIDTH=n`、`CONFIG_CGROUP_PIDS=n` 的原厂内核上，让
Droidspaces 的 `--cpus` 与 `--pids-limit` 实际生效。

真机验证：OPPO Find X7（MT6989，`6.1.157-android14-11`，KMI `android14-6.1`）。

```
droid_lkm_pids.ko   移植自 ai-luo2006/droidspaces-6.12-pmb110 的 Plan B
droid_lkm_cpu.ko    时间片限流，自研实现
```

---

## 动机

| 能力 | 内核现状 | 表现 |
|---|---|---|
| `--pids-limit` | `CONFIG_CGROUP_PIDS=n`，pids 子系统不存在 | 写 `pids.max` 失败，预检查项不通过 |
| `--cpus` | `CONFIG_CFS_BANDWIDTH=n`，`cpu.max` 写路径与执行体（`tg_set_cfs_bandwidth`、`throttle_cfs_rq`）被 `#ifdef` 整体删除 | 写 `cpu.max` 失败，预检查项不通过 |

两项配置都在编译期移除代码。LKM 无法重新启用被删除的路径，只能仿真——由模块提供接口、记账与执行。

---

## pids 模块（Plan B，移植自 6.12）

四层结构，与上游一致：

| 层 | 手段 |
|---|---|
| 显示层 | kretprobe `cgroup_controllers_show` / `proc_cgroupstats_show`，追加 `"pids cpu"` |
| 文件层 | `cgroup_add_dfl_cftypes(memory_cgrp_subsys, ...)` 挂载 `pids.max`、`pids.current`、`pids.stats` |
| 执行层 | kprobe `cgroup_can_fork`：超限时置 `regs->pc = regs->regs[30]` 与 `x0 = -EAGAIN`，函数体不执行；`cgroup_post_fork` 计数 +1；`cgroup_exit` −1 |
| 翻译层 | kprobe `cgroup_subtree_control_write`：抹除 `+pids` / `+cpu`，必要时替换为 `+memory` |

fork 拒绝通过跳过被探测函数、经返回寄存器返回 `-EAGAIN` 送达，用户态得到的 errno 与真实控制器一致。

约束：

- **布局自校验。** `struct css_set` 以 `subsys[CGROUP_SUBSYS_COUNT]` 开头。运行时从 `cgroup_subsys[]` 读取实际控制器数并据此修正偏移。`init_css_set.dfl_cgrp` 与 `init_task.cgroups` 两重校验必须同时通过，否则不安装 fork 探针。
- **重复 enable `+pids` 返回 EFAULT。** 翻译层仅在 memory 未启用时改写缓冲区；已启用时清空缓冲区后直接返回。
- **显示层必须同时声明 `cpu`。** Droidspaces 读取 `cgroup.controllers` 选择 v2 路径。只声明 `pids` 会让 `--cpus` 走 v1 路径继而失败。

### 真机验证

```
$ dmesg | grep droid_lkm_pids
layout verified: controllers=7 (built against 7)
pids limit enforcement active (emulated pids controller)

# 手工测试，pids.max=5
第 1 次 current=2 ... 第 4 次 current=5   <- 到达上限
第 5 次 current=2 ... refused=3            <- 被拒绝

# Droidspaces 容器，--pids-limit=64
pids.max = 64
fork 60 次后 refused=2
容器内: /bin/sh: can't fork: Resource temporarily unavailable
```

---

## cpu 模块（自研实现）

内核缺少 CFS 带宽执行体，改用时间片限流：

```
cpu.max 文件   挂到 memory 子系统；解析 "<quota_us> <period_us>"
记账           delayed_work 每 10 ms 采样：遍历 cgroup 子树，
               累加 task_sched_runtime()（ns）
窗口判定       window_used = 累计值 - 窗口基准；>= quota 即超限
超限动作       css_task_iter 遍历进程发送 SIGSTOP
窗口结束       重置基准，发送 SIGCONT
```

### 开发中遇到的失效模式

以下每一项都在开发过程中导致过 panic 或静默失效。

1. **hrtimer 上下文 panic。** `filp_open` 进入 VFS 层，该层不可在 hrtimer 中断上下文调用；在 `do_mem_abort` 中出错并 panic。改为 `delayed_work`（进程上下文）。

2. **CFI 陷阱 panic。** `CONFIG_CFI_CLANG=y` 下，经 KallRecon 解析的函数指针做间接调用会触发 CFI 检查。所有含间接调用的函数标注 `__nocfi`。

3. **SELinux 拒绝通过 VFS 读取 `cpu.stat`（EACCES）。** 模块域下 `filp_open` 无法打开 cgroup 文件。改用内核内部数据。

4. **`struct cgroup.bstat` 偏移不匹配。** 设备内核与本地树的 commit 不同，布局校验通过但 `bstat` 读出 0。改为按任务累加 `task_sched_runtime`。

5. **采样间隔等于窗口周期。** tick 100 ms 与 period 100 ms 时，每次采样要么设置基准要么重置窗口，配额检查永远不执行。tick 改为 10 ms。

### 真机验证

```
$ dmesg | grep droid_lkm_cpu
layout ok: controllers=7 bstat_off=984
over quota (62593 >= 50000), SIGSTOP     <- --cpus=0.5，窗口内超限
window reset, SIGCONT
over quota (57774 >= 50000), SIGSTOP
window reset, SIGCONT

容器内 ps 出现 T (stopped) 进程           <- 进程确实被冻结
```

---

## 已知限制

| 项 | 说明 |
|---|---|
| 迁移进程不计数 | 记账覆盖在 cgroup 内 fork 的进程；从外部迁移进来的进程不计入。与真实控制器存在差异。 |
| cpu 用时间片而非平滑限流 | SIGSTOP 比 CFS throttle 更粗；进程可能在窗口剩余时段内整体暂停。 |
| 10 ms 记账粒度 | 对 busy loop 准确；短突发可能漏计。 |
| `rmmod` 清空配置 | 重载后需重新写 `cpu.max` / `pids.max`。通过 Droidspaces 重启容器即可。 |
| 冻结仅发 SIGSTOP | SIGSTOP 不可捕获也不可忽略，因此覆盖容器内全部进程。 |

---

## 加载

```bash
su -c 'insmod /data/local/tmp/droid_lkm_pids.ko'
su -c 'insmod /data/local/tmp/droid_lkm_cpu.ko'

# 卸载（先停止容器）
su -c 'rmmod droid_lkm_cpu; rmmod droid_lkm_pids'
```

加载顺序无关。Droidspaces 创建容器时两个模块必须都在，否则限制写入失败后被跳过，需重启容器重试。

---

## 构建

```bash
# WSL，内核树位于 ~/zram/common（6.1.157）
bash /mnt/c/nomount/wsl/build_pids.sh
bash /mnt/c/nomount/wsl/build_cpu.sh
```

依赖：clang 20、已配置 `out/` 的内核树、从 `net_ip6nat/kr/` 复制到本目录的 KallRecon。

## 文件

```
extra/cgrouplimits/
├── Makefile
├── pids_mod.c          pids 仿真（6.12 Plan B 移植，显示层附加 "cpu"）
├── cpu_mod.c           cpu.max 时间片限流
└── kr/                 KallRecon（复制自 net_ip6nat/kr）
```

## 共用部分（`common.c`）

两个模块原先各自维护一套 cgroup 布局校验。901 / 902 行中仅 15% 逐字相同——cpu 那份由 pids 派生，`cpu_mod.c` 里仍留有「同 droid_lkm_pids 的做法」的注释。实际缺陷是校验强度发生了漂移：

| 校验 | pids | cpu（改前） |
|---|---|---|
| `init_css_set.dfl_cgrp == &cgrp_dfl_root.cgrp` | 有 | 有 |
| `init_task.cgroups == &init_css_set` | 有 | **缺失** |

只做第一重时，若 `task_struct.cgroups` 偏移计算错误，会在 fork 路径上写入错误内存，损坏现场远离出错点。

现已抽到 `common.c` / `common.h`：

```
ctl_read_ptr()         安全读取内核指针（copy_from_kernel_nofault）
ctl_is_kptr()          内核指针范围判定
ctl_anchors_resolve()  解析四个布局锚点符号
ctl_subsys_count()     统计 cgroup_subsys[] 中真实控制器数
ctl_layout_probe()     修正编译期偏移，执行两重校验
```

两侧均调用 `ctl_layout_probe()`，cpu 侧因此获得此前缺失的第二重校验。

`common.o` 分别链入两个 `.ko`；两个模块仍各自独立，可单独 insmod / rmmod。这一重复是刻意的，与 `kr/`（KallRecon 同样各链一份）相同。

## IPC key 索引不使用内核 rhashtable

`struct ipc_namespace` 由模块用 `kzalloc` 按编译期 `sizeof` 分配，而 `rhashtable_init()` 是内核函数，它按**内核的** `struct rhashtable` 布局初始化嵌在 `ids[]` 里的 `key_ht`。目标内核的结构体一旦大于构建时的大小，该次初始化就会越界写入——堆破坏，表现为随机 panic 或卡死。

（`Dere3046/_patchHarmony` issue #12 在一台 MT6989 `6.1.145` 上实测相差 `0x18`：`sizeof(ipc_ids)` 272 对 280，三处。）

修法：`vendor/ipc/` 将 key 索引改为模块私有的单链表（`ipc_keylist_lookup/insert/unlink/clear`），使 `nm -u *.ko | grep rhashtable` 无输出。容器内 SysV IPC 对象数量很少，线性扫描开销可忽略，换来的是对内核结构体布局完全不敏感。