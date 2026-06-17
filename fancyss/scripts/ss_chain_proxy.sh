#!/bin/sh
# fancyss chain-proxy helper
#
# 启用条件：dbus key ssconf_basic_node_front 非空。
# 仅支持以下协议组合作为前置/落地：
#   type=0 (SS, 不含 obfs)
#   type=3 (VMess)，且不使用 json 自定义 outbound
#   type=4 (Xray Vless/Vmess)，且不使用 json
#   type=5 (Trojan)，不使用 plugin (obfs-local) WebSocket 伪装的复杂分支
#
# 仅支持以下 transport：tcp / ws / grpc。security: none / tls。
# 其他场景视为不支持，本函数会输出告警并直接退出（不修改 xray.json）。
#
# 链式代理实现方式：xray 的 streamSettings.sockopt.dialerProxy。
# 主 outbound（落地节点，索引 0）将 dialerProxy 指向新增的 "proxy_front"。

KSROOT="${KSROOT:-/koolshare}"
. "${KSROOT}/scripts/ss_node_common.sh"

FSS_CHAIN_FRONT_TAG="proxy_front"

fss_chain_log() {
	echo "【$(TZ=UTC-8 date -R +%Y%m%d\ %X)】: [chain-proxy] $*"
}

# 状态写入：state ∈ {disabled, enabled, fallback}；path 仅 enabled 时填，其它清空
fss_chain_set_status() {
	local state="$1" path="$2"
	# 注意：键前缀必须用 ss_ 而非 fss_，因为前端通过 /_api/ss 读取，只匹配 ss/ssconf/ssr 这种 "ss" 开头的键
	dbus set ss_chain_status="${state}" >/dev/null 2>&1
	dbus set ss_chain_path="${path}" >/dev/null 2>&1
}

fss_chain_get_front_id() {
	dbus get ssconf_basic_node_front 2>/dev/null
}

fss_chain_type_supported() {
	# $1=type, $2=node_id (用于附加字段约束检查)
	local t="$1" id="$2" v
	case "${t}" in
	0)
		v=$(fss_get_node_field_plain "${id}" "ss_obfs" 2>/dev/null)
		[ -z "${v}" ] || [ "${v}" = "0" ]
		return $?
		;;
	3)
		v=$(fss_get_node_field_plain "${id}" "v2ray_use_json" 2>/dev/null)
		[ "${v}" != "1" ]
		return $?
		;;
	4)
		v=$(fss_get_node_field_plain "${id}" "xray_use_json" 2>/dev/null)
		[ "${v}" != "1" ]
		return $?
		;;
	5)
		# trojan：不支持 plugin=obfs-local + ws 复杂伪装分支
		v=$(fss_get_node_field_plain "${id}" "trojan_plugin" 2>/dev/null)
		[ -z "${v}" ] || [ "${v}" = "none" ] || [ "${v}" = "0" ]
		return $?
		;;
	8)
		# hysteria2：xray 原生 outbound（doge.10 加入）。不支持 obfs 和端口跳跃
		v=$(fss_get_node_field_plain "${id}" "hy2_obfs" 2>/dev/null)
		if [ "${v}" = "1" ]; then return 1; fi
		# 端口跳跃：hy2_port 含逗号或连字符即范围
		local port_raw
		port_raw=$(fss_get_node_field_plain "${id}" "hy2_port" 2>/dev/null)
		case "${port_raw}" in *,*|*-*) return 1 ;; esac
		return 0
		;;
	esac
	return 1
}

# JSON-string 转义（用于嵌入到 jq --arg）
fss_chain_jq_string() {
	# stdin -> escaped string content (no surrounding quotes)
	awk 'BEGIN{ORS=""} {gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); gsub(/\r/,"\\r"); gsub(/\n/,"\\n"); gsub(/\t/,"\\t"); print}'
}

# 输出布尔 true/false（json 字面量）
fss_chain_bool_json() {
	case "$1" in
	1|true|TRUE) echo true;;
	*) echo false;;
	esac
}

