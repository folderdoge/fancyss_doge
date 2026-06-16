#!/bin/sh

# fancyss script for asuswrt/merlin based router with software center
#
# fork doge.12 alpha: 分流架构 Rule 自动更新 cron 入口
# 设计 / 数据契约：
#   doc/design/split-routing-architecture.md §10  （cron 设计 + 调度表）
#   doc/implementation/split-routing-implementation.md §1.2 / §1.7 （dbus key 契约）
#
# 用法：
#   /koolshare/scripts/fss_rules_update.sh                   cron 模式：扫所有 Rule，按 update_hours 决定是否更新
#   /koolshare/scripts/fss_rules_update.sh --rule-id <id>    UI 强制立即更新模式：只跑 Rule.id == <id>
#
# alpha 期所有内置 Rule.update_hours=0，cron 跑一圈基本是 no-op（守护跳过）。
# 用户自定义 Rule + 设置 source_url & update_hours 才真正下载。

source /koolshare/scripts/base.sh

alias echo_date='echo 【$(TZ=UTC-8 date -R +%Y%m%d\ %X)】:'

LOCK_KEY="fss_split_rules_update_lock"
LOG_KEY="fss_split_rules_update_log"
RULES_DIR="/koolshare/ss/rules_user"
TMP_DIR="/tmp"

# 限额（与设计文档 §10.2 一致）
MAX_LINES=1000000
MAX_BYTES=$((50 * 1024 * 1024))
CURL_CONNECT_TIMEOUT=30
CURL_MAX_TIME=300

# 本轮内部状态
NEED_RESTART=0
COUNT_OK=0
COUNT_SKIP=0
COUNT_FAIL=0
LAST_FAIL_REASON=""

run(){
	env -i PATH=${PATH} "$@"
}

# ============================================================================
# 锁管理（与 cron 互斥；UI 强制更新模式也走同一把锁）
# ============================================================================

acquire_lock(){
	local cur="$(dbus get ${LOCK_KEY} 2>/dev/null)"
	if [ "${cur}" = "1" ]; then
		echo_date "另一个 fss_rules_update 实例正在运行（${LOCK_KEY}=1），本轮退出。"
		return 1
	fi
	dbus set ${LOCK_KEY}=1 >/dev/null 2>&1
	# trap 在 ash/busybox 下 EXIT 信号可用
	trap 'release_lock' EXIT INT TERM HUP
	return 0
}

release_lock(){
	dbus set ${LOCK_KEY}=0 >/dev/null 2>&1
}

# ============================================================================
# Rule 数据读取 + 文件校验
# ============================================================================

# 把 dbus list 输出的 ss_split_rule_<i>_xxx=value 行解析出来。
# 返回所有"槽位 i"列表，按数值升序，一行一个。
list_rule_slots(){
	dbus list ss_split_rule_ 2>/dev/null \
		| awk -F'=' '{print $1}' \
		| awk -F'_' '$4 ~ /^[0-9]+$/ {print $4}' \
		| sort -nu
}

# 读 dbus rule 字段。
# 用法：rule_get <slot> <field>
# 字段：id name builtin source_url update_hours last_update stat_domains stat_ips
rule_get(){
	dbus get "ss_split_rule_$1_$2" 2>/dev/null
}

rule_set(){
	dbus set "ss_split_rule_$1_$2=$3" >/dev/null 2>&1
}

