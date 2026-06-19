#!/bin/sh

# fancyss fork doge.12 — 内置 Rule (id 1~2) 源文件 seed helper
#
# 用途：把内置 Rule 的 rule_${rid}.txt 文件（chnlist / gfwlist / 公共DNS / adblock /
# Telegram / 在线检测 / 查IP / Bing）重建到 /koolshare/ss/rules_user/ 下，并把
# 实际行数回写到 ss_split_rule_<slot>_stat_domains / stat_ips。
#
# 调用入口（两个）：
#   1) install.sh::migrate_split_routing_v1 — 首次迁移 + marker=1 自愈分支
#   2) ssconfig.sh::generate_xray_json_split — 运行时健康检查 + hot reseed
#
# 设计要点（幂等 + 自愈安全）：
#   - 每次跑都覆盖重写 rule_1.txt~rule_8.txt（_write_rule_header 清空+起头，后续 >> 追加）
#   - id / builtin=1 / last_update / stat_domains / stat_ips 必写（结构性 + 与文件一致）
#   - name / source_url / update_hours 仅在 dbus key 缺失时写默认值（保护用户已改的元数据）
#   - 不动 rid >= 9 的用户自定义 Rule 文件
#   - 不动 ss_split_mode_* / ss_split_default_mode_id（Mode 元数据由 install.sh 单独管理）
#
# 历史背景：
#   alpha.8 (commit 876890d) 修了"rules_user 目录丢失"——install.sh 加了 mkdir 兜底。
#   但 alpha.11 用户实测，目录在、文件却被某些升级路径吃掉了；generate_xray_json_split
#   在 ssconfig.sh:5305 `[ -f "${rfile}" ]` 守卫下静默跳过 → Mode 2 routing 只剩兜底 →
#   所有流量走代理。本 helper 即为"同形漏修"补丁。
#
# 数据契约：doc/implementation/split-routing-implementation.md §1.2 (Rule dbus key)
# 内容来源：install.sh::migrate_split_routing_v1 Step 1 原 inline 代码（搬过来不改语义）

# ----------------------------------------------------------------------------
# 自包含 helper（被 source 时不重定义；命令行直跑时兜底定义）
# ----------------------------------------------------------------------------

# doge.14-beta.1 BLOCKER fix: koolshare base.sh:7 + ss_*/dns_test/rule_update 等
# 文件定义 `alias echo_date='echo 【$(...)】:'`（含 $() 复杂展开）。
# busybox sh 1.25.1 解析下面的 `echo_date(){` 函数定义时会展开 alias，把它变成
# `echo 【$(...)】:(){` → syntax error: unexpected "(" (expecting "fi")。
# 修法：先 unalias 让 alias 离场，再 type 检测 + 定义 function。
# sh 逐 statement parse+execute，unalias 这行先跑，下面的 function 定义 parse 时
# 已经没 alias 干扰。下游 caller 之后调 echo_date 用 function 等价 alias。
unalias echo_date >/dev/null 2>&1

if ! type echo_date >/dev/null 2>&1; then
	# 与 install.sh::echo_date 同语义
	echo_date(){
		echo "【$(TZ=UTC-8 date -R "+%Y%m%d %X")】: $*"
	}
fi

# 给 rule_<id>.txt 顶部写头注释（覆盖式 = 清空文件再起头）
# 后续 Rule 内容用 >> 追加
_seed_write_rule_header(){
	local rid="$1" rname="$2"
	local rfile="/koolshare/ss/rules_user/rule_${rid}.txt"
	{
		echo "# fancyss-rule v1"
		echo "# id: ${rid}"
		echo "# name: ${rname}"
		echo "# auto-generated rule_${rid}.txt by fancyss_split_seed_rule_files_v1 @ $(date +%s)"
	} > "${rfile}"
}

# 统计 rule 文件的 domain / ip 行数（跳过头注释 / 空行）
# 用 awk 单次扫描（不能用 while-read+grep；chnlist 7 万行会 fork 14 万次子进程
# AX86U 上 9-15 分钟，alpha.2 用户报 → alpha.3 改 awk，详见 install.sh:552-568 注释）
_seed_count_rule_entries(){
	local rfile="$1"
	if [ ! -f "${rfile}" ]; then
		echo "0 0"
		return
	fi
	awk '
		/^[[:space:]]*$/ { next }
		/^#/             { next }
		/^[0-9a-fA-F:.]+(\/[0-9]+)?$/ { ip++; next }
		{ dn++ }
		END { printf "%d %d\n", dn+0, ip+0 }
	' "${rfile}"
}

