#!/bin/sh

# fancyss fork doge.12 — 分流架构 Rule 持久化 helper
# 由 Module_shadowsocks.asp 的 Rule 编辑弹窗触发：
#   POST /_api/ {"id":<rid>,"method":"ss_split_rule_save.sh","params":[],"fields":{...}}
#
# 框架契约：koolshare /_api/ 调度器会先把 fields 写到 dbus，再以 $1=请求id 调用本脚本。
# 本脚本读 ss_split_rule_save_* 临时 dbus key，处理后清理。
#
# Frontend 传入的临时 keys：
#   ss_split_rule_save_op           = "create" | "update" | "delete"
#   ss_split_rule_save_id           = <rule.id>（1+ 整数；alpha 阶段 index==id）
#   ss_split_rule_save_name         = <显示名>（create/update 必填）
#   ss_split_rule_save_source_url   = <auto-update URL>（可空）
#   ss_split_rule_save_update_hours = <小时数>（0=禁用 auto-update）
#   ss_split_rule_save_payload_b64  = base64(域名+IP 混排，一行一条；可空 = 空规则)
#
# 输出 keys（前端轮询读）：
#   ss_split_rule_save_result       = "ok" | "error"
#   ss_split_rule_save_error        = 失败原因（仅 result=error 时）
#
# 设计 / 数据契约：
#   doc/implementation/split-routing-implementation.md §1.2 (Rule dbus key)
#   doc/design/split-routing-architecture.md §3.4 (stats 计算约定)

export KSROOT=/koolshare
source $KSROOT/scripts/base.sh

LOG_TAG="[ss_split_rule_save]"
RULES_DIR="/koolshare/ss/rules_user"
MAX_LINES=1000000
MAX_BYTES=$((50 * 1024 * 1024))

TMP_OP_KEY="ss_split_rule_save_op"
TMP_ID_KEY="ss_split_rule_save_id"
TMP_NAME_KEY="ss_split_rule_save_name"
TMP_SRC_KEY="ss_split_rule_save_source_url"
TMP_HRS_KEY="ss_split_rule_save_update_hours"
TMP_PAYLOAD_KEY="ss_split_rule_save_payload_b64"
TMP_RESULT_KEY="ss_split_rule_save_result"
TMP_ERROR_KEY="ss_split_rule_save_error"

# has_dbus_forbidden_chars：检查字符串含 dbus 文本格式破坏字符 (" ` $ \ = CR LF)
# 用法：has_dbus_forbidden_chars "$value" && fail "..."
# 设计原因（doge.13 hotfix）：原版 case "*'<CR>'*" 依赖字面 0x0D 字节夹在单引号之间，
# Edit/Write 工具无法稳定插入；rule_save.sh L156 历史上 CR 字节得以保留是因 git 把文件判 binary，
# 但任何未来 normalize 行尾 / autocrlf 切换都可能悄悄吃掉，复发 BLOCKER。改用 printf+tr 绕开字面 CR/LF。
# 同款 helper 也在 ss_split_mode_save.sh，两脚本暂未共享 lib（doge.14 可 DRY 化）。
has_dbus_forbidden_chars() {
	case "$1" in
		*\"*|*\`*|*\$*|*=*|*\\*) return 0;;
	esac
	[ "$(printf '%s' "$1" | tr -cd '\r\n' | wc -c)" -gt 0 ]
}

log() {
	echo "$(date +'%Y%m%d %H:%M:%S') ${LOG_TAG} $*" >> /tmp/syslog.log 2>/dev/null
}

cleanup_tmp() {
	dbus remove ${TMP_OP_KEY} >/dev/null 2>&1
	dbus remove ${TMP_ID_KEY} >/dev/null 2>&1
	dbus remove ${TMP_NAME_KEY} >/dev/null 2>&1
	dbus remove ${TMP_SRC_KEY} >/dev/null 2>&1
	dbus remove ${TMP_HRS_KEY} >/dev/null 2>&1
	dbus remove ${TMP_PAYLOAD_KEY} >/dev/null 2>&1
}

fail() {
	dbus set ${TMP_RESULT_KEY}="error"
	dbus set ${TMP_ERROR_KEY}="$1"
	log "FAIL: $1"
	cleanup_tmp
	http_response "$2"
	exit 0
}

ok() {
	dbus set ${TMP_RESULT_KEY}="ok"
	dbus remove ${TMP_ERROR_KEY} >/dev/null 2>&1
	log "OK: $1"
	cleanup_tmp
	http_response "$2"
	exit 0
}

# base64 字母表纯度检查（避免 busybox base64 -d 在脏输入上死循环——
# 详见 doc/reference 或 memory reference_busybox_base64_loop）
b64_safe() {
	# 容许字符：A-Z a-z 0-9 + / =；换行先剥掉
	printf '%s' "$1" | tr -d '\n\r\t ' | grep -qE '^[A-Za-z0-9+/]*=*$'
}

