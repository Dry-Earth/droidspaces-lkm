#!/usr/bin/env python3
"""
在 build_modules.sh 里给 macvlan.c 加一步源码改写，去掉三个在部分厂商内核上
不导出的符号依赖。

依据（linux v6.1 drivers/net/macvlan.c）：

  L1173  .ndo_fdb_dump = ndo_dflt_fdb_dump,
         → 删掉这一行。rtnl_fdb_dump() 在 ops->ndo_fdb_dump 为 NULL 时本来就会
           回退到 ndo_dflt_fdb_dump，行为完全等价，但不再产生静态导入。

  L413   ret = __netif_rx(nskb);
  L473   __netif_rx(skb);
         → 换成 netif_rx()。签名一致（struct sk_buff * → int），语义上是同一条
           收包路径的不同入口；netif_rx 是所有内核都导出的那个名字。

  L458   skb = ip_check_defrag(dev_net(skb->dev), skb, IP_DEFRAG_MACVLAN);
         → 换成恒等内联，跳过分片重组。这是唯一有语义损失的替换：macvlan 的
           source 模式下不再重组 IP 分片。分片流量在容器场景里少见，而代价是
           整个模块在部分厂商内核上装不上 —— 取舍偏向保留模块可用。

  第二组（针对只导出部分 net 符号的厂商内核，如 Qualcomm SM7675 6.1.138）：

    L234   return __dev_forward_skb(dev, skb);
           → dev_forward_skb(dev, skb)。导出的那个就是 __dev_forward_skb 再加
             一层 rx 计数包装，参数和返回值完全一致，无语义差异。

    L1014  err = dev_uc_add_excl(dev, addr);
    L1016  err = dev_mc_add_excl(dev, addr);
           → dev_uc_add() / dev_mc_add()。唯一差别是 _excl 在地址已存在时返回
             -EEXIST，非 excl 版返回 0。这条路径是 rtnl_fdb_add()，即
             "ip link set ... fdb ..."；重复添加同一个 FDB 条目本来就没坏处，
             改成幂等反而更宽容。真机可观察到的差异：重复 fdb add 不再报
             "File exists"。

替换统一走字符串匹配，不依赖行号，因为 7 个 KMI 的内核树版本不同。
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from i18n import t  # noqa: E402

p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8", errors="surrogateescape")
orig = s
done = []

# ---- 1. 删掉 ndo_fdb_dump 的赋值 ----
lines = s.split("\n")
out = []
removed = 0
for ln in lines:
    if "ndo_fdb_dump" in ln and "ndo_dflt_fdb_dump" in ln and "=" in ln:
        removed += 1
        continue
    out.append(ln)
if removed:
    s = "\n".join(out)
    done.append(f"删除 .ndo_fdb_dump 赋值 {removed} 处")

# ---- 2. __netif_rx → netif_rx ----
if "__netif_rx(" in s:
    n = s.count("__netif_rx(")
    s = s.replace("__netif_rx(", "netif_rx(")
    done.append(f"__netif_rx → netif_rx {n} 处")

# ---- 3. ip_check_defrag → 恒等内联 ----
if "ip_check_defrag(" in s and "macvlan_skip_defrag" not in s:
    n = s.count("ip_check_defrag(")
    s = s.replace("ip_check_defrag(", "macvlan_skip_defrag(")
    # 在第一个 #include 之后插入恒等内联
    marker = s.find("\n", s.find("#include"))
    helper = """
/*
 * [TRIM] ip_check_defrag 在部分厂商内核上没有 EXPORT_SYMBOL，静态链接会让
 * 整个 macvlan 装不上。这里退化成不做分片重组：skb 原样返回。
 */
