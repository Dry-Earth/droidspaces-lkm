// SPDX-License-Identifier: GPL-2.0
/*
 * mali_nsfix - make the Mali kbase driver work from inside a PID namespace
 *
 * Problem
 * -------
 * kbase_create_context() (drivers/gpu/arm/midgard/context/mali_kbase_context.c)
 * does, roughly:
 *
 *     kctx->tgid  = current->tgid;          // host PID-namespace value
 *     rcu_read_lock();
 *     pid_struct  = find_get_pid(kctx->tgid);   // looked up in current's ns
 *     if (pid_struct) { ... } else { err = -ESRCH; }
 *     ...
 *
 * task_struct->tgid is always the value in the initial PID namespace, while
 * find_get_pid() -> find_vpid() searches the caller's active namespace. For a
 * process inside a container the two disagree, the lookup fails, and GPU
 * context creation is refused with -ESRCH. Android's own processes are not
 * affected because for them the two values are the same task.
 *
 * The vendor's own fix replaces the lookup with current->group_leader. This
 * module achieves the same result without touching the driver binary: it
 * intercepts find_get_pid() and, when the caller is inside a kbase module,
 * hands back a reference to the caller's own group leader. pid_task() on that
 * pid returns exactly the task the driver wanted, and the driver's put_pid()
 * balances the reference taken here.
 *
 * Because the redirected result equals what a host process would have got,
 * redirecting unconditionally for kbase callers is a no-op for Android and
 * the fix for containers - no namespace test is needed.
 *
 * Two interception backends
 * -------------------------
 * kprobe: replaces the first instruction of find_get_pid() with a BRK. Every
 *   call anywhere in the kernel traps into the exception vector, runs the
 *   handler, then single-steps the displaced instruction. Reliable, but the
 *   cost is paid by every find_get_pid() call in the system, not only Mali's.
 *
 * ftrace: find_get_pid() carries a call to __fentry__ at its entry (patched to
 *   a NOP at build time when CONFIG_DYNAMIC_FTRACE is on). dynamic ftrace
 *   rewrites that NOP into a branch to the tracing trampoline. With
 *   FTRACE_OPS_FL_IPMODIFY the handler may rewrite regs->pc, which is how
 *   livepatch redirects a function - no breakpoint, no exception, no
 *   single-step. The caller still pays the trampoline, but that is a direct
 *   branch and register save, not two exception round trips.
 *
 * ftrace is attempted first and kprobe is used if it cannot be armed. Both
 * paths produce identical behaviour; the difference is what each intercepted
 * call costs.
 *
 * Why not rebuild mali_kbase.ko
 * -----------------------------
 * Rebuilding the vendor driver needs its source, matching symbol CRCs against
 * the running kernel and replacing the module in vendor_dlkm (or rmmod-ing a
 * driver Android is actively using, which panics on the next GPU fence).
 * Neither backend here needs any of that, and both survive an OTA.
 *
 * Scope
 * -----
 * This only unblocks GPU context creation. Userspace still has to load the
 * vendor driver into the container (libhybris) and provide a render node.
 */

#include <linux/module.h>
#include <linux/kprobes.h>
#include <linux/pid.h>
#include <linux/sched.h>
#include <linux/sched/task.h>
#include <linux/rculist.h>
#include <linux/string.h>
#include <linux/kernel.h>
#include <linux/version.h>
#include <linux/errno.h>

#ifndef __nocfi
#define __nocfi
#endif

#define NSHF_NAME_MAX 64

/* Prefix matched against the name of the module that called find_get_pid(). */
static char mali_prefix[NSHF_NAME_MAX] = "mali_kbase";
module_param_string(mali_prefix, mali_prefix, sizeof(mali_prefix), 0444);
MODULE_PARM_DESC(mali_prefix,
		 "Module name prefix whose find_get_pid() calls are redirected (default mali_kbase)");

/*
 * Backend selection.
 *   auto   (default) ftrace if it can be armed, otherwise kprobe
 *   ftrace fail to load if ftrace is unavailable
 *   kprobe kprobe only
 */
static char nshf_backend[16] = "auto";
module_param_string(nshf_backend, nshf_backend, sizeof(nshf_backend), 0444);
MODULE_PARM_DESC(nshf_backend, "auto (default) | ftrace | kprobe");

/* Which backend actually ended up armed: 0 = none, 1 = ftrace, 2 = kprobe. */
static int nshf_active = 0;
module_param(nshf_active, int, 0444);
MODULE_PARM_DESC(nshf_active, "armed backend: 0 none, 1 ftrace, 2 kprobe");

/*
 * Interception counters, readable without unloading:
 *   cat /sys/module/mali_nsfix/parameters/nshf_seen
 *
 * nshf_seen counts every intercepted find_get_pid() call anywhere in the
 * kernel; nshf_hits counts the ones redirected. seen/hits divided by uptime
 * gives the exact interception rate - the number that decides whether the
 * per-call cost matters at all.
 */
