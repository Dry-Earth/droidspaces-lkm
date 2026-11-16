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

替换统一走字符串匹配，不依赖行号，因为 7 个 KMI 的内核树版本不同。
"""
import sys
from pathlib import Path

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

if s != orig:
    p.write_text(s, encoding="utf-8", errors="surrogateescape")

print("  macvlan.c 改写：")
for d in done:
    print("    -", d)
if not done:
    print("    (无改动，可能已经改过)")