# 按 rule.id 找 slot；返回 slot 号 (1+) 或空串
find_rule_slot_by_id() {
	local target="$1"
	local slot rid
	for slot in $(dbus list ss_split_rule_ 2>/dev/null | awk -F'=' '{print $1}' | awk -F'_' '$4 ~ /^[0-9]+$/ {print $4}' | sort -nu); do
		rid="$(dbus get ss_split_rule_${slot}_id 2>/dev/null)"
		if [ "${rid}" = "${target}" ]; then
			echo "${slot}"
			return 0
		fi
	done
	return 1
}

# 与 fss_rules_update.sh::recount_stats 同语义（设计文档 §3.4）：
#   含 '/' → IP/CIDR
#   纯 IPv4（四段数字）→ IP
#   含 ':' 且只有 hex → IPv6
#   其余 → 域名
# 注释（#/;）和空行不计。
# 输出："<domain_count> <ip_count>"
recount_stats_file() {
	local f="$1"
	local d=0 i=0 line
	[ -f "${f}" ] || { echo "0 0"; return; }
	while IFS= read -r line; do
		line="$(printf '%s' "${line}" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
		[ -z "${line}" ] && continue
		case "${line}" in
			\#*|\;*) continue;;
		esac
		case "${line}" in
			*/*) i=$((i + 1)); continue;;
		esac
		if echo "${line}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
			i=$((i + 1)); continue
		fi
		if echo "${line}" | grep -Eq '^[0-9a-fA-F:]+$' && echo "${line}" | grep -q ':'; then
			i=$((i + 1)); continue
		fi
		d=$((d + 1))
	done < "${f}"
	echo "${d} ${i}"
}

# ============================================================================
# Main
# ============================================================================
mkdir -p "${RULES_DIR}" 2>/dev/null

REQ_ID="$1"

op="$(dbus get ${TMP_OP_KEY} 2>/dev/null)"
target_id="$(dbus get ${TMP_ID_KEY} 2>/dev/null)"

[ -z "${op}" ] && fail "missing op" "${REQ_ID}"
case "${target_id}" in
	''|*[!0-9]*) fail "invalid id (must be positive integer)" "${REQ_ID}";;
esac
[ "${target_id}" -lt 1 ] && fail "id must be >= 1" "${REQ_ID}"

case "${op}" in
	create|update)
		name="$(dbus get ${TMP_NAME_KEY} 2>/dev/null)"
		source_url="$(dbus get ${TMP_SRC_KEY} 2>/dev/null)"
		update_hours="$(dbus get ${TMP_HRS_KEY} 2>/dev/null)"
		payload_b64="$(dbus get ${TMP_PAYLOAD_KEY} 2>/dev/null)"

		[ -z "${name}" ] && fail "missing name" "${REQ_ID}"
		# C-CRIT-6 修：拒绝包含 dbus 文本格式破坏字符的 name —— 双引号 / 反引号 / $ / \ / 换行 / 等号。
		# 这些字符进了 dbus 后会让 `dbus list` 输出 `key=value` 文本切分错位，下次 awk 切 = 时误读到错误 slot —— 看似数据消失。
		# 反斜杠会让后续 bash 在 `dbus set key="${name}"` 双引号上下文里把 \" \$ 等转义掉，可能绕过本检查的等价形式。
		# 前端 split_v2_save_rule_dialog 已先校验拦截，本检查为后端兜底（绕过前端 / curl 直 POST 等场景）。
		has_dbus_forbidden_chars "${name}" && fail "name contains forbidden chars (\" \` \$ \\ = CR LF)" "${REQ_ID}"
		case "${update_hours}" in
			''|*[!0-9]*) update_hours=0;;
		esac

		rule_file="${RULES_DIR}/rule_${target_id}.txt"

		if [ -n "${payload_b64}" ]; then
			if ! b64_safe "${payload_b64}"; then
				fail "payload contains non-base64 chars (refused to avoid busybox base64 -d loop)" "${REQ_ID}"
			fi
			tmp_file="${rule_file}.tmp.$$"
			printf '%s' "${payload_b64}" | tr -d '\n\r\t ' | base64 -d > "${tmp_file}" 2>/dev/null
			# 体积校验
			bytes=$(wc -c < "${tmp_file}" 2>/dev/null | tr -d ' ')
			[ -z "${bytes}" ] && bytes=0
			if [ "${bytes}" -gt "${MAX_BYTES}" ]; then
				rm -f "${tmp_file}"
				fail "size limit exceeded: ${bytes}B > ${MAX_BYTES}B" "${REQ_ID}"
			fi
			lines=$(wc -l < "${tmp_file}" 2>/dev/null | tr -d ' ')
			[ -z "${lines}" ] && lines=0
			if [ "${lines}" -gt "${MAX_LINES}" ]; then
				rm -f "${tmp_file}"
				fail "line limit exceeded: ${lines} > ${MAX_LINES}" "${REQ_ID}"
			fi
			# 备份既有文件再替换
			[ -f "${rule_file}" ] && cp -f "${rule_file}" "${rule_file}.bak" 2>/dev/null
			mv "${tmp_file}" "${rule_file}"
		else
			# 空 payload：建/留空文件
			[ -f "${rule_file}" ] && cp -f "${rule_file}" "${rule_file}.bak" 2>/dev/null
			: > "${rule_file}"
		fi

		# 重算 stats
		set -- $(recount_stats_file "${rule_file}")
		stat_d="$1"
		stat_i="$2"
		[ -z "${stat_d}" ] && stat_d=0
		[ -z "${stat_i}" ] && stat_i=0

		# 找/分配 slot
		slot="$(find_rule_slot_by_id "${target_id}")"
		is_new=0
		if [ -z "${slot}" ]; then
			# 新 rule：slot = current_count + 1
			count="$(dbus get ss_split_rule_count 2>/dev/null)"
			case "${count}" in
				''|*[!0-9]*) count=0;;
			esac
			slot=$((count + 1))
			dbus set ss_split_rule_count="${slot}"
			is_new=1
		fi

		# 写永久 dbus key
		dbus set ss_split_rule_${slot}_id="${target_id}"
		dbus set ss_split_rule_${slot}_name="${name}"
		dbus set ss_split_rule_${slot}_source_url="${source_url}"
		dbus set ss_split_rule_${slot}_update_hours="${update_hours}"
		dbus set ss_split_rule_${slot}_stat_domains="${stat_d}"
		dbus set ss_split_rule_${slot}_stat_ips="${stat_i}"
		# builtin: 新建默认 0；已存在则保留原值
		existing_builtin="$(dbus get ss_split_rule_${slot}_builtin 2>/dev/null)"
		[ -z "${existing_builtin}" ] && dbus set ss_split_rule_${slot}_builtin="0"
		# alpha.17 修 F-D-1：CREATE 路径补写 last_update。
		# 旧版只有 cron / 手动 update 才会写 last_update（见 ss_split_rule_seed.sh / fss_rules_update.sh），
		# 用户从 UI 新建 rule 后该 key 不存在 → 前端显示"从未更新"，且 cron 评估到期算法会按"很久没更新"逻辑误触发立刻更新。
		# UPDATE 路径不在这里写——update_one_rule (fss_rules_update.sh) 拉到远程 payload 后才写，保留语义。
		if [ "${is_new}" = "1" ]; then
			dbus set ss_split_rule_${slot}_last_update="$(date +%s)"
		fi

		ok "rule id=${target_id} saved (slot=${slot}, stats=${stat_d}d/${stat_i}i)" "${REQ_ID}"
		;;
	delete)
		slot="$(find_rule_slot_by_id "${target_id}")"
		[ -z "${slot}" ] && fail "rule id ${target_id} not found" "${REQ_ID}"

		# 守内置
		builtin="$(dbus get ss_split_rule_${slot}_builtin 2>/dev/null)"
		[ "${builtin}" = "1" ] && fail "cannot delete built-in rule" "${REQ_ID}"

		# 删文件 + .bak
		rm -f "${RULES_DIR}/rule_${target_id}.txt"
		rm -f "${RULES_DIR}/rule_${target_id}.txt.bak"

		# slot shift：slot+1..count 全下移一格
		count="$(dbus get ss_split_rule_count 2>/dev/null)"
		case "${count}" in
			''|*[!0-9]*) count=0;;
		esac
		s="${slot}"
		while [ "${s}" -lt "${count}" ]; do
			next=$((s + 1))
			# C-CRIT-5 修：始终 dbus set（即使值为空字符串）。旧版 if-else 在空字符串分支走 dbus remove，
			# 会把''用户故意清空 source_url''这种语义从''空字符串''误降级为''key 不存在'' ——
			# 前端 db_ss 读到 undefined 而非 ''，可能触发不同分支。
			for f in id name builtin source_url update_hours last_update stat_domains stat_ips; do
				val="$(dbus get ss_split_rule_${next}_${f} 2>/dev/null)"
				dbus set ss_split_rule_${s}_${f}="${val}"
			done
			s="${next}"
		done
		# 删最后一个槽位的残余
		for f in id name builtin source_url update_hours last_update stat_domains stat_ips; do
			dbus remove ss_split_rule_${count}_${f} >/dev/null 2>&1
		done
		new_count=$((count - 1))
		[ "${new_count}" -lt 0 ] && new_count=0
		dbus set ss_split_rule_count="${new_count}"

		ok "rule id=${target_id} deleted (was slot ${slot}; new count=${new_count})" "${REQ_ID}"
		;;
	*)
		fail "unknown op: ${op}" "${REQ_ID}"
		;;
esac
