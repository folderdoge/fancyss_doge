#!/bin/sh

# fancyss fork doge.13 beta — 分流架构 Mode 持久化 helper
# 由 Module_shadowsocks.asp 的 Mode 编辑/删除弹窗触发：
#   POST /_api/ {"id":<rid>,"method":"ss_split_mode_save.sh","params":[],"fields":{...}}
#
# 框架契约：koolshare /_api/ 调度器会先把 fields 写到 dbus，再以 $1=请求id 调用本脚本。
# 本脚本读 ss_split_mode_save_* 临时 dbus key，处理后清理。
#
# Frontend 传入的临时 keys（create/update/delete 通用）：
#   ss_split_mode_save_op                = "create" | "update" | "delete"
#   ss_split_mode_save_id                = <mode.id>（1+ 整数；用户自定义 >= 100）
# create/update 必填（builtin update 时 name / rule_count / rules_b64 被忽略；
# udp_proxy / block_quic / apply_blackwhite / dns_mode / default_action / rule_<r>_action
# 总是可改——见 CLAUDE.md 决策 4 双模式）：
#   ss_split_mode_save_name              = <显示名>（≤ 40 UTF-8 字节）
#   ss_split_mode_save_builtin_hint      = "0" | "1"（前端 hint, 后端不信任，仅给日志参考）
#   ss_split_mode_save_udp_proxy         = "0" | "1"
#   ss_split_mode_save_block_quic        = "0" | "1"
#   ss_split_mode_save_apply_blackwhite  = "0" | "1"
#   ss_split_mode_save_dns_mode          = "split" | "global" | "remote"
#   ss_split_mode_save_default_action    = "direct" | "proxy_main" | "proxy_node:<N>" | "proxy_chain:<F>:<L>"
#                                          （注意：default_action 不允许 "reject"，详见 validate_action）
#   ss_split_mode_save_rule_count        = <0~64>
#   ss_split_mode_save_rules_b64         = base64(JSON array of {rid, action})；空 = "[]"
#
# 输出 keys（前端轮询读）：
#   ss_split_mode_save_result            = "ok" | "error"
#   ss_split_mode_save_error             = 失败原因（仅 result=error 时）
#
# 设计 / 数据契约：
#   doc/implementation/split-routing-implementation.md §1.3 (Mode dbus key)
#   doc/design/split-routing-architecture.md §3 (Mode/Rule/User 三层模型)
#   CLAUDE.md 硬规则 #16（无 /dev/stdout fallback）+ #15（dbus list/remove 不对称）

export KSROOT=/koolshare
source $KSROOT/scripts/base.sh

LOG_TAG="[ss_split_mode_save]"
MAX_RULE_COUNT=64

# === COMMON BLOCK (keep in sync with ss_split_rule_save.sh) ===
# 下面这些临时 key 常量 + log/cleanup/fail/ok/b64_safe 函数与 ss_split_rule_save.sh
# 同结构（前缀替换为 mode），按 CLAUDE.md 决策 6 决定 copy-paste 不抽公共文件。
# 改动这块时，请同步检查 ss_split_rule_save.sh 是否需要同样修订。

TMP_OP_KEY="ss_split_mode_save_op"
TMP_ID_KEY="ss_split_mode_save_id"
TMP_NAME_KEY="ss_split_mode_save_name"
TMP_BUILTIN_HINT_KEY="ss_split_mode_save_builtin_hint"
TMP_UDP_KEY="ss_split_mode_save_udp_proxy"
TMP_QUIC_KEY="ss_split_mode_save_block_quic"
TMP_BW_KEY="ss_split_mode_save_apply_blackwhite"
TMP_DNS_KEY="ss_split_mode_save_dns_mode"
TMP_DEFACT_KEY="ss_split_mode_save_default_action"
TMP_RCOUNT_KEY="ss_split_mode_save_rule_count"
TMP_RULES_KEY="ss_split_mode_save_rules_b64"
TMP_RESULT_KEY="ss_split_mode_save_result"
TMP_ERROR_KEY="ss_split_mode_save_error"

