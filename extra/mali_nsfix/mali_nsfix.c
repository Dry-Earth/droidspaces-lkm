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
 * Why kprobe and not ftrace
 * -------------------------
 * ftrace would be cheaper: find_get_pid() carries a call to __fentry__ at its
 * entry when CONFIG_FUNCTION_TRACER is on, and dynamic ftrace rewrites that
 * into a branch to the trampoline. With FTRACE_OPS_FL_IPMODIFY the handler may
 * rewrite regs->pc, which is how livepatch redirects a function - no
 * breakpoint, no exception, no single-step.
 *
 * But CONFIG_FUNCTION_TRACER is unset on this device and in the DDK build tree
 * (# CONFIG_FUNCTION_TRACER is not set in both /proc/config.gz and the tree's
 * .config). Without it there are no __fentry__ call sites to patch, so the
 * ftrace path would compile to nothing.
 *
 * Measured cost of the kprobe alternative on OPPO PHZ110 / MT6989 / 6.1.157:
 * find_get_pid() is intercepted about 5 times per minute system-wide, and
 * 44 of 1800 interceptions were Mali callers. At 1-3 us per trap that is
 * 0.000008%-0.000025% CPU - not worth chasing.
 *
 * Correctness depends on struct layout, and is checked
 * ---------------------------------------------------
 * within_module() is a static inline that reads struct module's core_layout
 * fields. The plugin is built against the DDK's headers, but the device kernel
 * is the vendor's build: any config or patch that changes struct module shifts
 * those offsets. CONFIG_MODULE_SCMVERSION=y is present on the test device and
 * is a vendor addition absent from the DDK tree.
 *
 * If the offsets are wrong, within_module() answers wrongly. A false negative
 * just leaves the redirect off (GPU context creation keeps failing - visible).
 * A false positive is worse: an unrelated find_get_pid(nr) gets redirected to
 * get_task_pid(current->group_leader), so a caller asking about some other pid
 * (waitid, kill, pidfd_open) receives the wrong task. That does not produce an
 * error message; it produces a wrong signal target or a wrong wait target.
 *
 * nshf_layout_ok() therefore validates the layout against the one thing we can
 * verify without symbol lookups: one of our own functions must be classified
 * as inside THIS_MODULE. If that fails, the probe is not installed and the
 * module refuses to load.
 *
 * Scope
 * -----
 * This only unblocks GPU context creation. Userspace still has to load the
 * vendor driver into the container (libhybris) and provide a render node.
 *
 * Dry run
 * -------
 * insmod mali_nsfix.ko nshf_activate=0 keeps the module resident but unarmed:
 * it validates struct module, register/unregister-probes find_get_pid to prove
 * the hook point exists, resolves mali_kbase if present, and exports the
 * outcome through nshf_active / nshf_probe_ok / nshf_layout_valid /
 * nshf_driver. Nothing is redirected, so it is safe to use as a first-install
 * preflight on an unverified device.
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
 * Interception counters, readable without unloading:
 *   cat /sys/module/mali_nsfix/parameters/nshf_seen
 *
 * They are plain unsigned long incremented from every CPU with no
 * serialisation, so concurrent hits can be lost. They are diagnostics, not
 * accounting: treat the values as a lower bound and the rate derived from them
 * as approximate.
 */
static unsigned long nshf_seen;
static unsigned long nshf_hits;
module_param(nshf_seen, ulong, 0444);
MODULE_PARM_DESC(nshf_seen, "intercepted find_get_pid() calls since load (approximate)");
module_param(nshf_hits, ulong, 0444);
MODULE_PARM_DESC(nshf_hits, "calls redirected to the group leader (approximate)");

/* Set once the layout self-check has passed. Never cleared. */
static bool nshf_layout_valid;
module_param(nshf_layout_valid, bool, 0444);
MODULE_PARM_DESC(nshf_layout_valid, "struct module layout self-check result");

/*
 * Dry-run control, borrowed from the activate= convention other Droidspaces
 * LKM targets use for their self-test builds.
 *
 * 1 (default): validate the layout, arm the kprobe, stay resident.
 * 0:          validate the layout, prove the probe point exists by
 *             register/unregister-ing it, resolve the driver, export all
 *             diagnostics -- and change nothing about kernel behaviour.
 *             The module stays loaded and removable, so a first install can
 *             answer "would this work here?" before committing to a hook.
 *
 * Read-only on purpose: flipping it after load would not disarm anything.
 */
