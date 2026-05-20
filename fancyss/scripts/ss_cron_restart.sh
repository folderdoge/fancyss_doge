#!/bin/sh

# fancyss fork doge.12 alpha.17 — cron/legacy 触发的 restart wrapper
#
# 背景：ssconfig.sh::case restart/start 的入口处会看 fss_failover_internal_restart 标志
# 决定是否清空 failover 备用组合的 failed 状态：
#   • flag = "1"  → 故障转移自己切换（保留 failed）
#   • flag = "2"  → cron / wan-start / legacy 内部触发（保留 failed，本 wrapper 设置）
#   • flag 其他   → 视为用户主动操作 → 清 failed + 解除冷却
#
# 任何非用户路径的 restart（cru 定时重启 / 规则更新后重启 / 备用 s4_1=1 重启 …）
# 必须先打标志位再 exec ssconfig.sh，否则会把 failover 已学到的"哪些 combo 失败过"知识
# 静默清空，导致失败 combo 反复进轮询。
#
# 设计/契约：
#   doc/implementation/failover-combo-implementation.md
#   CLAUDE.md 硬规则 #8（fss_* hot-only keys）

dbus set fss_failover_internal_restart="2"
exec /bin/sh /koolshare/ss/ssconfig.sh restart