log() {
	echo "$(date +'%Y%m%d %H:%M:%S') ${LOG_TAG} $*" >> /tmp/syslog.log 2>/dev/null
}

cleanup_tmp() {
	dbus remove ${TMP_OP_KEY} >/dev/null 2>&1
	dbus remove ${TMP_ID_KEY} >/dev/null 2>&1
	dbus remove ${TMP_NAME_KEY} >/dev/null 2>&1
	dbus remove ${TMP_BUILTIN_HINT_KEY} >/dev/null 2>&1
	dbus remove ${TMP_UDP_KEY} >/dev/null 2>&1
	dbus remove ${TMP_QUIC_KEY} >/dev/null 2>&1
	dbus remove ${TMP_BW_KEY} >/dev/null 2>&1
	dbus remove ${TMP_DNS_KEY} >/dev/null 2>&1
	dbus remove ${TMP_DEFACT_KEY} >/dev/null 2>&1
	dbus remove ${TMP_RCOUNT_KEY} >/dev/null 2>&1
	dbus remove ${TMP_RULES_KEY} >/dev/null 2>&1
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
# 详见 memory reference_busybox_base64_loop / CLAUDE.md 硬规则 #16 上下文）
b64_safe() {
	printf '%s' "$1" | tr -d '\n\r\t ' | grep -qE '^[A-Za-z0-9+/]*=*$'
}
# === END COMMON BLOCK ===

# 按 mode.id 找 slot；返回 slot 号 (1+) 或空串
# 注意 $5 == "id" 过滤——避免 ss_split_mode_<N>_rule_<R>_rid 的 awk 切出 N 干扰判断。
find_mode_slot_by_id() {
	local target="$1"
	local slot mid
	for slot in $(dbus list ss_split_mode_ 2>/dev/null \
				  | awk -F'=' '{print $1}' \
				  | awk -F'_' '$4 ~ /^[0-9]+$/ && $5 == "id" {print $4}' \
				  | sort -nu); do
		mid="$(dbus get ss_split_mode_${slot}_id 2>/dev/null)"
		if [ "${mid}" = "${target}" ]; then
			echo "${slot}"
			return 0
		fi
	done
	return 1
}

# has_dbus_forbidden_chars：检查字符串含 dbus 文本格式破坏字符 (" ` $ \ = CR LF)
# 用法：has_dbus_forbidden_chars "$value" && fail "..."
# 设计原因（doge.13 hotfix #20）：原版 case "*'<CR>'*" 依赖字面 0x0D 字节夹在单引号之间，
# 但 Edit/Write 工具无法插入字面 CR → beta.2 写代码时变成 "*''*"，POSIX shell 里 '' = 空串，
# *''* 等价 ** 匹配任何非空字符串 → Mode 编辑保存全部被拒。改用 printf+tr 绕开字面 CR/LF。
has_dbus_forbidden_chars() {
	case "$1" in
		*\"*|*\`*|*\$*|*=*|*\\*) return 0;;
	esac
	[ "$(printf '%s' "$1" | tr -cd '\r\n' | wc -c)" -gt 0 ]
}

# validate_action：校验 action 字符串
# 用法：validate_action <action_str> <field_label> <allow_reject:0|1>
# 失败直接 fail()（带请求 id），成功返回 0
validate_action() {
	local act="$1"
	local field="$2"
	local allow_reject="$3"

	# 段 1: dbus 文本格式破坏字符
	has_dbus_forbidden_chars "${act}" && fail "${field} contains forbidden chars (\" \` \$ \\ = CR LF)" "${REQ_ID}"
	# 段 2: reject 仅 rule action 允许，default_action 禁用
	if [ "${allow_reject}" != "1" ] && [ "${act}" = "reject" ]; then
		fail "${field} cannot be reject (only allowed in rule actions)" "${REQ_ID}"
	fi
	# 段 3: 前缀白名单 + 格式校验
	case "${act}" in
		direct|reject|proxy_main)
			return 0
			;;
		proxy_node:*)
			local nid="${act#proxy_node:}"
			case "${nid}" in
				''|*[!0-9]*) fail "${field} proxy_node id invalid: '${nid}'" "${REQ_ID}";;
			esac
			[ "${nid}" -lt 1 ] && fail "${field} proxy_node id must be >= 1" "${REQ_ID}"
			;;
		proxy_chain:*:*)
			local rest="${act#proxy_chain:}"
			local fid="${rest%%:*}"
			local lid="${rest#*:}"
			case "${fid}" in
				''|*[!0-9]*) fail "${field} proxy_chain front id invalid: '${fid}'" "${REQ_ID}";;
			esac
			case "${lid}" in
				''|*[!0-9]*) fail "${field} proxy_chain landing id invalid: '${lid}'" "${REQ_ID}";;
			esac
			[ "${fid}" -lt 1 ] && fail "${field} proxy_chain front id must be >= 1" "${REQ_ID}"
			[ "${lid}" -lt 1 ] && fail "${field} proxy_chain landing id must be >= 1" "${REQ_ID}"
			;;
		*)
			fail "${field} unknown encoding: '${act}'" "${REQ_ID}"
			;;
	esac
}