static int nshf_activate = 1;
module_param(nshf_activate, int, 0444);
MODULE_PARM_DESC(nshf_activate,
		 "1 = arm the kprobe (default), 0 = validate only, stay unarmed");

/* 1 once the kprobe is actually installed; 0 in dry-run or after failure. */
static int nshf_active;
module_param(nshf_active, int, 0444);
MODULE_PARM_DESC(nshf_active, "1 = kprobe armed, 0 = not armed");

/* Result of the register/unregister probe; meaningful in both modes. */
static bool nshf_probe_ok;
module_param(nshf_probe_ok, bool, 0444);
MODULE_PARM_DESC(nshf_probe_ok, "kprobe registration on find_get_pid succeeded");

/*
 * Which module the redirect is bound to, for the doctor output. "(none)"
 * means mali_kbase was not present at load time (the handler still resolves
 * lazily on an armed module).
 */
static char nshf_driver[64] = "(none)";
module_param_string(nshf_driver, nshf_driver, sizeof(nshf_driver), 0444);
MODULE_PARM_DESC(nshf_driver, "module whose find_get_pid() calls are redirected");

/*
 * Replacement reached only through the redirect, so it never has to call the
 * original.
 *
 * get_task_pid(leader, PIDTYPE_PID) returns the leader with a reference held;
 * the driver's put_pid() drops it. Return type and ABI match find_get_pid()
 * exactly, so the caller cannot tell the difference and KCFI stays happy.
 *
 * nr is deliberately ignored: the only caller we redirect is kbase, which
 * passes its own current->tgid, and the group leader is the task that value
 * denotes. A redirected call that is NOT from kbase would therefore return the
 * wrong task - which is why the layout check below refuses to arm the probe
 * when classification cannot be trusted.
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
 *
 * The lazy path can run concurrently on several CPUs and each may take its own
 * try_module_get() reference, leaking all but the winner's. That is at most a
 * handful of references on a driver that never unloads in practice, so it is
 * accepted rather than serialised - the handler runs with interrupts off and
 * must not spin on a lock.
 */
static struct module *nshf_mali_mod;

/*
 * Lazy resolution attempts left.
 *
 * Without a cap, a device that never loads mali_kbase pays the full module-list
 * walk (632 entries plus a strncmp each on the test device) on EVERY
 * find_get_pid() call, inside a kprobe handler with interrupts off. That is
 * the exact cost the cached pointer was introduced to remove, just moved to
 * the "driver absent" case.
 *
 * After NSHF_RESOLVE_TRIES failures the handler stops looking and returns
 * "not mali" immediately.
 *
 * The number has to be large. service.sh loads this module at late_start, long
 * after vendor_dlkm, so nshf_init() normally resolves eagerly and the lazy path
 * never runs. It only matters when mali_kbase appears afterwards - and in that
 * case a small cap could be exhausted by early find_get_pid() traffic (from
 * init, healthd, the activity manager) before the driver shows up, permanently
 * disabling the redirect on a device that needed it.
 *
 * Measured rate on the test device is ~5 calls/min, so 4096 tries is more than
 * half a day of "driver still absent". The cost is bounded either way: each
 * failed try is one module-list walk, and it happens at most this many times
 * for the whole uptime.
 */
#define NSHF_RESOLVE_TRIES	4096
static int nshf_resolve_left = NSHF_RESOLVE_TRIES;
module_param(nshf_resolve_left, int, 0444);
MODULE_PARM_DESC(nshf_resolve_left,
		 "remaining lazy lookups for the kbase module (0 = gave up)");

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
		if (!nshf_resolve_left)
			return false;   /* gave up; see NSHF_RESOLVE_TRIES */
		if (--nshf_resolve_left == 0)
			pr_info("mali_nsfix: gave up looking for '%s*' after %d tries\n",
				mali_prefix, NSHF_RESOLVE_TRIES);
		nshf_mali_mod = nshf_resolve_mali();
		if (!nshf_mali_mod)
			return false;   /* not loaded (yet); nothing to redirect */
		pr_info("mali_nsfix: bound to %s at %px\n",
			nshf_mali_mod->name, nshf_mali_mod);
	}

	return within_module(addr, nshf_mali_mod);
}