# 写一条内置 Rule 的 dbus 元数据
# 用法：_seed_write_rule_meta <rid> <name> <source_url> <update_hours> <stat_domains> <stat_ips>
#
# 自愈安全策略：
#   - id / builtin / last_update / stat_domains / stat_ips → 总是覆盖写（结构性 + 跟文件强一致）
#   - name / source_url / update_hours → 仅在 dbus key 缺失时写默认；已存在则保留
#     （保护用户可能在 ASP UI 改过的 name / 自定义 source_url / update_hours）
#
# alpha 阶段 slot==rid（CLAUDE.md 硬规则 #13 1-indexed）。
_seed_write_rule_meta(){
	local rid="$1" rname="$2" surl="$3" uhours="$4" sdom="$5" sips="$6"
	local now_ts="$(date +%s)"
	[ -z "${sdom}" ] && sdom=0
	[ -z "${sips}" ] && sips=0

	dbus set ss_split_rule_${rid}_id="${rid}"
	dbus set ss_split_rule_${rid}_builtin="1"
	dbus set ss_split_rule_${rid}_last_update="${now_ts}"
	dbus set ss_split_rule_${rid}_stat_domains="${sdom}"
	dbus set ss_split_rule_${rid}_stat_ips="${sips}"

	# name / source_url / update_hours：仅在缺失时写默认，保留用户已改的
	local cur
	cur="$(dbus get ss_split_rule_${rid}_name 2>/dev/null)"
	[ -z "${cur}" ] && dbus set ss_split_rule_${rid}_name="${rname}"
	cur="$(dbus get ss_split_rule_${rid}_source_url 2>/dev/null)"
	if [ -z "${cur}" ]; then
		# 内置 Rule 默认 source_url 为空（用户可在 UI 设置 auto-update URL）
		dbus set ss_split_rule_${rid}_source_url="${surl}"
	fi
	cur="$(dbus get ss_split_rule_${rid}_update_hours 2>/dev/null)"
	[ -z "${cur}" ] && dbus set ss_split_rule_${rid}_update_hours="${uhours}"
}

# ============================================================================
# 主函数：重建内置 Rule 1~2 的源文件 + 同步 dbus 元数据
# ============================================================================
fancyss_split_seed_rule_files_v1(){
	local rfile stat_line dn_count ip_count

	mkdir -p /koolshare/ss/rules_user 2>/dev/null
	chmod 755 /koolshare/ss/rules_user 2>/dev/null

	echo_date "🔧 split-seed: 开始 reseed 内置 Rule 1~2 源文件..."

	# ---------- Rule 1: 大陆白名单_场景 = chnlist.gz 域名 + rules_ng2/ip/cn.txt ----------
	echo_date "  reseed Rule 1: 大陆白名单_场景"
	_seed_write_rule_header 1 "大陆白名单_场景"
	rfile="/koolshare/ss/rules_user/rule_1.txt"
	if [ -f /koolshare/ss/rules/chnlist.gz ]; then
		zcat /koolshare/ss/rules/chnlist.gz 2>/dev/null | grep -v '^[[:space:]]*$' | grep -v '^#' >> "${rfile}" || { echo_date "  ⚠️ Rule 1: zcat chnlist.gz 失败"; }
	else
		echo_date "  ⚠️ Rule 1: /koolshare/ss/rules/chnlist.gz 不存在，跳过域名灌入"
	fi
	if [ -f /koolshare/ss/rules_ng2/ip/cn.txt ]; then
		cat /koolshare/ss/rules_ng2/ip/cn.txt 2>/dev/null | grep -v '^[[:space:]]*$' | grep -v '^#' >> "${rfile}" || { echo_date "  ⚠️ Rule 1: cat ip/cn.txt 失败"; }
	else
		echo_date "  ⚠️ Rule 1: /koolshare/ss/rules_ng2/ip/cn.txt 不存在，跳过 IP 灌入"
	fi
	stat_line="$(_seed_count_rule_entries "${rfile}")"
	dn_count="${stat_line% *}"
	ip_count="${stat_line#* }"
	_seed_write_rule_meta 1 "大陆白名单_场景" "" 0 "${dn_count}" "${ip_count}"

	# ---------- Rule 2: GFW列表_常用 = gfwlist.gz ----------
	echo_date "  reseed Rule 2: GFW列表_常用"
	_seed_write_rule_header 2 "GFW列表_常用"
	rfile="/koolshare/ss/rules_user/rule_2.txt"
	if [ -f /koolshare/ss/rules/gfwlist.gz ]; then
		zcat /koolshare/ss/rules/gfwlist.gz 2>/dev/null | grep -v '^[[:space:]]*$' | grep -v '^#' >> "${rfile}" || { echo_date "  ⚠️ Rule 2: zcat gfwlist.gz 失败"; }
	else
		echo_date "  ⚠️ Rule 2: /koolshare/ss/rules/gfwlist.gz 不存在，跳过域名灌入"
	fi
	stat_line="$(_seed_count_rule_entries "${rfile}")"
	dn_count="${stat_line% *}"
	ip_count="${stat_line#* }"
	_seed_write_rule_meta 2 "GFW列表_常用" "" 0 "${dn_count}" "${ip_count}"

	echo_date "✅ split-seed: 内置 Rule 1~2 源文件 reseed 完成"
	return 0
}

# ============================================================================
# 命令行直接调用入口（运维 SSH 紧急 reseed 用）
#   /koolshare/scripts/ss_split_rule_seed.sh
#   /koolshare/scripts/ss_split_rule_seed.sh reseed_all
# 被其他脚本 source 时（$0 不是本文件名）不自动跑，等调用方显式 invoke。
# ============================================================================
if [ "${0##*/}" = "ss_split_rule_seed.sh" ]; then
	[ -f /koolshare/scripts/ss_base.sh ] && . /koolshare/scripts/ss_base.sh 2>/dev/null
	case "$1" in
		""|reseed_all)
			fancyss_split_seed_rule_files_v1
			;;
		*)
			echo "Usage: $0 [reseed_all]" >&2
			exit 2
			;;
	esac
fi
