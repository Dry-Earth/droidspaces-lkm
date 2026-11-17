/* SPDX-License-Identifier: GPL-2.0 */
/*
 * droid_lkm_pids / droid_lkm_cpu 的公共基础设施。
 *
 * 为什么要有这个文件
 * ------------------
 * 两个模块原先各自实现了一整套「cgroup 结构体布局校验」：
 *
 *   pids_mod.c: ctl_read_ptr / ctl_is_kptr / ctl_layout_init
 *   cpu_mod.c : ctl_read_ptr / cpu_layout_init
 *
 * 两份 901 / 902 行的文件里只有 15% 的行逐字相同 —— 因为 cpu 那份是照着
 * pids 抄的（cpu_mod.c 里还留着注释「同 droid_lkm_pids 的做法」）。
 *
 * 真正的问题是**校验强度已经漂移**：pids 做了两重校验
 *   1. init_css_set.dfl_cgrp 必须等于 &cgrp_dfl_root.cgrp
 *   2. init_task.cgroups      必须等于 &init_css_set
 * 而 cpu 只做了第一重。哪天发现第三重校验必要，改一处漏一处就是下一个 panic。
 *
 * 所以把它抽出来。两边拿到同样的校验，改动只需要做一遍。
 *
 * 注意：这里只共享**源码**，不合并 .ko。common.o 分别链进两个模块，两个模块
 * 仍然各自独立、可以单独 insmod / rmmod。
 *
 * 关于偏移修正的原理
 * ------------------
 * offsetof 是编译期算出来的，按我们构建时用的头文件；真机上
 * struct css_set / struct task_struct 之内那些以 CGROUP_SUBSYS_COUNT 为长度的
 * 数组（css_set->subsys[]、task_struct->cgroups 之前的成员等）会随内核实际
 * 编进多少个 cgroup 控制器而伸缩。所以运行时数一遍 cgroup_subsys[] 里真正
 * 有值的指针个数，差值 × 8 就是要修正的量。
 *
 * 这个思路和 rhashtable 那个坑是同一类：**别信编译期布局，运行时验一遍**。
 */
#ifndef DROID_LKM_CGROUPLIMITS_COMMON_H
#define DROID_LKM_CGROUPLIMITS_COMMON_H

#include <linux/kprobes.h>
#include <linux/types.h>

/*
 * 探针路由（module_param route）。
 *
 *   0 = auto     inline 优先，inline 装不上退回 kprobe（默认）
 *   1 = inline   只用 inline；装不上就放弃该探针
 *   2 = kprobe   只用 kprobe（改动前的行为）
 *
 * 存在意义：inline 命中是一条 b 指令（几十 ns），kprobe 命中要陷一次异常
 * （约 1-3 us）。cgroup_can_fork 每次 fork 都命中，是唯一的热路径。
 * 但 inline 需要精确的原函数签名，而 kprobe 的 pre_handler 只碰 regs、
 * 天然跨版本。所以只在签名已确认的版本上开放 inline，其余一律 kprobe。
 */
extern unsigned int ctl_route;

/* 引擎初始化：hk_init + 用 KallRecon 做 resolve 回调。失败返回负值。
 * 由 pids 模块实现并调用（cpu 不链引擎）。 */
int ctl_hk_init(void);
void ctl_hk_exit(void);

/* 布局锚点符号，运行时解析 */
struct ctl_anchors {
	unsigned long subsys;		/* cgroup_subsys[] */
	unsigned long init_css;		/* init_css_set */
	unsigned long dfl_root;		/* cgrp_dfl_root */
	unsigned long init_task;	/* init_task */
};

/* 验证结果，两个模块据此决定装不装 hook */
struct ctl_layout {
	int controllers;		/* cgroup_subsys[] 里实际的控制器数 */
	int built_against;		/* 构建时的 CGROUP_SUBSYS_COUNT */
	long delta_bytes;		/* (controllers - built_against) * 8 */
	unsigned long css_dfl_cgrp_off;	/* 修正后的 css_set.dfl_cgrp 偏移 */
	unsigned long task_cgroups_off;	/* task_struct.cgroups 偏移 */
	unsigned long kn_priv_off;	/* kernfs_node.priv 偏移 */
	bool css_verified;		/* 校验 1 通过 */
	bool task_verified;		/* 校验 2 通过 */
};

/* 安全读内核指针。失败返回 false，绝不因读不到而崩。 */
bool __nocfi ctl_read_ptr(unsigned long addr, unsigned long *out);

/* 判一个值像不像内核指针（0xffff.... 段且非 0） */
bool ctl_is_kptr(unsigned long v);

/*
 * 可选 kprobe。
 *
 * register_kprobe / unregister_kprobe / register_kretprobe /
 * unregister_kretprobe 原先是**静态链接**的：厂商内核只要没导出其中之一
 * （或干脆没编 CONFIG_KPROBES），insmod 直接 Unknown symbol，整个
 * droid_lkm_pids / droid_lkm_cpu 装不上 —— 连带文件层、显示层一起没了。
 *
 * 现在这 four 个改成经 KallRecon 运行时解析的函数指针：
 *   - 解析不到时 ctl_probe_register 返回 -ENOSYS，调用方按既有 best-effort
 *     语义跳过该探针，模块照常加载，只是限额/显示功能降级；
 *   - 不再产生对内核 kprobe 符号的静态依赖，模块能在无 kprobe 的内核上加载。
 *
 * 首次使用时懒解析（与 ZR_SYM / ctl_anchors_resolve 同一模式），
 * 必须在 find_kallsyms_base() 之后调用。
 */
int ctl_probe_register(struct kprobe *p);
void ctl_probe_unregister(struct kprobe *p);
int ctl_kretprobe_register(struct kretprobe *rp);
void ctl_kretprobe_unregister(struct kretprobe *rp);

/*
 * 解析四个锚点符号。缺任何一个就返回 -EOPNOTSUPP —— 调用方据此跳过所有
 * hook，只保留文件层（宁可功能少，也不要按错偏移写内核内存）。
 */
int __nocfi ctl_anchors_resolve(struct ctl_anchors *a);

/*
 * 数 cgroup_subsys[] 里真正有值的指针个数，也就是内核实际编进的控制器数。
 * 失败返回 -1。
 */
int __nocfi ctl_subsys_count(unsigned long subsys);

/*
 * 完整布局探测：解析锚点 → 数控制器 → 修正偏移 → 做两重校验。
 *
 * 两重校验缺一不可：
 *   1. init_css_set.dfl_cgrp == &cgrp_dfl_root.cgrp
 *   2. init_task.cgroups    == &init_css_set
 * 只做第一重时，若 task_struct 那边的偏移算错，会在 fork 路径上写坏内存，
 * 而且现场离肇事点很远。
 *
 * 返回 0 表示 out 可用且两重校验都过；否则返回负值，调用方不要装 hook。
 */
int __nocfi ctl_layout_probe(struct ctl_layout *out,
			     const char *warn_tag);

#endif /* DROID_LKM_CGROUPLIMITS_COMMON_H */