static unsigned long nshf_seen;
static unsigned long nshf_hits;
module_param(nshf_seen, ulong, 0444);
MODULE_PARM_DESC(nshf_seen, "intercepted find_get_pid() calls since load");
module_param(nshf_hits, ulong, 0444);
MODULE_PARM_DESC(nshf_hits, "calls redirected to the group leader");

/*
 * Replacement reached only through a redirect, so it never has to call the
 * original.
 *
 * get_task_pid(leader, PIDTYPE_PID) returns the leader with a reference held;
 * the driver's put_pid() drops it. Return type and ABI match find_get_pid()
 * exactly, so the caller cannot tell the difference and KCFI stays happy.
 */
static struct pid *__nocfi nshf_get_pid(pid_t nr)
{
	(void)nr;
	return get_task_pid(current->group_leader, PIDTYPE_PID);
}

/*
 * The module that owns the probed call sites, resolved once.
 *
 * Walking the whole module list and running a strncmp per entry on every
 * find_get_pid() call is what the first version did. This device has 632
 * modules loaded and mali_kbase sits at position 230, so a single pass cost
 * ~230 strncmp calls on a function that runs system-wide. Resolving once turns
 * the steady-state test into a couple of address comparisons.
 *
 * try_module_get() pins the module so the pointer cannot go stale; the
 * reference is dropped in nshf_exit(). mali_kbase may be loaded after this
 * module, so resolution is also attempted lazily until it succeeds.
 */
static struct module *nshf_mali_mod;

static struct module *nshf_resolve_mali(void)
{
	struct module *mod, *found = NULL;
	size_t plen = strlen(mali_prefix);

	rcu_read_lock();
	list_for_each_entry_rcu(mod, &THIS_MODULE->list, list) {
		if (strncmp(mod->name, mali_prefix, plen))
			continue;
		if (try_module_get(mod))
			found = mod;
		break;
	}
	rcu_read_unlock();

	return found;
}

static bool nshf_caller_is_mali(unsigned long addr)
{
	if (unlikely(!nshf_mali_mod)) {
		nshf_mali_mod = nshf_resolve_mali();
		if (!nshf_mali_mod)
			return false;   /* not loaded (yet); nothing to redirect */
		pr_info("mali_nsfix: bound to %s at %px\n",
			nshf_mali_mod->name, nshf_mali_mod);
	}

	return within_module(addr, nshf_mali_mod);
}

/*
 * arm64 passes the caller's return address in x30 (regs->regs[30]) at the very
 * first instruction of a function, which is where both probes sit.
 */
#if defined(CONFIG_ARM64)
#define NSHF_CALLER_PC(regs) ((regs)->regs[30])
#elif defined(CONFIG_X86_64)
#define NSHF_CALLER_PC(regs) ((regs)->ip)
#else
#error "mali_nsfix: unsupported architecture"
#endif

/* ======================================================================== */
/* ftrace backend                                                           */
/* ======================================================================== */

/*
 * Budget:
 *   FTRACE_OPS_FL_SAVE_REGS  makes regs available (needed to read x30 and to
 *                            write pc back)
 *   FTRACE_OPS_FL_IPMODIFY   permits changing regs->pc. This is how livepatch
 *                            redirects a function entry; without it the kernel
 *                            rejects the modification.
 *
 * The handler must be notrace: it runs from the tracing trampoline and must
 * not itself be traced.
 *
 * ftrace_regs and ftrace_get_regs() exist from 6.1 on arm64. Older kernels use
 * a plain struct pt_regs argument; instead of maintaining both shapes, ftrace
 * is compiled out there and kprobe is used.
 */
#if defined(CONFIG_DYNAMIC_FTRACE_WITH_REGS) && \
	LINUX_VERSION_CODE >= KERNEL_VERSION(6, 1, 0)
#define NSHF_HAVE_FTRACE 1
#include <linux/ftrace.h>

static void notrace nshf_ftrace_thunk(unsigned long ip, unsigned long parent_ip,
				      struct ftrace_ops *ops,
				      struct ftrace_regs *fregs)
{
	struct pt_regs *regs;
	unsigned long caller;

	(void)ip;
	(void)parent_ip;
	(void)ops;

	/*
	 * ftrace_get_regs() returns NULL unless the ops were registered with
	 * FTRACE_OPS_FL_SAVE_REGS. It is set, so this is a sanity check only.
	 */
	regs = ftrace_get_regs(fregs);
	if (unlikely(!regs))
		return;

	caller = NSHF_CALLER_PC(regs);
	nshf_seen++;

	if (!nshf_caller_is_mali(caller))
		return;                 /* run the original function */

	nshf_hits++;
	regs->pc = (unsigned long)nshf_get_pid;
}

static struct ftrace_ops nshf_ops = {
	.func  = nshf_ftrace_thunk,
	.flags = FTRACE_OPS_FL_SAVE_REGS | FTRACE_OPS_FL_IPMODIFY,
};

