#!/bin/sh

# fancyss script for asuswrt/merlin based router with software center
#
# FORK doge.14.x (D43): DNS 重试前端 + 卫星 dnsmasq 自愈 watchdog（cron 每分钟）。
#
# 背景（详见 doc/implementation/split-routing-implementation.md D43 / CLAUDE.md #37）：
# DNS 重定向的"重试前端"(65356/65357) 与卫星 dnsmasq(65355) 都是 fancyss 自己起的独立
# dnsmasq 实例，不在固件管理范围内。固件 out-of-band 的 `service restart_dnsmasq`
# （DHCP/WAN 续约、某些固件按钮等）会 `killall dnsmasq` 把它们一并杀掉，而固件只会把
# 主 dnsmasq(53) 重新拉起 → 这几个实例不自愈、不到下次 apply_ss 不恢复。DNS 重定向开启
# 时，被 DNAT 到这些端口的设备 DNS 会全断。
#
# 本 watchdog 周期性确认它们在监听，缺失即调 ssconfig.sh heal_dns_fronts 幂等重起
# （heal 内各 start 函数先 netstat 再 spawn，端口已在则跳过；不重启 chinadns、不碰主
# dnsmasq、无递归）。健康时只做几次 netstat 检查即退出，开销极小。

# cron 的 PATH 很小、不含 /koolshare/bin（dbus 在那），必须显式设置，否则 dbus/netstat
# 找不到 → 判定为"未启用"静默退出 → 永不自愈。
export PATH=/koolshare/bin:/koolshare/sbin:/usr/sbin:/usr/bin:/sbin:/bin

# 插件未启用：前端/卫星都无意义，直接退出
[ "$(dbus get ss_basic_enable 2>/dev/null)" = "1" ] || exit 0

# 卫星 dnsmasq(65355) 只要插件在跑就需要（chinadns group lan/custom/node 的上游）。
# 重试前端(65356/65357) 只有 DNS 重定向开启时才需要（否则设备走主 dnsmasq，无需前端）。
PORTS="65355"
[ "$(dbus get ss_basic_dns_hijack 2>/dev/null)" = "1" ] && PORTS="${PORTS} 65356 65357"

need=0
for p in ${PORTS}; do
	netstat -lnup 2>/dev/null | grep -q ":${p}\b" || need=1
done
[ "${need}" = "0" ] && exit 0

# 有缺失 → 幂等重起（heal 输出进启动日志，便于事后排查"DNS 怎么自己好了/为什么修复"）
/koolshare/ss/ssconfig.sh heal_dns_fronts >> /tmp/upload/ss_log.txt 2>&1