# decode_rules：解 base64 + 校验 JSON array，结果写到 <out> 文件
# 用法：decode_rules <b64_str> <out_file>
# 返回：0=ok, 1=out 未传, 2=非 base64, 3=非 JSON array, 其他=解码失败
# 注意：out 必传（CLAUDE.md 硬规则 #16，无 /dev/stdout fallback）。
decode_rules() {
	local b64="$1"
	local out="$2"
	[ -z "${out}" ] && return 1
	: > "${out}"
	if [ -z "${b64}" ]; then
		echo '[]' > "${out}"
		return 0
	fi
	if ! b64_safe "${b64}"; then
		return 2
	fi
	printf '%s' "${b64}" | tr -d '\n\r\t ' | base64 -d > "${out}.raw" 2>/dev/null
	if ! jq -e 'type=="array"' "${out}.raw" >/dev/null 2>&1; then
		rm -f "${out}.raw"
		return 3
	fi
	mv "${out}.raw" "${out}"
	return 0
}

# 校验 rules JSON 文件的每条 entry 并写入 dbus（slot/mode_id 由调用方提供）
# 用法：validate_and_write_rules <slot> <rules_json_file> <declared_rule_count>
# 失败直接 fail()
validate_and_write_rules() {
	local slot="$1"
	local rules_json="$2"
	local declared="$3"
	local actual r rid action

	actual="$(jq 'length' "${rules_json}" 2>/dev/null)"
	case "${actual}" in
		''|*[!0-9]*) fail "rules JSON length parse failed" "${REQ_ID}";;
	esac
	if [ "${actual}" != "${declared}" ]; then
		fail "rule_count mismatch: declared=${declared}, actual=${actual}" "${REQ_ID}"
	fi

	r=1
	while [ "${r}" -le "${declared}" ]; do
		rid="$(jq -r ".[$((r - 1))].rid" "${rules_json}" 2>/dev/null)"
		action="$(jq -r ".[$((r - 1))].action" "${rules_json}" 2>/dev/null)"
		case "${rid}" in
			''|null|*[!0-9]*) fail "rule_${r}_rid invalid: '${rid}'" "${REQ_ID}";;
		esac
		[ "${rid}" -lt 1 ] && fail "rule_${r}_rid must be >= 1" "${REQ_ID}"
		[ -z "${action}" ] || [ "${action}" = "null" ] && fail "rule_${r}_action missing" "${REQ_ID}"
		# rule action 允许 reject
		validate_action "${action}" "rule_${r}_action" 1
		dbus set ss_split_mode_${slot}_rule_${r}_rid="${rid}"
		dbus set ss_split_mode_${slot}_rule_${r}_action="${action}"
		r=$((r + 1))
	done
}