static int nshf_arm_ftrace(void)
{
	char buf[32];
	int ret;

	/*
	 * Name-based filter: avoids kallsyms_lookup_name(), which stopped being
	 * exported in 5.7. ftrace_set_filter() resolves the name internally and
	 * returns -ENODEV when no instrumented function matches - which is also
	 * our detection for "find_get_pid was built without -pg".
	 */
	strscpy(buf, "find_get_pid", sizeof(buf));

	ret = ftrace_set_filter(&nshf_ops, buf, strlen(buf), 0);
	if (ret) {
		pr_info("mali_nsfix: ftrace_set_filter(find_get_pid) = %d\n", ret);
		return ret;
	}

	ret = register_ftrace_function(&nshf_ops);
	if (ret) {
		pr_info("mali_nsfix: register_ftrace_function = %d\n", ret);
		/* Leave no half-armed filter behind for the kprobe fallback. */
		ftrace_set_filter(&nshf_ops, buf, strlen(buf), 1);
		return ret;
	}

	return 0;
}

static void nshf_disarm_ftrace(void)
{
	char buf[32];

	strscpy(buf, "find_get_pid", sizeof(buf));
	unregister_ftrace_function(&nshf_ops);
	ftrace_set_filter(&nshf_ops, buf, strlen(buf), 1);
}
#else
#define nshf_arm_ftrace()	(-EOPNOTSUPP)
#define nshf_disarm_ftrace()	do { } while (0)
#endif /* CONFIG_DYNAMIC_FTRACE_WITH_REGS */

/* ======================================================================== */
/* kprobe backend                                                           */
/* ======================================================================== */

static struct kprobe nshf_kp;

static int nshf_pre_handler(struct kprobe *p, struct pt_regs *regs)
{
	unsigned long caller = NSHF_CALLER_PC(regs);

	(void)p;
	nshf_seen++;

	if (!nshf_caller_is_mali(caller))
		return 0;                /* execute the original instruction */

	nshf_hits++;

	/* Return 1: we have taken over, do not single-step the original. */
	regs->pc = (unsigned long)nshf_get_pid;
	return 1;
}

static int nshf_arm_kprobe(void)
{
	int ret;

	nshf_kp.symbol_name = "find_get_pid";
	nshf_kp.pre_handler = nshf_pre_handler;

	ret = register_kprobe(&nshf_kp);
	if (ret)
		pr_info("mali_nsfix: register_kprobe(find_get_pid) = %d\n", ret);
	return ret;
}

static void nshf_disarm_kprobe(void)
{
	unregister_kprobe(&nshf_kp);
}

/* ======================================================================== */
/* init / exit                                                              */
/* ======================================================================== */

static int __init nshf_init(void)
{
	int ret = -EINVAL;

	if (!strlen(mali_prefix))
		return -EINVAL;

	if (!strcmp(nshf_backend, "ftrace")) {
		ret = nshf_arm_ftrace();
		if (ret)
			return ret;
		nshf_active = 1;
	} else if (!strcmp(nshf_backend, "kprobe")) {
		ret = nshf_arm_kprobe();
		if (ret)
			return ret;
		nshf_active = 2;
	} else if (!strcmp(nshf_backend, "auto")) {
		ret = nshf_arm_ftrace();
		if (!ret) {
			nshf_active = 1;
		} else {
			pr_info("mali_nsfix: ftrace unavailable (%d), using kprobe\n",
				ret);
			ret = nshf_arm_kprobe();
			if (ret)
				return ret;
			nshf_active = 2;
		}
	} else {
		pr_err("mali_nsfix: unknown backend '%s'\n", nshf_backend);
		return -EINVAL;
	}

	/* Resolve eagerly when the driver is already loaded (the usual case on a
	 * booted device); the handler falls back to lazy resolution otherwise. */
	nshf_mali_mod = nshf_resolve_mali();

	pr_info("mali_nsfix: backend=%s redirecting callers in '%s*'%s\n",
		nshf_active == 1 ? "ftrace" : "kprobe", mali_prefix,
		nshf_mali_mod ? " (driver already loaded)" : " (driver not loaded yet)");
	return 0;
}

static void __exit nshf_exit(void)
{
	if (nshf_active == 1)
		nshf_disarm_ftrace();
	else if (nshf_active == 2)
		nshf_disarm_kprobe();

	if (nshf_mali_mod) {
		module_put(nshf_mali_mod);
		nshf_mali_mod = NULL;
	}

	pr_info("mali_nsfix: removed (backend=%s, intercepted %lu time(s), redirected %lu)\n",
		nshf_active == 1 ? "ftrace" : (nshf_active == 2 ? "kprobe" : "none"),
		nshf_seen, nshf_hits);
}

module_init(nshf_init);
module_exit(nshf_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("misaka5202");
MODULE_DESCRIPTION("Redirect find_get_pid() calls made by the Mali kbase driver so GPU contexts work inside a PID namespace");
MODULE_VERSION("0.2.0");