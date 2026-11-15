// SPDX-License-Identifier: GPL-2.0
/*
 * droid_lkm_pids / droid_lkm_cpu 的公共基础设施实现。
 * 见 common.h 里的说明。
 */

#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/sched.h>
#include <linux/cgroup.h>
#include <linux/kernfs.h>
#include <linux/uaccess.h>
#include <linux/errno.h>
#include <asm/rwonce.h>

#include "common.h"

/*
 * KallRecon 的解析入口。
 *
 * 注意类型：kallrecon_klp 是一个**函数指针变量**（kr/core.h 里
 * `extern unsigned long (*kallrecon_klp)(const char *name);`），
 * 不是函数。
 *
 * 这里一开始写成了 `extern unsigned long kallrecon_klp(const char *)`
 * ——符号名相同所以链接得过，但运行时实际是跳到「存放指针的那个数据
 * 变量的地址」去执行，等于执行随机指令，写坏内核内存，然后在完全无关
 * 的路径上崩（实测崩在 _regulator_disable+0x68）。
 *
 * 而且它在 kr 初始化完成前是 NULL，必须判空。
 */
extern unsigned long (*kallrecon_klp)(const char *name);

bool __nocfi ctl_read_ptr(unsigned long addr, unsigned long *out)
{
	if (!addr || !out)
		return false;
	return copy_from_kernel_nofault(out, (void *)addr, sizeof(*out)) == 0;
}

bool ctl_is_kptr(unsigned long v)
{
	if (!v)
		return false;
	/* arm64 内核虚拟地址最高 16 位全 1 */
	return (v & 0xffff000000000000UL) == 0xffff000000000000UL;
}

int __nocfi ctl_anchors_resolve(struct ctl_anchors *a)
{
	if (!a)
		return -EINVAL;
	if (!kallrecon_klp)
		return -ENODEV;

	a->subsys = kallrecon_klp("cgroup_subsys");
	a->init_css = kallrecon_klp("init_css_set");
	a->dfl_root = kallrecon_klp("cgrp_dfl_root");
	a->init_task = kallrecon_klp("init_task");

	if (!a->subsys || !a->init_css || !a->dfl_root || !a->init_task)
		return -EOPNOTSUPP;
	return 0;
}

int __nocfi ctl_subsys_count(unsigned long subsys)
{
	unsigned long v;
	int i, n = 0;

	if (!subsys)
		return -1;

	/*
	 * cgroup_subsys[] 末尾是空的，但有些内核会留 padding 或者空隙，
	 * 所以除了读得到，还要判它像个内核指针 —— 否则会把垃圾算成控制器。
	 */
	for (i = 0; i < 64; i++) {
		if (!ctl_read_ptr(subsys + (unsigned long)i * 8, &v))
			break;
		if (!ctl_is_kptr(v))
			break;
		n++;
	}
	return n > 0 ? n : -1;
}

int __nocfi ctl_layout_probe(struct ctl_layout *out, const char *warn_tag)
{
	struct ctl_anchors a;
	unsigned long expect_root, v, off;
	int controllers, ret;

	if (!out)
		return -EINVAL;
	memset(out, 0, sizeof(*out));
	out->built_against = (int)CGROUP_SUBSYS_COUNT;

	ret = ctl_anchors_resolve(&a);
	if (ret) {
		pr_warn("[%s] layout anchors missing (subsys=%d init_css=%d "
			"dfl_root=%d init_task=%d)\n",
			warn_tag ? warn_tag : "cgrouplimits",
			!!a.subsys, !!a.init_css, !!a.dfl_root, !!a.init_task);
		return ret;
	}

	controllers = ctl_subsys_count(a.subsys);
	if (controllers < 0) {
		pr_warn("[%s] cannot count cgroup_subsys[]\n",
			warn_tag ? warn_tag : "cgrouplimits");
		return -EOPNOTSUPP;
	}

	out->controllers = controllers;
	out->delta_bytes = (long)(controllers - out->built_against) * 8;
	out->css_dfl_cgrp_off = offsetof(struct css_set, dfl_cgrp) +
				(unsigned long)out->delta_bytes;
	out->task_cgroups_off = offsetof(struct task_struct, cgroups);
	out->kn_priv_off = offsetof(struct kernfs_node, priv);

	/* 校验 1：init_css_set.dfl_cgrp 必须等于 &cgrp_dfl_root.cgrp */
	expect_root = a.dfl_root + offsetof(struct cgroup_root, cgrp);
	off = out->css_dfl_cgrp_off;
	if (!ctl_read_ptr(a.init_css + off, &v) || v != expect_root) {
		pr_warn("[%s] css_set.dfl_cgrp unverified: controllers=%d "
			"off=%lu got=0x%lx want=0x%lx\n",
			warn_tag ? warn_tag : "cgrouplimits",
			controllers, off, v, expect_root);
		return -EINVAL;
	}
	out->css_verified = true;

	/* 校验 2：init_task.cgroups 必须等于 &init_css_set */
	off = out->task_cgroups_off;
	if (!ctl_read_ptr(a.init_task + off, &v) || v != a.init_css) {
		pr_warn("[%s] task_struct.cgroups unverified: off=%lu "
			"got=0x%lx want=0x%lx\n",
			warn_tag ? warn_tag : "cgrouplimits",
			off, v, a.init_css);
		return -EINVAL;
	}
	out->task_verified = true;

	return 0;
}