static inline struct sk_buff *macvlan_skip_defrag(struct net *net,
						  struct sk_buff *skb,
						  unsigned int user)
{
	return skb;
}
"""
    # 找到最后一条 #include，插在其后
    last = 0
    pos = 0
    while True:
        pos = s.find("#include", pos)
        if pos < 0:
            break
        last = pos
        pos += 1
    eol = s.find("\n", last)
    s = s[:eol + 1] + helper + s[eol + 1:]
    done.append(f"ip_check_defrag → 恒等内联 {n} 处")

# ---- 4. __dev_forward_skb -> dev_forward_skb（导出包装，语义等价）----
if "__dev_forward_skb(" in s:
    n = s.count("__dev_forward_skb(")
    s = s.replace("__dev_forward_skb(", "dev_forward_skb(")
    done.append(f"__dev_forward_skb -> dev_forward_skb {n} 处")

# ---- 5. dev_uc_add_excl / dev_mc_add_excl -> dev_uc_add / dev_mc_add ----
# 只影响 rtnl_fdb_add()：重复添加同一条 FDB 由 -EEXIST 变成幂等成功
for old_name, new_name in (("dev_uc_add_excl(", "dev_uc_add("),
                           ("dev_mc_add_excl(", "dev_mc_add(")):
    if old_name in s:
        n = s.count(old_name)
        s = s.replace(old_name, new_name)
        done.append(f"{old_name[:-1]} -> {new_name[:-1]} {n} 处")

# ---------------------------------------------------------------------------
# 6. 注入同名转发函数（只处理「A 换 B 也不可靠」的三个）
#
# issue #3（K90PM）/ #4（一加15）是 6.12.23-android16-5，这三台内核把
# __dev_forward_skb 和 dev_forward_skb **都**裁掉了，所以第 4 步的
# 「__dev_forward_skb → dev_forward_skb」在这类内核上等于没修。
#
# eth_header_cache / eth_header_cache_update 又是**取地址**用的
# （.cache = eth_header_cache），#define 成 (*ptr) 不是编译期常量。
#
# 统一改成同名转发函数：
#   * 模块内所有引用（调用 / 取地址）都链到这里，不产生静态导入
#   * 函数体在运行时解析的指针上做二次兜底
#   * 解析不到时：int 返回 -EINVAL、void 直接返回，调用点能安全退化
# ---------------------------------------------------------------------------
if "MACVLAN_SYMRES" not in s:
    shim = r"""
/* ---- MACVLAN_SYMRES begin ---------------------------------------------
 *
 * 部分厂商内核把下列 net 辅助函数裁掉了 EXPORT_SYMBOL（函数本体仍在
 * kallsyms 里）。静态链接会让整个 macvlan 装不上：
 *
 *   Qualcomm SM7675 / 6.1.138   __dev_forward_skb dev_mc_add_excl dev_uc_add_excl
 *   Meizu 6.1.25                同上 + eth_header_cache* 之外的一批
 *   6.12.23-android16-5         上一批 + dev_forward_skb eth_header_cache
 *                               eth_header_cache_update（issue #3 / #4）
 *
 * 这三个用**同名转发函数**而不是 #define：
 *   - eth_header_cache / eth_header_cache_update 在 struct header_ops 初始化里
 *     被取地址，(*ptr) 不是编译期常量；
 *   - dev_forward_skb 在 macvlan_broadcast() 里是普通调用，但第 4 步的替换
 *     会把 macvlan_forward_source_one() 也压到它上面，必须两种用法都支持。
 *
 * 模块内所有引用都链到这里，不产生静态导入；函数体转发到运行时解析的地址。
 * 解析机制同 zram-lkm 的 extra/compat/zram_symres.h：kprobe 拿
 * kallsyms_lookup_name，再查具体符号。
 */
#include <linux/kprobes.h>
#include <linux/etherdevice.h>
#include <linux/netdevice.h>

#ifndef __nocfi
#define __nocfi
#endif

static int  (*mv_p_dev_forward_skb)(struct net_device *, struct sk_buff *);
static int  (*mv_p___dev_forward_skb)(struct net_device *, struct sk_buff *);
static int  (*mv_p_eth_header_cache)(const struct neighbour *, struct hh_cache *,
				     __be16);
static void (*mv_p_eth_header_cache_update)(struct hh_cache *,
					    const struct net_device *,
					    const unsigned char *);
static int  (*mv_p_dev_mc_add)(struct net_device *, const unsigned char *);
static int  (*mv_p_dev_mc_del)(struct net_device *, const unsigned char *);
static bool (*mv_p_netdev_is_rx_handler_busy)(struct net_device *);

static unsigned long mv_lookup(const char *name)
{
	static unsigned long (*kln)(const char *);
	struct kprobe kp;
	unsigned long addr;

	if (!kln) {
		memset(&kp, 0, sizeof(kp));
		kp.symbol_name = "kallsyms_lookup_name";
		if (!register_kprobe(&kp)) {
			kln = (void *)kp.addr;
			unregister_kprobe(&kp);
		}
	}
	if (kln)
		return kln(name);

	memset(&kp, 0, sizeof(kp));
	kp.symbol_name = name;
	if (register_kprobe(&kp))
		return 0;
	addr = (unsigned long)kp.addr;
	unregister_kprobe(&kp);
	return addr;
}

static void mv_resolve_syms(void)
{
	mv_p_dev_forward_skb     = (void *)mv_lookup("dev_forward_skb");
	mv_p___dev_forward_skb   = (void *)mv_lookup("__dev_forward_skb");
	mv_p_eth_header_cache    = (void *)mv_lookup("eth_header_cache");
	mv_p_eth_header_cache_update =
		(void *)mv_lookup("eth_header_cache_update");
	mv_p_dev_mc_add           = (void *)mv_lookup("dev_mc_add");
	mv_p_dev_mc_del           = (void *)mv_lookup("dev_mc_del");
	mv_p_netdev_is_rx_handler_busy =
		(void *)mv_lookup("netdev_is_rx_handler_busy");
}

