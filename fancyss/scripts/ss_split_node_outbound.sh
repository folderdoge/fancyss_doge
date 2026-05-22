#!/bin/sh

# fancyss fork doge.13 — split V2 节点 outbound 构建器
# 从 ss_chain_proxy.sh 拆出,通用化节点 ID → outbound JSON 转换。
# 由 ssconfig.sh::generate_xray_json_split 在解除 out_main collapse 后调用,
# 为每个非主节点 (out_node_X) 或跨节点 chain (out_chain_Y_X) 构建独立 outbound。
# 主节点链式 (proxy_front 通过 fss_chain_apply) 不变,在 ss_chain_proxy.sh 内继续处理。
#
# 设计文档:
#   doc/implementation/split-routing-implementation.md §6.2 D12 (sentinel + collapse 解除)
#
# 支持协议(与 ss_chain_proxy.sh 历史口径一致):
#   type=0 (SS, 不含 obfs)
#   type=3 (VMess, 不使用 json 自定义 outbound)
#   type=4 (Xray Vless/Vmess, 不使用 json)
#   type=5 (Trojan, 不使用 obfs-local plugin)
#   type=8 (Hysteria2, 不含 obfs / 端口跳跃)
#
# 仅支持 transport: tcp / ws / grpc。security: none / tls。
# 其他场景视为不支持,返回 1。
#
# 依赖:
#   ss_node_common.sh 提供 fss_get_node_field_plain
#   ss_chain_proxy.sh 提供 fss_chain_type_supported / fss_chain_log /
#                          fss_chain_bool_json / fss_chain_build_stream_settings
# 调用方需先 source 上述两个文件(本文件不再重复 source 以避免循环依赖)。

# 主入口:构建任意节点的 outbound JSON(单个对象),写入指定 outfile。
# 用法: fss_split_build_node_outbound_json <node_id> <out_tag> <outfile> [dialer_tag]
#   <node_id>    - 节点 ID(整数,字段读 ssconf_basic_node_<id>_*)
#   <out_tag>    - outbound tag(如 "proxy_front" / "out_node_3" / "out_chain_2_5")
#   <outfile>    - 输出文件路径(必传,内容为单个 JSON 对象)
#   [dialer_tag] - 可选,非空时注入 streamSettings.sockopt.dialerProxy=<dialer_tag>
#                  用于 chain landing(out_chain_Y_X)指向前置 outbound (chain_front_Y)
# 返回 0 = 成功,非 0 = 失败(outfile 可能未写)
#
# 注意:CLAUDE.md 硬规则 #16 — outfile 必传,缺失即 return 1。
# busybox 路由器 /dev/stdout 不存在,不能默认走标准输出(会被当物理文件污染 /dev/)。
fss_split_build_node_outbound_json() {
	local id="$1"
	local out_tag="$2"
	local outfile="$3"
	local dialer_tag="$4"
	[ -n "${id}" ] || return 1
	[ -n "${out_tag}" ] || return 1
	if [ -z "${outfile}" ]; then
		fss_chain_log "fss_split_build_node_outbound_json: outfile required"
		return 1
	fi

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
			--arg tag "${out_tag}" \
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
			fss_chain_log "节点 ${id} 使用了未支持的传输协议: ${network}(仅支持 tcp/ws/grpc)"
			return 1
			;;
		esac
		local stream_security
		stream_security=$(fss_get_node_field_plain "${id}" "v2ray_network_security" 2>/dev/null); stream_security=${stream_security:-none}

		local stream
		stream=$(fss_chain_build_stream_settings "${id}" "${network}" "${stream_security}" "${host}" "${path}" "${sni}" "${ai}" "${alpn_h2}" "${alpn_http}" "${grpc_mode}" "${grpc_authority}" "${grpc_service}") || return 1

		outbound=$(jq -n \
			--arg tag "${out_tag}" \
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
			fss_chain_log "节点 ${id} 使用了未支持的传输协议: ${network}(仅支持 tcp/ws/grpc)"
			return 1
			;;
		esac
		case "${stream_security}" in none|tls) ;; *)
			fss_chain_log "节点 ${id} 使用了未支持的安全模式: ${stream_security}(仅支持 none/tls)"
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
			--arg tag "${out_tag}" \
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
			--arg tag "${out_tag}" \
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
	8)
		# Hysteria2:xray 原生 outbound,network=hysteria(QUIC over UDP)
		# 字段:hy2_pass / hy2_sni / hy2_ai / hy2_pcs / hy2_vcn
		local hy2_pass hy2_sni hy2_ai hy2_pcs hy2_vcn
		hy2_pass=$(fss_get_node_field_plain "${id}" "hy2_pass" 2>/dev/null)
		hy2_sni=$(fss_get_node_field_plain "${id}" "hy2_sni" 2>/dev/null)
		hy2_ai=$(fss_get_node_field_plain "${id}" "hy2_ai" 2>/dev/null)
		hy2_pcs=$(fss_get_node_field_plain "${id}" "hy2_pcs" 2>/dev/null)
		hy2_vcn=$(fss_get_node_field_plain "${id}" "hy2_vcn" 2>/dev/null)

		# SNI 默认值:跟 ssconfig.sh 4825-4834 行的逻辑保持一致 —— sni 空时用 server(除非 server 是 IP)
		if [ -z "${hy2_sni}" ]; then
			case "${server}" in
			*[a-zA-Z]*) hy2_sni="${server}" ;;
			esac
		fi

		local tls_block
		if [ "${hy2_ai}" = "1" ]; then
			tls_block=$(jq -n --arg sni "${hy2_sni}" '
				{serverName: $sni, allowInsecure: true, alpn: ["h3"]}
				| with_entries(select(.value != null and .value != ""))
			')
		else
			tls_block=$(jq -n --arg sni "${hy2_sni}" --arg pcs "${hy2_pcs}" --arg vcn "${hy2_vcn}" '
				{serverName: $sni, pinnedPeerCertSha256: $pcs, verifyPeerCertByName: $vcn, alpn: ["h3"]}
				| with_entries(select(.value != null and .value != ""))
			')
		fi

		outbound=$(jq -n \
			--arg tag "${out_tag}" \
			--arg srv "${server}" --argjson port "${port}" \
			--arg pwd "${hy2_pass}" \
			--argjson tls "${tls_block}" '
			{
				tag: $tag,
				protocol: "hysteria",
				settings: {version: 2, address: $srv, port: $port},
				streamSettings: {
					network: "hysteria",
					hysteriaSettings: {version: 2, auth: $pwd},
					security: "tls",
					tlsSettings: $tls
				}
			}
		') || return 1
		;;
	*)
		return 1
		;;
	esac

	# strip null/empty,写入 outfile
	# dialer_tag 非空 → 注入 streamSettings.sockopt.dialerProxy(chain landing 用)
	# 注意:SS (type=0) 历史口径无 streamSettings,jq 必须先建空对象再 merge
	if [ -n "${dialer_tag}" ]; then
		printf '%s' "${outbound}" | jq --arg dt "${dialer_tag}" '
			.streamSettings = (.streamSettings // {})
			| .streamSettings.sockopt = ((.streamSettings.sockopt // {}) + {dialerProxy: $dt})
			| del(.. | nulls)
		' > "${outfile}" 2>/dev/null
	else
		printf '%s' "${outbound}" | jq 'del(.. | nulls)' > "${outfile}" 2>/dev/null
	fi
	[ -s "${outfile}" ] || return 1
	return 0
}