/*
 * Is within_module() actually reading struct module correctly?
 *
 * The positive case is self-evident and needs no external symbol: our own
 * function lives in this module's text, so within_module() must report true
 * for it. A wrong core_layout offset makes that come back false.
 *
 * The negative case uses a second address that is also ours - a static data
 * object. It must land in the same module, which distinguishes "read the right
 * struct" from "read a struct that happens to look plausible".
 *
 * Deliberately no kernel-symbol address is used here: resolving one would pull
 * in kallsyms machinery and reintroduce exactly the portability problem this
 * check exists to guard against.
 */
static bool nshf_layout_ok(void)
{
	unsigned long size;

	if (!within_module((unsigned long)&nshf_layout_ok, THIS_MODULE))
		return false;
	if (!within_module((unsigned long)&nshf_layout_valid, THIS_MODULE))
		return false;

	/*
	 * Third check: the core text size must be a plausible allocation. Both
	 * functions above living "inside" a module whose recorded size is 0 or
	 * 4 GB means the offset is pointing at something that merely happens to
	 * bracket our addresses by luck.
	 *
	 * The field moved in 6.4: struct module_layout { core_layout,
	 * init_layout, ... } became struct module_memory mem[] indexed by
	 * enum mod_mem_type (commit "module: replace module_layout with
	 * module_memory"). MOD_TEXT is the core text slot in the new layout.
	 */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 4, 0)
	size = THIS_MODULE->mem[MOD_TEXT].size;
#else
	size = THIS_MODULE->core_layout.size;
#endif
	if (size < 4096 || size > (64UL << 20))
		return false;

	return true;
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
		pr_err("mali_nsfix: register_kprobe(find_get_pid) = %d\n", ret);
	return ret;
}

static void nshf_disarm_kprobe(void)
{
	unregister_kprobe(&nshf_kp);
}

static int __init nshf_init(void)
{
	int ret;

	if (!strlen(mali_prefix))
		return -EINVAL;

	/*
	 * Validate struct module before arming anything. Without this, a
	 * mismatched layout turns into misattributed callers, and a redirected
	 * non-kbase call returns the wrong task to its caller.
	 */
	if (!nshf_layout_ok()) {
		pr_err("mali_nsfix: struct module layout check failed; "
		       "refusing to arm (within_module() cannot be trusted)\n");
		return -EINVAL;
	}
	nshf_layout_valid = true;

	if (nshf_activate) {
		ret = nshf_arm_kprobe();
		if (ret)
			return ret;
		nshf_active = 1;
		nshf_probe_ok = true;
	} else {
		/*
		 * Dry run. Registering proves the probe point exists on this
		 * kernel (it fails with -ENODEV when CONFIG_KPROBES is off or
		 * find_get_pid is not a kallsyms-resolvable name); unregistering
		 * immediately leaves no trace. Nothing is redirected.
		 */
		ret = nshf_arm_kprobe();
		if (ret) {
			pr_warn("mali_nsfix: dry-run: register_kprobe"
				"(find_get_pid) = %d\n", ret);
		} else {
			nshf_disarm_kprobe();
			nshf_probe_ok = true;
			pr_info("mali_nsfix: dry-run: find_get_pid probe "
				"registered and released\n");
		}
	}

	/* Resolve eagerly when the driver is already loaded (the usual case on a
	 * booted device); an armed handler falls back to lazy resolution. */
	nshf_mali_mod = nshf_resolve_mali();
	if (nshf_mali_mod)
		scnprintf(nshf_driver, sizeof(nshf_driver), "%s",
			  nshf_mali_mod->name);

	pr_info("mali_nsfix: %s; redirecting callers in '%s*', layout verified%s\n",
		nshf_active ? "kprobe armed" : "dry-run (not armed)",
		mali_prefix,
		nshf_mali_mod ? " (driver already loaded)" : " (driver not loaded yet)");
	return 0;
}

static void __exit nshf_exit(void)
{
	if (nshf_active)
		nshf_disarm_kprobe();

	if (nshf_mali_mod) {
		module_put(nshf_mali_mod);
		nshf_mali_mod = NULL;
	}

	pr_info("mali_nsfix: removed (intercepted %lu time(s), redirected %lu)\n",
		nshf_seen, nshf_hits);
}

module_init(nshf_init);
module_exit(nshf_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("misaka5202");
MODULE_DESCRIPTION("Redirect find_get_pid() calls made by the Mali kbase driver so GPU contexts work inside a PID namespace");
MODULE_VERSION("0.4.0");