/*
 * dev_forward_skb - 同名转发。
 * 优先 dev_forward_skb（导出的那个，自带 rx 计数）；没有就退到
 * __dev_forward_skb（语义等价，少一层计数）。
 */
int __nocfi dev_forward_skb(struct net_device *dev, struct sk_buff *skb)
{
	if (mv_p_dev_forward_skb)
		return mv_p_dev_forward_skb(dev, skb);
	if (mv_p___dev_forward_skb)
		return mv_p___dev_forward_skb(dev, skb);
	kfree_skb(skb);
	return -EINVAL;
}

/* eth_header_cache - 同名转发（被 .cache = eth_header_cache 取地址）。 */
int __nocfi eth_header_cache(const struct neighbour *neigh, struct hh_cache *hh,
			     __be16 type)
{
	if (!mv_p_eth_header_cache)
		return -EINVAL;
	return mv_p_eth_header_cache(neigh, hh, type);
}

/* eth_header_cache_update - 同名转发（同上，被 .cache_update 取地址）。 */
void __nocfi eth_header_cache_update(struct hh_cache *hh,
				     const struct net_device *dev,
				     const unsigned char *haddr)
{
	if (mv_p_eth_header_cache_update)
		mv_p_eth_header_cache_update(hh, dev, haddr);
}

/*
 * dev_mc_add / dev_mc_del —— 6.1.25 的 Meizu 内核连这两个都没导出
 * （issue #2 的 boot.img 导出表实测），所以第 5 步的
 * "dev_mc_add_excl -> dev_mc_add" 替换在它上面等于没修。
 * 这里补同名转发，让替换后的调用点落到运行时解析上。
 */
int __nocfi dev_mc_add(struct net_device *dev, const unsigned char *addr)
{
	if (!mv_p_dev_mc_add)
		return -EINVAL;
	return mv_p_dev_mc_add(dev, addr);
}

int __nocfi dev_mc_del(struct net_device *dev, const unsigned char *addr)
{
	if (!mv_p_dev_mc_del)
		return -EINVAL;
	return mv_p_dev_mc_del(dev, addr);
}

/*
 * netdev_is_rx_handler_busy —— macvlan 注册 rx_handler 前的检查。
 * 没导出，同样走运行时解析。查不到时返回 false（视为不忙），
 * 让注册流程继续 —— 最坏情况是 register_netdevice 自己拒绝。
 */
bool __nocfi netdev_is_rx_handler_busy(struct net_device *dev)
{
	if (!mv_p_netdev_is_rx_handler_busy)
		return false;
	return mv_p_netdev_is_rx_handler_busy(dev);
}

/* ---- MACVLAN_SYMRES end ----------------------------------------------- */
"""
    # 插在最后一个 #include 之后（与第 2 步的 helper 不冲突：那个用 inline）
    last = 0
    pos = 0
    while True:
        pos = s.find("#include", pos)
        if pos < 0:
            break
        last = pos
        pos += 1
    eol = s.find("\n", last)
    if eol < 0:
        eol = len(s)
    s = s[:eol + 1] + shim + s[eol + 1:]
    done.append("注入 MACVLAN_SYMRES 同名转发 shim（6 个符号）")

    # 在 module_init 里调用解析
    import re as _re
    m = _re.search(r"static int __init macvlan_init_module\(void\)\s*\{", s)
    if m and "mv_resolve_syms();" not in s:
        # 插在函数体内第一条语句之前，但要跳过变量声明。
        #
        # 直接插在 { 之后会触发 -Wdeclaration-after-statement，
        # 在 5.10 / 5.15 上是硬错误（CI #78 就是这么挂的）：
        #   error: mixing declarations and code is a C99 extension
        #   [-Werror,-Wdeclaration-after-statement]
        brace = s.find("{", m.start())
        j = brace + 1
        while True:
            eol = s.find("\n", j)
            if eol < 0:
                break
            st = s[j:eol].strip()
            if not st:
                j = eol + 1
                continue
            _DECL = ("int ", "unsigned ", "struct ", "long ", "void *",
                     "u8 ", "u16 ", "u32 ", "u64 ", "bool ", "char *",
                     "const ")
            if st.endswith(";") and "(" not in st and st.startswith(_DECL):
                j = eol + 1
                continue
            break
        s = s[:j] + "\tmv_resolve_syms();\n" + s[j:]
        done.append("module_init 里调用 mv_resolve_syms()（跳过变量声明）")
    elif not m:
        done.append("⚠ 找不到 macvlan_init_module")

if s != orig:
    p.write_text(s, encoding="utf-8", errors="surrogateescape")

print(t("macvlan_rewrites"))
for d in done:
    print("    -", d)
if not done:
    print(t("macvlan_no_change"))