# 构建 transport streamSettings 片段（jq filter，最终合并进 outbound）
# 入参：node_id, network, security, host, path, sni, allow_insecure, alpn_h2, alpn_http, grpc_mode, grpc_authority, grpc_service
# 仅支持 network in {tcp, ws, grpc}, security in {none, tls}
fss_chain_build_stream_settings() {
	local id="$1"
	local network="$2"
	local security="$3"
	local host="$4"
	local path="$5"
	local sni="$6"
	local ai="$7"
	local alpn_h2="$8"
	local alpn_http="$9"
	local grpc_mode="${10}"
	local grpc_authority="${11}"
	local grpc_service="${12}"

	[ -z "${network}" ] && network="tcp"
	case "${network}" in tcp|ws|grpc) ;; *) echo ""; return 1;; esac
	[ -z "${security}" ] && security="none"
	case "${security}" in none|tls) ;; *) echo ""; return 1;; esac

	local ws_block="null" tls_block="null" grpc_block="null"

	if [ "${network}" = "ws" ]; then
		ws_block=$(jq -n --arg path "${path}" --arg host "${host}" '
			{
				path: ($path // ""),
				headers: (if ($host // "") == "" then {} else {Host: $host} end)
			}
		')
	elif [ "${network}" = "grpc" ]; then
		local mt="false"
		[ "${grpc_mode}" = "multi" ] && mt="true"
		grpc_block=$(jq -n --arg sn "${grpc_service}" --argjson mt "${mt}" --arg auth "${grpc_authority}" '
			{
				serviceName: $sn,
				multiMode: $mt,
				authority: $auth
			} | with_entries(select(.value != null and .value != ""))
		')
	fi

	if [ "${security}" = "tls" ]; then
		local alpn_arr="[]"
		if [ "${alpn_h2}" = "1" ] && [ "${alpn_http}" = "1" ]; then
			alpn_arr='["h2","http/1.1"]'
		elif [ "${alpn_h2}" = "1" ]; then
			alpn_arr='["h2"]'
		elif [ "${alpn_http}" = "1" ]; then
			alpn_arr='["http/1.1"]'
		fi
		# allowInsecure removed by Xray (2026.x); use pinnedPeerCertSha256/verifyPeerCertByName (FORK doge.14)
		local pcs vcn
		pcs=$(fss_get_node_field_plain "${id}" "xray_pcs" 2>/dev/null)
		vcn=$(fss_get_node_field_plain "${id}" "xray_vcn" 2>/dev/null)
		tls_block=$(jq -n --arg sni "${sni}" --arg pcs "${pcs}" --arg vcn "${vcn}" --argjson alpn "${alpn_arr}" '
			{
				serverName: $sni,
				pinnedPeerCertSha256: $pcs,
				verifyPeerCertByName: $vcn,
				alpn: (if ($alpn|length) == 0 then null else $alpn end)
			} | with_entries(select(.value != null and .value != ""))
		')
	fi

	jq -n \
		--arg net "${network}" \
		--arg sec "${security}" \
		--argjson ws "${ws_block}" \
		--argjson tls "${tls_block}" \
		--argjson gr "${grpc_block}" '
		{
			network: $net,
			security: $sec,
			tlsSettings: $tls,
			wsSettings: $ws,
			grpcSettings: $gr
		} | with_entries(select(.value != null))
	'
}

# 主入口：构建前置节点的 outbound JSON（单个对象）
# 失败返回非 0，stdout 为空。
#
# doge.13: 节点 outbound 构建逻辑拆到 ss_split_node_outbound.sh,本函数改为 wrapper
# 以保持向后兼容。新代码请直接调用 fss_split_build_node_outbound_json。
#
# 历史签名:fss_chain_build_front_outbound_json <id>  → stdout
# 新版改用临时文件中转(busybox 路由器 /dev/stdout 不可靠,见 CLAUDE.md 硬规则 #16)。
fss_chain_build_front_outbound_json() {
	local id="$1"
	[ -n "${id}" ] || return 1

	if ! type fss_split_build_node_outbound_json >/dev/null 2>&1; then
		# 防御:若拆分文件未 source(理论上不会发生,见本文件末尾 source 段),回退报错
		fss_chain_log "fss_split_build_node_outbound_json 未定义,ss_split_node_outbound.sh 缺失?"
		return 1
	fi

	local tmp="/tmp/fss_chain_front_ob.$$.json"
	fss_split_build_node_outbound_json "${id}" "${FSS_CHAIN_FRONT_TAG}" "${tmp}" || {
		rm -f "${tmp}"
		return 1
	}
	cat "${tmp}"
	rm -f "${tmp}"
	return 0
}

# 主入口：把链式代理叠加进 xray 配置文件
# 用法: fss_chain_apply <xray.json>
# 返回 0 即使没启用（无操作），返回非 0 表示出现错误。
fss_chain_apply() {
	local xray_json="${1:-/koolshare/ss/xray.json}"
	# 默认置为直连状态；后续按情况覆盖
	fss_chain_set_status "disabled" ""
	[ -f "${xray_json}" ] || return 0

	local front_id
	front_id=$(fss_chain_get_front_id)
	[ -n "${front_id}" ] || return 0

	# doge.14: 老 mode=7 (节点分流) 已退役，原先的链式代理 fallback 分支整段删除。

	# 防御：不与落地节点相同
	local landing_id=""
	if type fss_get_current_node_id >/dev/null 2>&1; then
		landing_id=$(fss_get_current_node_id 2>/dev/null)
	fi
	[ -n "${landing_id}" ] || landing_id=$(dbus get ssconf_basic_node 2>/dev/null)
	if [ -n "${landing_id}" ] && [ "${landing_id}" = "${front_id}" ]; then
		fss_chain_log "前置节点与落地节点相同，已跳过链式代理"
		fss_chain_set_status "fallback" ""
		return 0
	fi

	# 校验落地节点协议
	local landing_type="${ss_basic_type}"
	[ -n "${landing_type}" ] || landing_type=$(dbus get ss_basic_type 2>/dev/null)
	case "${landing_type}" in
	0|3|4|5|8) ;;
	*)
		fss_chain_log "落地节点协议(type=${landing_type})不在 SS/VMess/VLess/Trojan/HY2 范围，已跳过链式代理"
		fss_chain_set_status "fallback" ""
		return 0
		;;
	esac
	if ! fss_chain_type_supported "${landing_type}" "${landing_id}"; then
		fss_chain_log "落地节点不满足链式代理约束（如使用了 obfs / json 自定义 / 复杂插件），已跳过"
		fss_chain_set_status "fallback" ""
		return 0
	fi

	# 校验前置节点
	local front_type
	front_type=$(fss_get_node_field_plain "${front_id}" "type" 2>/dev/null)
	case "${front_type}" in
	0|3|4|5|8) ;;
	*)
		fss_chain_log "前置节点协议(type=${front_type})不在 SS/VMess/VLess/Trojan/HY2 范围，已跳过链式代理"
		fss_chain_set_status "fallback" ""
		return 0
		;;
	esac
	if ! fss_chain_type_supported "${front_type}" "${front_id}"; then
		fss_chain_log "前置节点不满足链式代理约束（如使用了 obfs / json 自定义 / 复杂插件），已跳过"
		fss_chain_set_status "fallback" ""
		return 0
	fi

	# 构建前置 outbound
	local front_ob
	front_ob=$(fss_chain_build_front_outbound_json "${front_id}") || {
		fss_chain_log "前置节点 outbound 构建失败，已跳过链式代理"
		fss_chain_set_status "fallback" ""
		return 0
	}
	[ -n "${front_ob}" ] || { fss_chain_set_status "fallback" ""; return 0; }

	fss_chain_log "启用链式代理：前置节点=${front_id}(type=${front_type}) 落地节点=${landing_id}(type=${landing_type})"

	# 注入到 xray.json：
	#   1. .outbounds[0].streamSettings.sockopt.dialerProxy = "proxy_front"
	#   2. .outbounds += [front_ob]
	local tmp="/tmp/fss_chain_xray.$$.json"
	jq --argjson fb "${front_ob}" --arg ftag "${FSS_CHAIN_FRONT_TAG}" '
		# 确保第一个 outbound 有 streamSettings.sockopt.dialerProxy
		.outbounds[0].streamSettings = (.outbounds[0].streamSettings // {})
		| .outbounds[0].streamSettings.sockopt = ((.outbounds[0].streamSettings.sockopt // {}) + {dialerProxy: $ftag})
		| .outbounds += [$fb]
	' "${xray_json}" > "${tmp}" 2>/dev/null
	if [ ! -s "${tmp}" ]; then
		fss_chain_log "jq 注入链式 outbound 失败，跳过链式代理"
		rm -f "${tmp}"
		fss_chain_set_status "fallback" ""
		return 0
	fi
	mv -f "${tmp}" "${xray_json}"

	# 重新校验配置
	if [ -x /koolshare/bin/xray ]; then
		# FORK doge.14-beta.11: 自检必须注入 XRAY_LOCATION_ASSET（同 ssconfig.sh:4884/4958）。
		# beta.8 起内置大表规则改发 geosite:cn/geoip:cn 共享引用，xray.json 含 geo 引用；
		# 本自检（链式注入后重新校验）若不带 asset 目录，xray 找不到 geosite.dat →
		# "failed to load geosite: CN" → 自检失败 → 误判链式配置坏 → 回滚 → 链式代理永远 fallback。
		# 见 CLAUDE.md #26 坑①（env -i 会吃掉 export，必须写进同一行）。
		if ! XRAY_LOCATION_ASSET="${SS_XRAY_ASSET_DIR:-/koolshare/ss/rules_ng2/dat}" /koolshare/bin/xray run -test -config="${xray_json}" >/tmp/fss_chain_test.log 2>&1; then
			fss_chain_log "链式代理配置 xray 自检失败：$(cat /tmp/fss_chain_test.log 2>/dev/null | tr '\n' ' ' | head -c 500)"
			# 失败时回滚到无链式版本：移除 dialerProxy + 删除附加 outbound
			tmp="/tmp/fss_chain_rollback.$$.json"
			jq --arg ftag "${FSS_CHAIN_FRONT_TAG}" '
				.outbounds = [ .outbounds[] | select(.tag != $ftag) ]
				| if (.outbounds[0].streamSettings.sockopt.dialerProxy // "") == $ftag then
					del(.outbounds[0].streamSettings.sockopt.dialerProxy)
				  else . end
			' "${xray_json}" > "${tmp}" 2>/dev/null
			if [ -s "${tmp}" ]; then
				mv -f "${tmp}" "${xray_json}"
				fss_chain_log "已回滚到非链式配置"
			else
				rm -f "${tmp}"
			fi
			fss_chain_set_status "fallback" ""
			return 1
		fi
	fi

	# 全部成功，写入 enabled 状态和路径
	local front_name landing_name path
	front_name=$(fss_get_node_field_plain "${front_id}" "name" 2>/dev/null)
	landing_name=$(fss_get_node_field_plain "${landing_id}" "name" 2>/dev/null)
	[ -n "${front_name}" ] || front_name="节点${front_id}"
	[ -n "${landing_name}" ] || landing_name="节点${landing_id}"
	path="${front_name} → ${landing_name} → 目标"
	fss_chain_set_status "enabled" "${path}"
	return 0
}

# doge.13: source 节点 outbound 构建器(必须在所有 helper 定义之后,因为新文件函数依赖
# fss_chain_log / fss_chain_type_supported / fss_chain_bool_json / fss_chain_build_stream_settings)。
# ssconfig.sh 在第 10 行 source 本文件后即可直接调用 fss_split_build_node_outbound_json。
[ -f "${KSROOT}/scripts/ss_split_node_outbound.sh" ] && . "${KSROOT}/scripts/ss_split_node_outbound.sh"
