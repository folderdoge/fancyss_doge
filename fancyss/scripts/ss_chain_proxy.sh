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
		tls_block=$(jq -n --arg sni "${sni}" --argjson ai "$(fss_chain_bool_json "${ai}")" --argjson alpn "${alpn_arr}" '
			{
				serverName: $sni,
				allowInsecure: $ai,
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
fss_chain_build_front_outbound_json() {
	local id="$1"
	[ -n "${id}" ] || return 1

	local type
	type=$(fss_get_node_field_plain "${id}" "type" 2>/dev/null)
	[ -n "${type}" ] || return 1
	if ! fss_chain_type_supported "${type}" "${id}"; then
		return 1
	fi

	local server port
	server=$(fss_get_node_field_plain "${id}" "server" 2>/dev/null)
	port=$(fss_get_node_field_plain "${id}" "port" 2>/dev/null)
	[ -n "${server}" ] || return 1
	[ -n "${port}" ] || return 1

	local outbound=""
	case "${type}" in
	0)
		# SS no-obfs
		local password method
		password=$(fss_get_node_field_plain "${id}" "password" 2>/dev/null)
		method=$(fss_get_node_field_plain "${id}" "method" 2>/dev/null)
		outbound=$(jq -n \
			--arg tag "${FSS_CHAIN_FRONT_TAG}" \
			--arg srv "${server}" --argjson port "${port}" \
			--arg pwd "${password}" --arg method "${method}" '
			{
				tag: $tag,
				protocol: "shadowsocks",
				settings: {servers: [{address: $srv, port: $port, password: $pwd, method: $method, uot: true}]}
			}
		') || return 1
		;;
	3)
		local uuid alterid security network host path sni ai alpn_h2 alpn_http grpc_mode grpc_authority grpc_service
		uuid=$(fss_get_node_field_plain "${id}" "v2ray_uuid" 2>/dev/null)
		alterid=$(fss_get_node_field_plain "${id}" "v2ray_alterid" 2>/dev/null); alterid=${alterid:-0}
		security=$(fss_get_node_field_plain "${id}" "v2ray_security" 2>/dev/null); security=${security:-auto}
		network=$(fss_get_node_field_plain "${id}" "v2ray_network" 2>/dev/null); network=${network:-tcp}
		host=$(fss_get_node_field_plain "${id}" "v2ray_network_host" 2>/dev/null)
		path=$(fss_get_node_field_plain "${id}" "v2ray_network_path" 2>/dev/null)
		sni=$(fss_get_node_field_plain "${id}" "v2ray_network_security_sni" 2>/dev/null)
		ai=$(fss_get_node_field_plain "${id}" "v2ray_network_security_ai" 2>/dev/null)
		alpn_h2=$(fss_get_node_field_plain "${id}" "v2ray_network_security_alpn_h2" 2>/dev/null)
		alpn_http=$(fss_get_node_field_plain "${id}" "v2ray_network_security_alpn_http" 2>/dev/null)
		grpc_mode=$(fss_get_node_field_plain "${id}" "v2ray_grpc_mode" 2>/dev/null)
		grpc_authority=$(fss_get_node_field_plain "${id}" "v2ray_grpc_authority" 2>/dev/null)
		grpc_service="${path}"

		case "${network}" in tcp|ws|grpc) ;; *)
			fss_chain_log "前置节点 ${id} 使用了未支持的传输协议: ${network}（仅支持 tcp/ws/grpc）"
			return 1
			;;
		esac
		local stream_security
		stream_security=$(fss_get_node_field_plain "${id}" "v2ray_network_security" 2>/dev/null); stream_security=${stream_security:-none}

		local stream
		stream=$(fss_chain_build_stream_settings "${id}" "${network}" "${stream_security}" "${host}" "${path}" "${sni}" "${ai}" "${alpn_h2}" "${alpn_http}" "${grpc_mode}" "${grpc_authority}" "${grpc_service}") || return 1

		outbound=$(jq -n \
			--arg tag "${FSS_CHAIN_FRONT_TAG}" \
			--arg srv "${server}" --argjson port "${port}" \
			--arg uuid "${uuid}" --argjson aid "${alterid}" --arg sec "${security}" \
			--argjson stream "${stream}" '
			{
				tag: $tag,
				protocol: "vmess",
				settings: {vnext: [{address: $srv, port: $port, users: [{id: $uuid, alterId: $aid, security: $sec}]}]},
				streamSettings: $stream
			}
		') || return 1
		;;
	4)
		local prot uuid encryption flow network host path sni ai stream_security alpn_h2 alpn_http grpc_mode grpc_authority grpc_service
		prot=$(fss_get_node_field_plain "${id}" "xray_prot" 2>/dev/null); prot=${prot:-vless}
		uuid=$(fss_get_node_field_plain "${id}" "xray_uuid" 2>/dev/null)
		encryption=$(fss_get_node_field_plain "${id}" "xray_encryption" 2>/dev/null)
		flow=$(fss_get_node_field_plain "${id}" "xray_flow" 2>/dev/null)
		network=$(fss_get_node_field_plain "${id}" "xray_network" 2>/dev/null); network=${network:-tcp}
		host=$(fss_get_node_field_plain "${id}" "xray_network_host" 2>/dev/null)
		path=$(fss_get_node_field_plain "${id}" "xray_network_path" 2>/dev/null)
		sni=$(fss_get_node_field_plain "${id}" "xray_network_security_sni" 2>/dev/null)
		ai=$(fss_get_node_field_plain "${id}" "xray_network_security_ai" 2>/dev/null)
		alpn_h2=$(fss_get_node_field_plain "${id}" "xray_network_security_alpn_h2" 2>/dev/null)
		alpn_http=$(fss_get_node_field_plain "${id}" "xray_network_security_alpn_http" 2>/dev/null)
		grpc_mode=$(fss_get_node_field_plain "${id}" "xray_grpc_mode" 2>/dev/null)
		grpc_authority=$(fss_get_node_field_plain "${id}" "xray_grpc_authority" 2>/dev/null)
		grpc_service="${path}"
		stream_security=$(fss_get_node_field_plain "${id}" "xray_network_security" 2>/dev/null); stream_security=${stream_security:-none}

		case "${network}" in tcp|ws|grpc) ;; *)
			fss_chain_log "前置节点 ${id} 使用了未支持的传输协议: ${network}（仅支持 tcp/ws/grpc）"
			return 1
			;;
		esac
		case "${stream_security}" in none|tls) ;; *)
			fss_chain_log "前置节点 ${id} 使用了未支持的安全模式: ${stream_security}（仅支持 none/tls）"
			return 1
			;;
		esac

		local stream
		stream=$(fss_chain_build_stream_settings "${id}" "${network}" "${stream_security}" "${host}" "${path}" "${sni}" "${ai}" "${alpn_h2}" "${alpn_http}" "${grpc_mode}" "${grpc_authority}" "${grpc_service}") || return 1

		local user_block
		if [ "${prot}" = "vless" ]; then
			user_block=$(jq -n --arg uuid "${uuid}" --arg enc "${encryption:-none}" --arg fl "${flow}" '
				{id: $uuid, encryption: $enc, flow: (if $fl == "" then null else $fl end)}
				| with_entries(select(.value != null))
			')
		else
			[ -z "${encryption}" ] || [ "${encryption}" = "none" ] && encryption="auto"
			user_block=$(jq -n --arg uuid "${uuid}" --arg sec "${encryption}" '
				{id: $uuid, security: $sec}
			')
		fi

		outbound=$(jq -n \
			--arg tag "${FSS_CHAIN_FRONT_TAG}" \
			--arg prot "${prot}" \
			--arg srv "${server}" --argjson port "${port}" \
			--argjson user "${user_block}" \
			--argjson stream "${stream}" '
			{
				tag: $tag,
				protocol: $prot,
				settings: {vnext: [{address: $srv, port: $port, users: [$user]}]},
				streamSettings: $stream
			}
		') || return 1
		;;
	5)
		local trojan_uuid sni ai
		trojan_uuid=$(fss_get_node_field_plain "${id}" "trojan_uuid" 2>/dev/null)
		sni=$(fss_get_node_field_plain "${id}" "trojan_sni" 2>/dev/null)
		ai=$(fss_get_node_field_plain "${id}" "trojan_ai" 2>/dev/null)

		local tls_block
		tls_block=$(jq -n --arg sni "${sni}" --argjson ai "$(fss_chain_bool_json "${ai}")" '
			{serverName: $sni, allowInsecure: $ai} | with_entries(select(.value != null and .value != ""))
		')

		outbound=$(jq -n \
			--arg tag "${FSS_CHAIN_FRONT_TAG}" \
			--arg srv "${server}" --argjson port "${port}" \
			--arg pwd "${trojan_uuid}" \
			--argjson tls "${tls_block}" '
			{
				tag: $tag,
				protocol: "trojan",
				settings: {servers: [{address: $srv, port: $port, password: $pwd}]},
				streamSettings: {network: "tcp", security: "tls", tlsSettings: $tls}
			}
		') || return 1
		;;
	*)
		return 1
		;;
	esac

	# strip null/empty
	printf '%s' "${outbound}" | jq 'del(.. | nulls)'
}

# 主入口：把链式代理叠加进 xray 配置文件
# 用法: fss_chain_apply <xray.json>
# 返回 0 即使没启用（无操作），返回非 0 表示出现错误。
fss_chain_apply() {
	local xray_json="${1:-/koolshare/ss/xray.json}"
	[ -f "${xray_json}" ] || return 0

	local front_id
	front_id=$(fss_chain_get_front_id)
	[ -n "${front_id}" ] || return 0

	# 当前主模式是分流模式（7）时，本版不支持链式
	local main_mode
	main_mode=$(dbus get ss_basic_mode 2>/dev/null)
	if [ "${main_mode}" = "7" ]; then
		fss_chain_log "当前为 xray 分流模式，链式代理本版本暂不支持，已跳过"
		return 0
	fi

	# 防御：不与落地节点相同
	local landing_id=""
	if type fss_get_current_node_id >/dev/null 2>&1; then
		landing_id=$(fss_get_current_node_id 2>/dev/null)
	fi
	[ -n "${landing_id}" ] || landing_id=$(dbus get ssconf_basic_node 2>/dev/null)
	if [ -n "${landing_id}" ] && [ "${landing_id}" = "${front_id}" ]; then
		fss_chain_log "前置节点与落地节点相同，已跳过链式代理"
		return 0
	fi

	# 校验落地节点协议
	local landing_type="${ss_basic_type}"
	[ -n "${landing_type}" ] || landing_type=$(dbus get ss_basic_type 2>/dev/null)
	case "${landing_type}" in
	0|3|4|5) ;;
	*)
		fss_chain_log "落地节点协议(type=${landing_type})不在 SS/VMess/VLess/Trojan 范围，已跳过链式代理"
		return 0
		;;
	esac
	if ! fss_chain_type_supported "${landing_type}" "${landing_id}"; then
		fss_chain_log "落地节点不满足链式代理约束（如使用了 obfs / json 自定义 / 复杂插件），已跳过"
		return 0
	fi

	# 校验前置节点
	local front_type
	front_type=$(fss_get_node_field_plain "${front_id}" "type" 2>/dev/null)
	case "${front_type}" in
	0|3|4|5) ;;
	*)
		fss_chain_log "前置节点协议(type=${front_type})不在 SS/VMess/VLess/Trojan 范围，已跳过链式代理"
		return 0
		;;
	esac
	if ! fss_chain_type_supported "${front_type}" "${front_id}"; then
		fss_chain_log "前置节点不满足链式代理约束（如使用了 obfs / json 自定义 / 复杂插件），已跳过"
		return 0
	fi

	# 构建前置 outbound
	local front_ob
	front_ob=$(fss_chain_build_front_outbound_json "${front_id}") || {
		fss_chain_log "前置节点 outbound 构建失败，已跳过链式代理"
		return 0
	}
	[ -n "${front_ob}" ] || return 0

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
		return 0
	fi
	mv -f "${tmp}" "${xray_json}"

	# 重新校验配置
	if [ -x /koolshare/bin/xray ]; then
		if ! /koolshare/bin/xray run -test -config="${xray_json}" >/tmp/fss_chain_test.log 2>&1; then
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
			return 1
		fi
	fi

	return 0
}
