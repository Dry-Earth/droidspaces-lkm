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
 *     if (pid_struct) {
 *         task = pid_task(pid_struct, PIDTYPE_PID);
 *         if (task) { get_task_struct(task); kctx->task = task; }
 *         else     { err = -ESRCH; }
 *         put_pid(pid_struct);
 *     } else {
 *         dev_err(dev, "Failed to get pid pointer for %s/%d", ...);
 *         err = -ESRCH;
 *     }
 *     ...
 *     if (err) return err;
 *
 * task_struct->tgid is always the value in the initial PID namespace, while
 * find_get_pid() -> find_vpid() searches the caller's active namespace. For a
 * process inside a container the two disagree, the lookup fails, and GPU
 * context creation is refused with -ESRCH. Android's own processes are not
 * affected because for them the two values are the same task.
 *
 * The vendor's own fix replaces the lookup with current->group_leader. This
 * module achieves the same result without touching the driver binary: it
 * probes find_get_pid() and, when the caller is inside a kbase module, hands
 * back a reference to the caller's own group leader. pid_task() on that pid
 * returns exactly the task the driver wanted, and the driver's put_pid()
 * balances the reference taken here.
 *
 * Because the redirected result equals what a host process would have got,
 * redirecting unconditionally for kbase callers is a no-op for Android and
 * the fix for containers - no namespace test is needed.
 *
 * Why a kprobe and not a rebuilt mali_kbase.ko
 * -------------------------------------------
 * Rebuilding the vendor driver needs its source, matching symbol CRCs against
 * the running kernel and replacing the module in vendor_dlkm (or rmmod-ing a
 * driver Android is actively using, which panics on the next GPU fence).
 * A kprobe needs none of that and survives an OTA.
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

#ifndef __nocfi
#define __nocfi
#endif

#define NSHF_NAME_MAX 64

/* Prefix matched against the name of the module that called find_get_pid(). */
static char mali_prefix[NSHF_NAME_MAX] = "mali_kbase";
module_param_string(mali_prefix, mali_prefix, sizeof(mali_prefix), 0444);
MODULE_PARM_DESC(mali_prefix,
                 "Module name prefix whose find_get_pid() calls are redirected (default mali_kbase)");

static struct kprobe nshf_kp;
static unsigned long nshf_hits;      /* redirects performed */
static unsigned long nshf_seen;      /* handler invocations */
static unsigned long nshf_last_caller;

/*
 * Replacement reached only through the redirect below, so it never has to
 * call the original.
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
 * Is @addr inside a module whose name starts with the configured prefix?
 *
 * within_module() is a static inline over mod->core_layout (or the per-section
 * memory array on newer kernels), so this needs no symbol lookups and adapts
 * to the target kernel's struct module layout at compile time.
 *
 * The RCU walk is safe in a kprobe pre_handler: no sleeping, and the module
 * list is only mutated under module_mutex which we never take here.
 */
/*
 * The module that owns the probed call sites, resolved once.
 *
 * The first version of this walked the whole module list on every
 * find_get_pid() call and ran a strncmp per entry. This device has 632 modules
 * loaded and mali_kbase sits at position 230, so a single pass cost ~230
 * strncmp calls - on a hot function that runs system-wide, inside a kprobe
 * handler with interrupts off. That dominated whatever the breakpoint itself
 * cost.
 *
 * Resolving once turns the steady-state test into two address comparisons.
 * try_module_get() pins the module so the pointer cannot go stale under us;
 * the reference is dropped in nshf_exit().
 *
 * mali_kbase may be loaded after this module, so resolution is also attempted
 * lazily from the handler until it succeeds. Once found it is never looked up
 * again.
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
 * first instruction of a function, which is where the probe sits.
 */
#if defined(CONFIG_ARM64)
#define NSHF_CALLER_PC(regs) ((regs)->regs[30])
#elif defined(CONFIG_X86_64)
#define NSHF_CALLER_PC(regs) ((regs)->ip)
#else
#error "mali_nsfix: unsupported architecture"
#endif

static int nshf_pre_handler(struct kprobe *p, struct pt_regs *regs)
{
	unsigned long caller = NSHF_CALLER_PC(regs);

	(void)p;
	nshf_seen++;

	if (!nshf_caller_is_mali(caller))
		return 0;                /* execute the original instruction */

	nshf_last_caller = caller;
	nshf_hits++;

	/* Return 1: we have taken over, do not single-step the original. */
	regs->pc = (unsigned long)nshf_get_pid;
	return 1;
}

static int __init nshf_init(void)
{
	int ret;

	if (!strlen(mali_prefix))
		return -EINVAL;

	nshf_kp.symbol_name = "find_get_pid";
	nshf_kp.pre_handler = nshf_pre_handler;

	ret = register_kprobe(&nshf_kp);
	if (ret) {
		pr_err("mali_nsfix: register_kprobe(find_get_pid) failed: %d\n", ret);
		return ret;
	}

	/* Resolve eagerly when the driver is already loaded (the usual case on a
	 * booted device); the handler falls back to lazy resolution otherwise. */
	nshf_mali_mod = nshf_resolve_mali();

	pr_info("mali_nsfix: probing find_get_pid at %px, redirecting callers in '%s*'%s\n",
		nshf_kp.addr, mali_prefix,
		nshf_mali_mod ? " (driver already loaded)" : " (driver not loaded yet)");
	return 0;
}

static void __exit nshf_exit(void)
{
	unregister_kprobe(&nshf_kp);
	if (nshf_mali_mod) {
		module_put(nshf_mali_mod);
		nshf_mali_mod = NULL;
	}
	pr_info("mali_nsfix: removed (handler ran %lu time(s), redirected %lu, %lu skipped before the driver appeared)\n",
		nshf_seen, nshf_hits, nshf_seen - nshf_hits);
}

module_init(nshf_init);
module_exit(nshf_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("misaka5202");
MODULE_DESCRIPTION("Redirect find_get_pid() calls made by the Mali kbase driver so GPU contexts work inside a PID namespace");
MODULE_VERSION("0.1.0");