# 公共 0/1 校验
validate_01() {
	local v="$1"
	local field="$2"
	case "${v}" in
		0|1) return 0 ;;
		*) fail "${field} must be 0 or 1 (got '${v}')" "${REQ_ID}" ;;
	esac
}

# ============================================================================
# Main
# ============================================================================
REQ_ID="$1"

op="$(dbus get ${TMP_OP_KEY} 2>/dev/null)"
target_id="$(dbus get ${TMP_ID_KEY} 2>/dev/null)"

[ -z "${op}" ] && fail "missing op" "${REQ_ID}"
case "${target_id}" in
	''|*[!0-9]*) fail "invalid id (must be positive integer)" "${REQ_ID}";;
esac
[ "${target_id}" -lt 1 ] && fail "id must be >= 1" "${REQ_ID}"

case "${op}" in
	create)
		# --- 读临时 keys ---
		name="$(dbus get ${TMP_NAME_KEY} 2>/dev/null)"
		udp_proxy="$(dbus get ${TMP_UDP_KEY} 2>/dev/null)"
		block_quic="$(dbus get ${TMP_QUIC_KEY} 2>/dev/null)"
		apply_blackwhite="$(dbus get ${TMP_BW_KEY} 2>/dev/null)"
		dns_mode="$(dbus get ${TMP_DNS_KEY} 2>/dev/null)"
		default_action="$(dbus get ${TMP_DEFACT_KEY} 2>/dev/null)"
		rule_count="$(dbus get ${TMP_RCOUNT_KEY} 2>/dev/null)"
		rules_b64="$(dbus get ${TMP_RULES_KEY} 2>/dev/null)"

		# --- 校验 id 范围（用户自定义 >= 100，1~99 留给 builtin） ---
		[ "${target_id}" -lt 100 ] && fail "user-defined mode_id must be >= 100 (1~99 reserved for builtin)" "${REQ_ID}"

		# --- 校验 name ---
		[ -z "${name}" ] && fail "missing name" "${REQ_ID}"
		has_dbus_forbidden_chars "${name}" && fail "name contains forbidden chars (\" \` \$ \\ = CR LF)" "${REQ_ID}"

		# --- 校验各字段 ---
		validate_01 "${udp_proxy}" "udp_proxy"
		validate_01 "${block_quic}" "block_quic"
		validate_01 "${apply_blackwhite}" "apply_blackwhite"
		case "${dns_mode}" in
			split|global|remote) ;;
			*) fail "dns_mode must be 'split', 'global' or 'remote' (got '${dns_mode}')" "${REQ_ID}" ;;
		esac
		validate_action "${default_action}" "default_action" 0

		case "${rule_count}" in
			''|*[!0-9]*) fail "invalid rule_count (must be non-negative integer)" "${REQ_ID}";;
		esac
		[ "${rule_count}" -gt "${MAX_RULE_COUNT}" ] && fail "rule_count > ${MAX_RULE_COUNT} (limit)" "${REQ_ID}"

		# --- id 冲突检查 ---
		existing_slot="$(find_mode_slot_by_id "${target_id}")"
		[ -n "${existing_slot}" ] && fail "mode_id ${target_id} already exists (slot=${existing_slot})" "${REQ_ID}"

		# --- 解码并校验 rules ---
		rules_json="/tmp/ss_split_mode_save_rules.$$.json"
		decode_rules "${rules_b64}" "${rules_json}"
		case $? in
			0) ;;
			1) fail "decode_rules internal error: out file not specified" "${REQ_ID}" ;;
			2) rm -f "${rules_json}"; fail "rules payload contains non-base64 chars" "${REQ_ID}" ;;
			3) rm -f "${rules_json}"; fail "rules payload is not a JSON array" "${REQ_ID}" ;;
			*) rm -f "${rules_json}"; fail "rules decode failed" "${REQ_ID}" ;;
		esac

		# --- 分配 slot ---
		count="$(dbus get ss_split_mode_count 2>/dev/null)"
		case "${count}" in
			''|*[!0-9]*) count=0;;
		esac
		slot=$((count + 1))

		# --- 写永久 dbus key (9 个 scalar) ---
		dbus set ss_split_mode_${slot}_id="${target_id}"
		dbus set ss_split_mode_${slot}_name="${name}"
		dbus set ss_split_mode_${slot}_builtin="0"
		dbus set ss_split_mode_${slot}_udp_proxy="${udp_proxy}"
		dbus set ss_split_mode_${slot}_block_quic="${block_quic}"
		dbus set ss_split_mode_${slot}_apply_blackwhite="${apply_blackwhite}"
		dbus set ss_split_mode_${slot}_dns_mode="${dns_mode}"
		dbus set ss_split_mode_${slot}_default_action="${default_action}"
		dbus set ss_split_mode_${slot}_rule_count="${rule_count}"

		# --- 写 rule list（含逐条校验） ---
		validate_and_write_rules "${slot}" "${rules_json}" "${rule_count}"

		# --- 更新 count + 清理 ---
		dbus set ss_split_mode_count="${slot}"
		rm -f "${rules_json}"

		ok "mode id=${target_id} created (slot=${slot}, rules=${rule_count})" "${REQ_ID}"
		;;
	update)
		# --- 找 slot ---
		slot="$(find_mode_slot_by_id "${target_id}")"
		[ -z "${slot}" ] && fail "mode id ${target_id} not found" "${REQ_ID}"

		# --- 读 builtin 真值（不信任前端 hint，CLAUDE.md 决策 4） ---
		builtin="$(dbus get ss_split_mode_${slot}_builtin 2>/dev/null)"
		[ -z "${builtin}" ] && builtin="0"

		# --- 读临时 keys（所有 update 共用） ---
		udp_proxy="$(dbus get ${TMP_UDP_KEY} 2>/dev/null)"
		block_quic="$(dbus get ${TMP_QUIC_KEY} 2>/dev/null)"
		apply_blackwhite="$(dbus get ${TMP_BW_KEY} 2>/dev/null)"
		dns_mode="$(dbus get ${TMP_DNS_KEY} 2>/dev/null)"
		default_action="$(dbus get ${TMP_DEFACT_KEY} 2>/dev/null)"
		rules_b64="$(dbus get ${TMP_RULES_KEY} 2>/dev/null)"

		# --- 共用字段校验（builtin / 用户都可改） ---
		validate_01 "${udp_proxy}" "udp_proxy"
		validate_01 "${block_quic}" "block_quic"
		validate_01 "${apply_blackwhite}" "apply_blackwhite"
		case "${dns_mode}" in
			split|global|remote) ;;
			*) fail "dns_mode must be 'split', 'global' or 'remote' (got '${dns_mode}')" "${REQ_ID}" ;;
		esac
		validate_action "${default_action}" "default_action" 0

		# --- 写共用字段（运行时字段总是可改） ---
		dbus set ss_split_mode_${slot}_udp_proxy="${udp_proxy}"
		dbus set ss_split_mode_${slot}_block_quic="${block_quic}"
		dbus set ss_split_mode_${slot}_apply_blackwhite="${apply_blackwhite}"
		dbus set ss_split_mode_${slot}_dns_mode="${dns_mode}"
		dbus set ss_split_mode_${slot}_default_action="${default_action}"

		if [ "${builtin}" = "1" ]; then
			# === builtin update 双模式: 锁 name / rule_count / rule_<r>_rid，但 rule_<r>_action 放开 ===
			existing_rule_count="$(dbus get ss_split_mode_${slot}_rule_count 2>/dev/null)"
			case "${existing_rule_count}" in
				''|*[!0-9]*) existing_rule_count=0;;
			esac

			if [ -n "${rules_b64}" ]; then
				rules_json="/tmp/ss_split_mode_save_rules.$$.json"
				decode_rules "${rules_b64}" "${rules_json}"
				case $? in
					0) ;;
					1) fail "decode_rules internal error" "${REQ_ID}" ;;
					2) rm -f "${rules_json}"; fail "rules payload contains non-base64 chars" "${REQ_ID}" ;;
					3) rm -f "${rules_json}"; fail "rules payload is not a JSON array" "${REQ_ID}" ;;
					*) rm -f "${rules_json}"; fail "rules decode failed" "${REQ_ID}" ;;
				esac

				incoming_count="$(jq 'length' "${rules_json}" 2>/dev/null)"
				case "${incoming_count}" in
					''|*[!0-9]*) rm -f "${rules_json}"; fail "rules JSON length parse failed" "${REQ_ID}";;
				esac
				if [ "${incoming_count}" != "${existing_rule_count}" ]; then
					rm -f "${rules_json}"
					fail "built-in mode rule_count is locked (existing=${existing_rule_count}, incoming=${incoming_count})" "${REQ_ID}"
				fi

				# 逐条比 rid（锁 rid），仅写 action
				r=1
				while [ "${r}" -le "${existing_rule_count}" ]; do
					incoming_rid="$(jq -r ".[$((r - 1))].rid" "${rules_json}" 2>/dev/null)"
					incoming_action="$(jq -r ".[$((r - 1))].action" "${rules_json}" 2>/dev/null)"
					existing_rid="$(dbus get ss_split_mode_${slot}_rule_${r}_rid 2>/dev/null)"
					if [ "${incoming_rid}" != "${existing_rid}" ]; then
						rm -f "${rules_json}"
						fail "built-in mode rule_${r}_rid is locked (existing=${existing_rid}, incoming=${incoming_rid})" "${REQ_ID}"
					fi
					[ -z "${incoming_action}" ] || [ "${incoming_action}" = "null" ] && {
						rm -f "${rules_json}"
						fail "rule_${r}_action missing" "${REQ_ID}"
					}
					validate_action "${incoming_action}" "rule_${r}_action" 1
					dbus set ss_split_mode_${slot}_rule_${r}_action="${incoming_action}"
					r=$((r + 1))
				done
				rm -f "${rules_json}"
			fi
			# builtin update 不动 name / rule_count / rule_<r>_rid
			ok "builtin mode id=${target_id} updated (slot=${slot}, runtime fields only)" "${REQ_ID}"
		else
			# === 用户自定义 mode：完整字段重写 + rule list 完全替换 ===
			name="$(dbus get ${TMP_NAME_KEY} 2>/dev/null)"
			rule_count="$(dbus get ${TMP_RCOUNT_KEY} 2>/dev/null)"

			[ -z "${name}" ] && fail "missing name" "${REQ_ID}"
			has_dbus_forbidden_chars "${name}" && fail "name contains forbidden chars (\" \` \$ \\ = CR LF)" "${REQ_ID}"

			case "${rule_count}" in
				''|*[!0-9]*) fail "invalid rule_count" "${REQ_ID}";;
			esac
			[ "${rule_count}" -gt "${MAX_RULE_COUNT}" ] && fail "rule_count > ${MAX_RULE_COUNT} (limit)" "${REQ_ID}"

			# 解码并校验 rules
			rules_json="/tmp/ss_split_mode_save_rules.$$.json"
			decode_rules "${rules_b64}" "${rules_json}"
			case $? in
				0) ;;
				1) fail "decode_rules internal error" "${REQ_ID}" ;;
				2) rm -f "${rules_json}"; fail "rules payload contains non-base64 chars" "${REQ_ID}" ;;
				3) rm -f "${rules_json}"; fail "rules payload is not a JSON array" "${REQ_ID}" ;;
				*) rm -f "${rules_json}"; fail "rules decode failed" "${REQ_ID}" ;;
			esac

			# 读旧 rule_count，决定要清的残余范围
			old_rule_count="$(dbus get ss_split_mode_${slot}_rule_count 2>/dev/null)"
			case "${old_rule_count}" in
				''|*[!0-9]*) old_rule_count=0;;
			esac

			# 写 name + rule_count
			dbus set ss_split_mode_${slot}_name="${name}"
			dbus set ss_split_mode_${slot}_rule_count="${rule_count}"

			# 写新 rule list（含逐条校验）
			validate_and_write_rules "${slot}" "${rules_json}" "${rule_count}"

			# 清理旧 rule list 超出新 rule_count 的残余
			if [ "${old_rule_count}" -gt "${rule_count}" ]; then
				r=$((rule_count + 1))
				while [ "${r}" -le "${old_rule_count}" ]; do
					dbus remove ss_split_mode_${slot}_rule_${r}_rid >/dev/null 2>&1
					dbus remove ss_split_mode_${slot}_rule_${r}_action >/dev/null 2>&1
					r=$((r + 1))
				done
			fi

			rm -f "${rules_json}"
			ok "mode id=${target_id} updated (slot=${slot}, rules=${rule_count})" "${REQ_ID}"
		fi
		;;
	delete)
		# --- 找 slot ---
		slot="$(find_mode_slot_by_id "${target_id}")"
		[ -z "${slot}" ] && fail "mode id ${target_id} not found" "${REQ_ID}"

		# --- 守 builtin ---
		builtin="$(dbus get ss_split_mode_${slot}_builtin 2>/dev/null)"
		[ "${builtin}" = "1" ] && fail "cannot delete built-in mode (id=${target_id})" "${REQ_ID}"

		# --- 读 count ---
		count="$(dbus get ss_split_mode_count 2>/dev/null)"
		case "${count}" in
			''|*[!0-9]*) count=0;;
		esac

		# --- default_mode_id fallback：如果删的就是 default，自动选第一个 builtin Mode ---
		cur_default="$(dbus get ss_split_default_mode_id 2>/dev/null)"
		if [ "${cur_default}" = "${target_id}" ]; then
			# 扫一遍找第一个 builtin Mode 的 id
			new_default=""
			for s in $(dbus list ss_split_mode_ 2>/dev/null \
					   | awk -F'=' '{print $1}' \
					   | awk -F'_' '$4 ~ /^[0-9]+$/ && $5 == "id" {print $4}' \
					   | sort -nu); do
				[ "${s}" = "${slot}" ] && continue
				b="$(dbus get ss_split_mode_${s}_builtin 2>/dev/null)"
				if [ "${b}" = "1" ]; then
					new_default="$(dbus get ss_split_mode_${s}_id 2>/dev/null)"
					break
				fi
			done
			if [ -n "${new_default}" ]; then
				dbus set ss_split_default_mode_id="${new_default}"
				log "default_mode_id fallback: ${target_id} → ${new_default}"
			else
				log "WARN: no builtin mode found for default_mode_id fallback (kept '${cur_default}')"
			fi
		fi

		# --- ACL 引用清零：所有 ss_acl_split_mode_<i> 值 == target_id 的设为 0 ---
		acl_cleared=0
		for kv in $(dbus list ss_acl_split_mode_ 2>/dev/null); do
			k="${kv%%=*}"
			v="${kv#*=}"
			if [ "${v}" = "${target_id}" ]; then
				dbus set "${k}"="0"
				acl_cleared=$((acl_cleared + 1))
			fi
		done

		# --- slot shift：先快照 slot+1..count 的 rule_count，避免"读源已被覆盖" ---
		# rule_count 必须快照——后面 shift 时如果用 dbus get next slot 的 rule_count，
		# 而 next-1 已经被覆盖到 slot，next 的 rule_count 在多步 shift 中仍能读到正确
		# 值（next 此时还没被改），但保险起见先 snapshot；并且这能让 rule list 清理
		# 范围用同一份事实，不易出错。CLAUDE.md 决策 8。
		rc_snap_file="/tmp/ss_split_mode_save_rc_snap.$$"
		: > "${rc_snap_file}"
		s_snap=$((slot + 1))
		while [ "${s_snap}" -le "${count}" ]; do
			rc_v="$(dbus get ss_split_mode_${s_snap}_rule_count 2>/dev/null)"
			case "${rc_v}" in
				''|*[!0-9]*) rc_v=0;;
			esac
			echo "${s_snap} ${rc_v}" >> "${rc_snap_file}"
			s_snap=$((s_snap + 1))
		done

		# --- 先清掉 victim slot 自己的 rule list（这些 key 不会被 shift 覆盖到，必须显式删） ---
		victim_rule_count="$(dbus get ss_split_mode_${slot}_rule_count 2>/dev/null)"
		case "${victim_rule_count}" in
			''|*[!0-9]*) victim_rule_count=0;;
		esac
		r=1
		while [ "${r}" -le "${victim_rule_count}" ]; do
			dbus remove ss_split_mode_${slot}_rule_${r}_rid >/dev/null 2>&1
			dbus remove ss_split_mode_${slot}_rule_${r}_action >/dev/null 2>&1
			r=$((r + 1))
		done

		# --- slot shift：把 slot+1..count 整体下移一格 ---
		# 字段集：9 个 scalar + 每个 slot 的 rule list（按快照 rule_count）
		s="${slot}"
		while [ "${s}" -lt "${count}" ]; do
			next=$((s + 1))
			# 9 个 scalar 全部 shift（包括 builtin / id 等所有字段；始终 dbus set，
			# 即使值为空字符串——与 ss_split_rule_save.sh C-CRIT-5 同语义）
			for f in id name builtin udp_proxy block_quic apply_blackwhite dns_mode default_action rule_count; do
				val="$(dbus get ss_split_mode_${next}_${f} 2>/dev/null)"
				dbus set ss_split_mode_${s}_${f}="${val}"
			done
			# rule list shift：用快照里 next 的 rule_count
			next_rc="$(awk -v want="${next}" '$1 == want {print $2; exit}' "${rc_snap_file}")"
			case "${next_rc}" in
				''|*[!0-9]*) next_rc=0;;
			esac
			r=1
			while [ "${r}" -le "${next_rc}" ]; do
				rid_val="$(dbus get ss_split_mode_${next}_rule_${r}_rid 2>/dev/null)"
				action_val="$(dbus get ss_split_mode_${next}_rule_${r}_action 2>/dev/null)"
				dbus set ss_split_mode_${s}_rule_${r}_rid="${rid_val}"
				dbus set ss_split_mode_${s}_rule_${r}_action="${action_val}"
				r=$((r + 1))
			done
			s="${next}"
		done

		# --- 删最后一个槽位的残余 ---
		# 9 个 scalar
		for f in id name builtin udp_proxy block_quic apply_blackwhite dns_mode default_action rule_count; do
			dbus remove ss_split_mode_${count}_${f} >/dev/null 2>&1
		done
		# 最后一个槽位的 rule list（用其快照 rule_count；
		# 它在 shift 前是 count 自己的 rule list，快照已经存到 rc_snap_file 上一轮）
		last_rc="$(awk -v want="${count}" '$1 == want {print $2; exit}' "${rc_snap_file}")"
		case "${last_rc}" in
			''|*[!0-9]*) last_rc=0;;
		esac
		r=1
		while [ "${r}" -le "${last_rc}" ]; do
			dbus remove ss_split_mode_${count}_rule_${r}_rid >/dev/null 2>&1
			dbus remove ss_split_mode_${count}_rule_${r}_action >/dev/null 2>&1
			r=$((r + 1))
		done

		# --- 更新 count ---
		new_count=$((count - 1))
		[ "${new_count}" -lt 0 ] && new_count=0
		dbus set ss_split_mode_count="${new_count}"

		rm -f "${rc_snap_file}"

		ok "mode id=${target_id} deleted (was slot ${slot}; new count=${new_count}; acl_cleared=${acl_cleared})" "${REQ_ID}"
		;;
	*)
		fail "unknown op: ${op}" "${REQ_ID}"
		;;
esac