# 重算规则文件的域名行数 / IP 行数。
# 与设计文档 §3.4 一致：
#   - 域名 = 不含 '/' 且不是纯 IPv4/IPv6 的行
#   - IP/CIDR = 含 '/' 的行 + 纯 IPv4 + 纯 IPv6
# 注释（# 起头）和空行不计。
recount_stats(){
	local f="$1"
	local _stat_d="$2"   # 引用变量名：domains
	local _stat_i="$3"   # 引用变量名：ips
	local d=0 i=0

	if [ ! -f "${f}" ]; then
		eval "${_stat_d}=0"
		eval "${_stat_i}=0"
		return 0
	fi

	# 读出非空、非注释的有效行后再分两类
	# 纯 IPv4 / IPv4-CIDR / IPv6 / IPv6-CIDR 算 IP
	# 其它（含点的域名 / 纯英文 / wildcard）算域名
	# 注意 busybox awk 支持的扩展正则有限，分两步做
	local total_ip=0 total_dom=0
	while IFS= read -r line; do
		# 去掉前后空白和 CR
		line="$(printf '%s' "${line}" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
		[ -z "${line}" ] && continue
		case "${line}" in
			\#*|\;*) continue;;
		esac
		# 含 / 一律算 IP/CIDR（约定如此，性能也好）
		case "${line}" in
			*/*) total_ip=$((total_ip + 1)); continue;;
		esac
		# 纯 IPv4：四段全数字
		if echo "${line}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
			total_ip=$((total_ip + 1))
			continue
		fi
		# IPv6 粗略判定：含冒号且不含字母以外字符（含 hex a-f）
		if echo "${line}" | grep -Eq '^[0-9a-fA-F:]+$' && echo "${line}" | grep -q ':'; then
			total_ip=$((total_ip + 1))
			continue
		fi
		total_dom=$((total_dom + 1))
	done < "${f}"

	d=${total_dom}
	i=${total_ip}
	eval "${_stat_d}=${d}"
	eval "${_stat_i}=${i}"
}

# 文件校验：行数 / 字节数 / UTF-8 合法性
validate_rule_file(){
	local f="$1"
	local lines bytes

	if [ ! -s "${f}" ]; then
		LAST_FAIL_REASON="文件为空"
		return 1
	fi

	bytes=$(wc -c < "${f}" 2>/dev/null | tr -d ' ')
	[ -z "${bytes}" ] && bytes=0
	if [ "${bytes}" -gt "${MAX_BYTES}" ]; then
		LAST_FAIL_REASON="超过大小上限：${bytes}B > ${MAX_BYTES}B"
		return 1
	fi

	lines=$(wc -l < "${f}" 2>/dev/null | tr -d ' ')
	[ -z "${lines}" ] && lines=0
	if [ "${lines}" -gt "${MAX_LINES}" ]; then
		LAST_FAIL_REASON="超过行数上限：${lines} > ${MAX_LINES}"
		return 1
	fi

	# UTF-8 合法性：优先用 isutf8（fancyss 自带），fallback iconv，再 fallback 跳过
	if [ -x /koolshare/bin/isutf8 ]; then
		if ! /koolshare/bin/isutf8 -q "${f}" 2>/dev/null; then
			LAST_FAIL_REASON="UTF-8 校验失败"
			return 1
		fi
	elif command -v iconv >/dev/null 2>&1; then
		if ! iconv -f UTF-8 -t UTF-8 "${f}" >/dev/null 2>&1; then
			LAST_FAIL_REASON="UTF-8 校验失败（iconv）"
			return 1
		fi
	fi
	# 找不到检验工具就跳过——只是兜底，主校验是行数 + 字节数
	return 0
}

# ============================================================================
# 单条 Rule 更新主流程
# ============================================================================

# update_one_rule <slot>
# 返回值：
#   0 = 成功更新（需要 restart）
#   1 = 拉取/校验失败（保留原文件）
#   2 = 跳过（未到时间 / alpha 守护 / 缺字段）
update_one_rule(){
	local slot="$1"
	local force="$2"     # 1=强制（--rule-id 路径）；0=正常 cron 调度
	local rid name source_url update_hours last_update
	local now backup_file tmp_file dst_file
	local stat_d stat_i

	rid="$(rule_get "${slot}" id)"
	name="$(rule_get "${slot}" name)"
	source_url="$(rule_get "${slot}" source_url)"
	update_hours="$(rule_get "${slot}" update_hours)"
	last_update="$(rule_get "${slot}" last_update)"

	# 兜底默认值
	[ -z "${update_hours}" ] && update_hours=0
	[ -z "${last_update}" ] && last_update=0

	if [ -z "${rid}" ]; then
		echo_date "  槽位 ${slot} 缺少 id 字段，跳过。"
		return 2
	fi

	# alpha 守护：update_hours=0 或 source_url 为空 → 不自动更新
	# （--rule-id 强制路径绕过 update_hours 判定，但仍要求 source_url 非空）
	if [ -z "${source_url}" ]; then
		# 内置 Rule 大都没 URL（install 期 zcat 本地 .gz 注入），这是正常态
		# 静默跳过，不打日志免得 cron 每次输出一堆
		return 2
	fi

	if [ "${force}" != "1" ] && [ "${update_hours}" = "0" ]; then
		return 2
	fi

	# 时间判定（cron 模式才做）
	if [ "${force}" != "1" ]; then
		now=$(date +%s)
		local elapsed=$((now - last_update))
		local needed=$((update_hours * 3600))
		if [ "${elapsed}" -lt "${needed}" ]; then
			return 2
		fi
	fi

	echo_date "--------------------------------------------------------------------"
	echo_date "开始更新 Rule [id=${rid}, name=${name:-<未命名>}, slot=${slot}]"
	echo_date "  source: ${source_url}"

	# 备份现文件（如果存在）
	dst_file="${RULES_DIR}/rule_${rid}.txt"
	backup_file="${dst_file}.bak"
	if [ -f "${dst_file}" ]; then
		cp -f "${dst_file}" "${backup_file}" 2>/dev/null
	fi

	# 下载到 /tmp/rule_<id>.tmp
	tmp_file="${TMP_DIR}/rule_${rid}.tmp"
	rm -f "${tmp_file}"
	curl --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
		--max-time "${CURL_MAX_TIME}" \
		-fsSL "${source_url}" -o "${tmp_file}" 2>/dev/null
	local rc=$?
	if [ "${rc}" != "0" ]; then
		# 检测一下是不是磁盘满（rc=23 = 写失败）
		if [ "${rc}" = "23" ]; then
			echo_date "  下载失败：写入 ${tmp_file} 失败（可能磁盘满），保留原文件不动。"
		else
			echo_date "  下载失败：curl 退出码 ${rc}（连接超时 / 网络不可用 / HTTP 错误），本轮跳过下轮再试。"
		fi
		rm -f "${tmp_file}"
		LAST_FAIL_REASON="curl rc=${rc}"
		return 1
	fi

	# 校验
	if ! validate_rule_file "${tmp_file}"; then
		echo_date "  下载文件校验失败：${LAST_FAIL_REASON}，保留原文件不动。"
		rm -f "${tmp_file}"
		return 1
	fi

	# 确保目标目录存在（万一第一次跑）
	mkdir -p "${RULES_DIR}" 2>/dev/null

	# 原子替换
	if ! mv -f "${tmp_file}" "${dst_file}"; then
		echo_date "  替换 ${dst_file} 失败（mv），保留原文件不动。"
		rm -f "${tmp_file}"
		LAST_FAIL_REASON="mv 失败"
		return 1
	fi

	# 重算 stat 写回 dbus
	stat_d=0
	stat_i=0
	recount_stats "${dst_file}" stat_d stat_i
	rule_set "${slot}" stat_domains "${stat_d}"
	rule_set "${slot}" stat_ips "${stat_i}"
	rule_set "${slot}" last_update "$(date +%s)"

	echo_date "  更新成功：domains=${stat_d} ips=${stat_i}（原文件已备份至 ${backup_file}）"
	return 0
}

# ============================================================================
# 主入口：cron 模式 / --rule-id 模式
# ============================================================================

run_cron_mode(){
	local slots slot
	local rc
	local now_iso

	echo_date "fss_rules_update 启动（cron 模式）"

	slots="$(list_rule_slots)"
	if [ -z "${slots}" ]; then
		echo_date "未发现任何 ss_split_rule_<i>_* 数据，退出。"
		return 0
	fi

	for slot in ${slots}; do
		update_one_rule "${slot}" "0"
		rc=$?
		case "${rc}" in
			0) COUNT_OK=$((COUNT_OK + 1)); NEED_RESTART=1 ;;
			1) COUNT_FAIL=$((COUNT_FAIL + 1)) ;;
			2) COUNT_SKIP=$((COUNT_SKIP + 1)) ;;
		esac
	done

	echo_date "--------------------------------------------------------------------"
	echo_date "本轮汇总：成功=${COUNT_OK} 失败=${COUNT_FAIL} 跳过=${COUNT_SKIP}"

	now_iso="$(TZ=UTC-8 date '+%Y-%m-%d %H:%M:%S')"
	# 写摘要给 UI 看（JSON 字符串，不依赖 jq——简单转义）
	local summary
	summary="{\"ts\":\"${now_iso}\",\"ok\":${COUNT_OK},\"fail\":${COUNT_FAIL},\"skip\":${COUNT_SKIP},\"mode\":\"cron\"}"
	dbus set "${LOG_KEY}=${summary}" >/dev/null 2>&1

	# Batched restart：只有真正拉到新规则才重启
	if [ "${NEED_RESTART}" = "1" ]; then
		echo_date "检测到至少 1 条 Rule 实际更新成功，触发 ssconfig.sh restart 以应用新规则。"
		run sh /koolshare/ss/ssconfig.sh restart
	fi
}

run_force_mode(){
	local target_id="$1"
	local slots slot rid
	local matched_slot=""
	local rc
	local now_iso

	echo_date "fss_rules_update 启动（--rule-id 强制模式，目标 id=${target_id}）"

	slots="$(list_rule_slots)"
	for slot in ${slots}; do
		rid="$(rule_get "${slot}" id)"
		if [ "${rid}" = "${target_id}" ]; then
			matched_slot="${slot}"
			break
		fi
	done

	if [ -z "${matched_slot}" ]; then
		echo_date "未找到 id=${target_id} 的 Rule，退出。"
		now_iso="$(TZ=UTC-8 date '+%Y-%m-%d %H:%M:%S')"
		dbus set "${LOG_KEY}={\"ts\":\"${now_iso}\",\"ok\":0,\"fail\":1,\"skip\":0,\"mode\":\"force\",\"err\":\"rule_id_not_found\"}" >/dev/null 2>&1
		return 1
	fi

	update_one_rule "${matched_slot}" "1"
	rc=$?
	case "${rc}" in
		0) COUNT_OK=1; NEED_RESTART=1 ;;
		1) COUNT_FAIL=1 ;;
		2) COUNT_SKIP=1 ;;
	esac

	echo_date "--------------------------------------------------------------------"
	echo_date "强制更新汇总：id=${target_id} 成功=${COUNT_OK} 失败=${COUNT_FAIL} 跳过=${COUNT_SKIP}"

	now_iso="$(TZ=UTC-8 date '+%Y-%m-%d %H:%M:%S')"
	dbus set "${LOG_KEY}={\"ts\":\"${now_iso}\",\"ok\":${COUNT_OK},\"fail\":${COUNT_FAIL},\"skip\":${COUNT_SKIP},\"mode\":\"force\",\"rule_id\":${target_id}}" >/dev/null 2>&1

	if [ "${NEED_RESTART}" = "1" ]; then
		echo_date "Rule id=${target_id} 已更新，触发 ssconfig.sh restart 以应用新规则。"
		run sh /koolshare/ss/ssconfig.sh restart
	fi
}

# ============================================================================
# 入口分发
# ============================================================================

main(){
	case "$1" in
		--rule-id)
			if [ -z "$2" ]; then
				echo_date "--rule-id 需要指定 Rule.id 参数，退出。"
				exit 1
			fi
			if ! acquire_lock; then
				exit 1
			fi
			run_force_mode "$2"
			;;
		"")
			if ! acquire_lock; then
				exit 1
			fi
			run_cron_mode
			;;
		*)
			echo_date "用法："
			echo_date "  $0                       # cron 调度模式"
			echo_date "  $0 --rule-id <id>        # 强制更新指定 Rule"
			exit 1
			;;
	esac
}

main "$@"
