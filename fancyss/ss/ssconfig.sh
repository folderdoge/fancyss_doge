#!/bin/sh

# fancyss script for asuswrt/merlin based router with software center

export FSS_BASE_EAGER_NODE_ENV=0
export FSS_BASE_SKIP_SHUNT_SOURCE=1
source /koolshare/scripts/ss_base.sh
unset FSS_BASE_EAGER_NODE_ENV
unset FSS_BASE_SKIP_SHUNT_SOURCE
[ -f /koolshare/scripts/ss_chain_proxy.sh ] && . /koolshare/scripts/ss_chain_proxy.sh
# doge.13 beta: 分流多落地 outbound 构建 helper（解除 alpha collapse → out_main 兜底）
# 提供函数 fss_split_build_node_outbound_json <node_id> <out_tag> <outfile>
# 与 Impl-ss_split_node_outbound.sh subagent 协同；未部署时 generate_xray_json_split
# 内有 graceful fallback（仍走 out_main 兜底，不会让 ssconfig.sh restart 挂掉）。
[ -f /koolshare/scripts/ss_split_node_outbound.sh ] && . /koolshare/scripts/ss_split_node_outbound.sh
NEW_PATH=$(echo $PATH|tr ':' '\n'|sed '/opt/d;/mmc/d'|awk '!a[$0]++'|tr '\n' ':'|sed '$ s/:$//')
export PATH=${NEW_PATH}
#-----------------------------------------------
# Variable definitions
THREAD=""
LOG_FILE=/tmp/upload/ss_log.txt
CONFIG_FILE=/koolshare/ss/ssr.json
LOCK_FILE=/var/lock/koolss.lock
WS_PIDFILE=/var/run/fancyss-websocketd.pid
DNSC_PORT=53
ISP_DNS1=""
ISP_DNS2=""
lan_ipaddr=""
ip_prefix_hex=""
WAN_ACTION=""
NAT_ACTION=""
WEB_ACTION=""
ARG_OBFS=""
OUTBOUNDS="[]"
LINUX_VER=$(uname -r|awk -F"." '{print $1$2}')

# 分流架构 per-Mode TPROXY/REDIRECT 端口基址（详见 split-routing-architecture.md §5.1）
SS_SPLIT_PORT_BASE="13333"
# 双轨 chinadns-ng 实例端口（详见 split-routing-architecture.md §6.2）
SS_SPLIT_DNS_SPLIT_PORT="65353"
SS_SPLIT_DNS_GLOBAL_PORT="65354"
# doge.13 beta D5 兑现：起独立 dnsmasq 子实例占该端口（方案 C-2），
# 主 dnsmasq (port=53) 不动；chinadns split/global 两实例的 group lan
# 把 *.lan / *.local / <asusrouter> 等查询投递到 127.0.0.1:65355 → 这个
# dnsmasq 子实例 → 读 /etc/hosts 给出真实 LAN IP。
# 启停 hook 见 start_dnsmasq_lan_listener / stop_dnsmasq_lan_listener。
SS_SPLIT_DNS_LAN_PORT="65355"

#-----------------------------------------------

set_lock() {
	exec 1000>"$LOCK_FILE"
	flock -x 1000
}

unset_lock() {
	flock -u 1000
	rm -rf "$LOCK_FILE"
}

refresh_runtime_context() {
	[ -n "${THREAD}" ] || THREAD=$(grep -c '^processor' /proc/cpuinfo)
	dbus set ss_basic_version_local=$(cat /koolshare/ss/version)
	ISP_DNS1=$(nvram get wan0_dns | sed 's/ /\n/g' | grep -v 0.0.0.0 | grep -v 127.0.0.1 | sed -n 1p | grep -E "([0-9]{1,3}[\.]){3}[0-9]{1,3}|:")
	ISP_DNS2=$(nvram get wan0_dns | sed 's/ /\n/g' | grep -v 0.0.0.0 | grep -v 127.0.0.1 | sed -n 2p | grep -E "([0-9]{1,3}[\.]){3}[0-9]{1,3}|:")
	lan_ipaddr=$(nvram get lan_ipaddr)
	ip_prefix_hex=$(nvram get lan_ipaddr | awk -F "." '{printf ("0x%02x", $1)} {printf ("%02x", $2)} {printf ("%02x", $3)} {printf ("00/0xffffff00\n")}')
	WAN_ACTION=$(ps | grep /jffs/scripts/wan-start | grep -v grep)
	NAT_ACTION=$(ps | grep /jffs/scripts/nat-start | grep -v grep)
	WEB_ACTION=$(ps | grep "ss_config.sh" | grep -v grep)
}

normalize_ss2022_password() {
	[ "${ss_basic_type}" = "0" ] || return 0
	printf '%s' "${ss_basic_method}" | grep -q '^2022-' || return 0
	printf '%s' "${ss_basic_password}" | grep -q ':' && return 0

	local decoded=""
	decoded="$(printf '%s' "${ss_basic_password}" | base64_decode 2>/dev/null)"
	[ -n "${decoded}" ] || return 0
	printf '%s' "${decoded}" | grep -q ':' || return 0

	ss_basic_password="${decoded}"
}

refresh_schema2_secret_fields() {
	local current_node_id=""
	local raw_password=""

	[ "$(fss_detect_storage_schema)" = "2" ] || return 0
	current_node_id="$(fss_get_current_node_id 2>/dev/null)"
	[ -n "${current_node_id}" ] || return 0

	case "${ss_basic_type}" in
	0|1)
		raw_password="$(fss_get_node_field_plain "${current_node_id}" password 2>/dev/null)"
		if [ -n "${raw_password}" ] && [ "${raw_password}" != "${ss_basic_password}" ]; then
			ss_basic_password="${raw_password}"
		fi
		;;
	9)
		raw_password="$(fss_get_node_field_plain "${current_node_id}" anytls_pass 2>/dev/null)"
		if [ -n "${raw_password}" ] && [ "${raw_password}" != "${ss_basic_anytls_pass}" ]; then
			ss_basic_anytls_pass="${raw_password}"
		fi
		;;
	esac
}

get_model_name(){
	local ODMPID=$(nvram get odmpid)
	local PRODUCTID=$(nvram get productid)
	if [ -n "${ODMPID}" ];then
		echo "${ODMPID}"
	else
		echo "${PRODUCTID}"
	fi
}

set_skin(){
	local UI_TYPE=ASUSWRT
	local SC_SKIN=$(nvram get sc_skin)
	local TS_FLAG=$(grep -o "2ED9C3" /www/css/difference.css 2>/dev/null|head -n1)
	local ROG_FLAG=$(cat /www/form_style.css|grep -A1 ".tab_NW:hover{"|grep "background"|sed 's/,//g'|grep -o "2071044")
	local TUF_FLAG=$(cat /www/form_style.css|grep -A1 ".tab_NW:hover{"|grep "background"|sed 's/,//g'|grep -o "D0982C")
	local WRT_FLAG=$(cat /www/form_style.css|grep -A1 ".tab_NW:hover{"|grep "background"|sed 's/,//g'|grep -o "4F5B5F")
	if [ -n "${TS_FLAG}" ];then
		UI_TYPE="TS"
	else
		if [ -n "${TUF_FLAG}" ];then
			UI_TYPE="TUF"
		fi
		if [ -n "${ROG_FLAG}" ];then
			UI_TYPE="ROG"
		fi
		if [ -n "${WRT_FLAG}" ];then
			UI_TYPE="ASUSWRT"
		fi
	fi
	if [ -z "${SC_SKIN}" -o "${SC_SKIN}" != "${UI_TYPE}" ];then
		nvram set sc_skin="${UI_TYPE}"
		nvram commit
	fi
}

get_time(){
	local src=$1
	local debug=$2
	# Automatically Updates System Time According to the NIST Atomic Clock in a Linux Environment
	nistTime=$(run curl-fancyss -4skI --connect-timeout 2 --max-time 2 "${src}" | grep "Date")
	if [ -z "${nistTime}" ]; then
		return 1
	fi
	dateString=$(echo $nistTime | cut -d' ' -f2-7)
	dayString=$(echo $nistTime | cut -d' ' -f2-2)
	dateValue=$(echo $nistTime | cut -d' ' -f3-3)
	monthValue=$(echo $nistTime | cut -d' ' -f4-4)
	yearValue=$(echo $nistTime | cut -d' ' -f5-5)
	timeValue=$(echo $nistTime | cut -d' ' -f6-6)
	timeZoneValue=$(echo $nistTime | cut -d' ' -f7-7)
	#echo $dateString
		case $monthValue in
			"Jan")
				monthValue="01"
			;;
		"Feb")
			monthValue="02"
			;;
		"Mar")
			monthValue="03"
			;;
		"Apr")
			monthValue="04"
			;;
		"May")
			monthValue="05"
			;;
		"Jun")
			monthValue="06"
			;;
		"Jul")
			monthValue="07"
			;;
		"Aug")
			monthValue="08"
			;;
		"Sep")
			monthValue="09"
			;;
		"Oct")
			monthValue="10"
			;;
		"Nov")
			monthValue="11"
			;;
			"Dec")
				monthValue="12"
				;;
			*)
				return 1
				;;
		esac
	local UTCTIME="$yearValue.$monthValue.$dateValue-$timeValue"
	local SERVER_TIMESTAMP=$(date +%s --utc ${UTCTIME})
	if [ -n "${debug}" ];then
		local ROUTER_TIME=$(date +'%Y-%m-%d %H:%M:%S' -d @${SERVER_TIMESTAMP})
		echo_date "实际时间：${ROUTER_TIME}，来源：${src}"
	else
		echo ${SERVER_TIMESTAMP}
	fi
}

compare_time(){
	local TIMESTAMP_SOURCE=$1
	local SERVER_TIMESTAMP=$2
	local ROUTER_TIMESTAMP=$(date +%s)
	if [ -z "${SERVER_TIMESTAMP}" ];then
		return 1
	fi
	local TIME_DIFF=$((${SERVER_TIMESTAMP} - ${ROUTER_TIMESTAMP}))
	local TIME_DIFF=${TIME_DIFF#-}
	echo_date "实际时间：$(date +'%Y-%m-%d %H:%M:%S' -d @${SERVER_TIMESTAMP})，来源：${TIMESTAMP_SOURCE}"
	echo_date "路由时间：$(date +'%Y-%m-%d %H:%M:%S' -d @${ROUTER_TIMESTAMP})，来源：$(get_model_name)"
	if [ "${TIME_DIFF}" -ge "60" ];then
		echo_date "*路由器时间和实际时间相差${TIME_DIFF}秒，重新设置路由器时间为：$(date +'%Y-%m-%d %H:%M:%S' -d @${SERVER_TIMESTAMP})！"
		date -s @${SERVER_TIMESTAMP} >/dev/null 2>&1
		echo_date "路由器时间更新成功！"
	elif [ "${TIME_DIFF}" -eq "0" ];then
		echo_date "路由器时间和实际时间相同，继续！"
	else
		echo_date "路由器时间和实际时间相差${TIME_DIFF}秒，在允许误差范围60秒内！"
	fi
}

test_xray_conf(){
	#uset _test_ret
	local conf=$1
	echo_date "测试xray配置文件..."
	local test_ret=$(run /koolshare/bin/xray run -config="${conf}" -test 2>&1)
	local ret_1=$(echo "$test_ret" | grep "Configuration OK.")
	local ret_2=$(echo "$test_ret" | grep "does not support fingerprint")
	#local ret_2=$(echo $test_ret | grep "Old version of XTLS does not support fingerprint")
	if [ -n "${ret_1}" ]; then
		# test OK
		_test_ret=${ret_1}
		return 0
	elif [ -n "${ret_2}" ];then
		# fingerprint should be deleted
		_test_ret=${ret_2}
		return 2
	else
		# test faild
		_test_ret=${test_ret}
		return 1
	fi
}

check_time(){
	# 因为vmess代理协议要求本地时间和服务器时间一致才能工作，所以检测下路由器时间是否设置正确
	# 时间检测优先从worldtimeapi.org获取，如果获取成功，能同时得到公网出口ipv4地址
	# 如果所有检测方式用光了还无法获取时间，说明可能是DNS无法获取到解析通造成的
	echo_date "检测路由器本地时间是否正确..."

	# debug use
	# get_time "www.weibo.com" debug
	# get_time "www.baidu.com" debug
	# get_time "www.qq.com" debug
	# get_time "www.taobao.com" debug
	# get_time "www.zhihu.com" debug
	# get_time "www.jd.com" debug
	# get_time "https://nist.time.gov/" debug
	
	# FORK doge.11: 在线 IP/时间检测开关（ss_basic_online_ipcheck=0 时跳过 worldtimeapi）
	# worldtimeapi.org 同时返回 unixtime 和 client_ip；关闭后时间检测自动 fallback 到下面 weibo/baidu/qq/taobao/jd/nist.time.gov（纯时间，不上送 IP）
	# 详见 doc/design/protocol-roadmap.md §7 doge.11 的 G6 条目
	if [ "${ss_basic_online_ipcheck:-1}" = "1" ]; then
		local RET=$(run curl-fancyss -4sk --connect-timeout 2 --max-time 2 "http://worldtimeapi.org/api/timezone/Asia/Shanghai")
		if [ -n "${RET}" ];then
			if [ "${ss_basic_nochnipcheck}" != "1" ];then
				REMOTE_IP_OUT_SRC="worldtimeapi.org"
				REMOTE_IP_OUT=$(echo ${RET}|run jq -r '.client_ip')
			fi
			local TIMESTAMP_SOURCE="worldtimeapi.org"
			local SERVER_TIMESTAMP=$(echo ${RET}|run jq -r '.unixtime')
			if [ "${SERVER_TIMESTAMP}" == "null" ];then
				local SERVER_TIMESTAMP=""
			fi
			compare_time "worldtimeapi.org" ${SERVER_TIMESTAMP}
		fi
	else
		echo_date "ℹ️ 在线 IP/时间检测已关闭（ss_basic_online_ipcheck=0），跳过 worldtimeapi.org"
	fi

	if [ -z "${SERVER_TIMESTAMP}" ];then
		local TIMESTAMP_SOURCE="www.weibo.com"
		local SERVER_TIMESTAMP=$(get_time ${TIMESTAMP_SOURCE})
		compare_time ${TIMESTAMP_SOURCE} ${SERVER_TIMESTAMP}
	fi

	if [ -z "${SERVER_TIMESTAMP}" ];then
		local TIMESTAMP_SOURCE="www.baidu.com"
		local SERVER_TIMESTAMP=$(get_time ${TIMESTAMP_SOURCE})
		compare_time ${TIMESTAMP_SOURCE} ${SERVER_TIMESTAMP}
	fi

	if [ -z "${SERVER_TIMESTAMP}" ];then
		local TIMESTAMP_SOURCE="www.qq.com"
		local SERVER_TIMESTAMP=$(get_time ${TIMESTAMP_SOURCE})
		compare_time ${TIMESTAMP_SOURCE} ${SERVER_TIMESTAMP}
	fi

	if [ -z "${SERVER_TIMESTAMP}" ];then
		local TIMESTAMP_SOURCE="www.taobao.com"
		local SERVER_TIMESTAMP=$(get_time ${TIMESTAMP_SOURCE})
		compare_time ${TIMESTAMP_SOURCE} ${SERVER_TIMESTAMP}
	fi

	if [ -z "${SERVER_TIMESTAMP}" ];then
		local TIMESTAMP_SOURCE="www.jd.com"
		local SERVER_TIMESTAMP=$(get_time ${TIMESTAMP_SOURCE})
		compare_time ${TIMESTAMP_SOURCE} ${SERVER_TIMESTAMP}
	fi

	if [ -z "${SERVER_TIMESTAMP}" ];then
		local TIMESTAMP_SOURCE="https://nist.time.gov/"
		local SERVER_TIMESTAMP=$(get_time ${TIMESTAMP_SOURCE})
		compare_time ${TIMESTAMP_SOURCE} ${SERVER_TIMESTAMP}
	fi

	if [ -z "${SERVER_TIMESTAMP}" ];then
		echo_date "+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"
		echo_date "+            经多种方法尝试，均无法从服务器获取当前实际时间!            +"
		echo_date "+                 这可能是路由器DNS不通造成的!                      +"
		echo_date "+                请尝试更正此问题后重新启动插件!                     +"
		echo_date "+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"
		close_in_five flag
	fi
}

check_internet4(){
	# 开启插件之前必须检查网络，如果网络不通，则插件不予开启
	# 考虑到本插件可能的国外环境用户，最后添加8.8.8.8的检测
	echo_date "➡️ ipv4网络连通性检测..."
	if [ -z "${PING4_RET}" ];then
		local PING4_SRC="223.5.5.5"
		local PING4_RET=$(ping -c 1 -w 1 ${PING4_SRC} 2>/dev/null|tail -n1|awk -F '/' '{print $4}')
	fi
	if [ -z "${PING4_RET}" ];then
		local PING4_SRC="119.29.29.29"
		local PING4_RET=$(ping -c 1 -w 1 ${PING4_SRC} 2>/dev/null|tail -n1|awk -F '/' '{print $4}')
	fi
	if [ -z "${PING4_RET}" ];then
		local PING4_SRC="114.114.114.114"
		local PING4_RET=$(ping -c 1 -w 1 ${PING4_SRC} 2>/dev/null|tail -n1|awk -F '/' '{print $4}')
	fi
	if [ -z "${PING4_RET}" ];then
		local PING4_SRC="1.2.4.8"
		local PING4_RET=$(ping -c 1 -w 1 ${PING4_SRC} 2>/dev/null|tail -n1|awk -F '/' '{print $4}')
	fi
	if [ -z "${PING4_RET}" ];then
		local PING4_SRC="8.8.8.8"
		local PING4_RET=$(ping -c 1 -w 1 ${PING4_SRC} 2>/dev/null|tail -n1|awk -F '/' '{print $4}')
	fi
	if [ -n "${PING4_RET}" ];then
		echo_date "✅️ 检测到路由器可以正常访问ipv4公网，检测源：${PING4_SRC}，延迟：${PING4_RET}s，继续！"
	else
		echo_date "+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"
		echo_date "+               检测到路由器无法正常访问ipv4公网！                     +"
		echo_date "+                 请配置好你的路由器网络后重试！                     +"
		echo_date "+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"
		close_in_five flag
	fi
}

check_internet6(){
	# 开启插件之前必须检查网络，如果网络不通，则插件不予开启
	# 考虑到本插件可能的国外环境用户，最后添加2001:de4::101和2001:4860:4860::8888的检测
	echo_date "➡️ ipv6网络连通性检测..."
	if [ -z "${PING6_RET}" ];then
		local PING6_SRC="2400:3200::1"
		local PING6_RET=$(ping -c 1 -w 1 ${PING6_SRC} 2>/dev/null|tail -n1|awk -F '/' '{print $4}')
	fi
	if [ -z "${PING6_RET}" ];then
		local PING6_SRC="2402:4e00:: 2"
		local PING6_RET=$(ping -c 1 -w 1 ${PING6_SRC} 2>/dev/null|tail -n1|awk -F '/' '{print $4}')
	fi
	if [ -z "${PING6_RET}" ];then
		local PING6_SRC="2400:7fc0:849e:200::8"
		local PING6_RET=$(ping -c 1 -w 1 ${PING6_SRC} 2>/dev/null|tail -n1|awk -F '/' '{print $4}')
	fi
	if [ -z "${PING6_RET}" ];then
		local PING6_SRC="2001:de4::101"
		local PING6_RET=$(ping -c 1 -w 1 ${PING6_SRC} 2>/dev/null|tail -n1|awk -F '/' '{print $4}')
	fi
	if [ -z "${PING6_RET}" ];then
		local PING6_SRC="2001:4860:4860::8888"
		local PING6_RET=$(ping -c 1 -w 1 ${PING6_SRC} 2>/dev/null|tail -n1|awk -F '/' '{print $4}')
	fi
	if [ -n "${PING6_RET}" ];then
		echo_date "✅️ 检测到路由器可以正常访问ipv6公网，检测源：${PING6_SRC}，延迟：${PING6_RET}s，继续！"
		INTERNET6=1
	else
		#echo_date "+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"
		#echo_date "+               检测到路由器无法正常访问ipv6公网！                     +"
		#echo_date "+                 请配置好你的路由器网络后重试！                     +"
		#echo_date "+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"
		INTERNET6=0
	fi
}
check_internet6_pre(){
	# ipv6预检查
	if [ $(nvram get ipv6_service) == "disabled" ];then
		INTERNET6=0
		return 1
	fi

	local ipv6_addr=$(ip addr|grep -A3 -E "eth0|ppp0"|grep "scope global"|grep "inet6"|awk '{print $2}'|awk -F"/" '{print $1}')
	if [ -z "${ipv6_addr}" ];then
		INTERNET6=0
		return 1
	fi

	INTERNET6=1
	
}

check_internet(){
	# 预先检查先ipv6开关和ip地址，用于后面的DNS解析过滤
	check_internet6_pre
	
	if [ "${ss_basic_nonetcheck}" == "1" ];then
		# 用户关闭了连通性检测
		return 1
	fi
	
	check_internet4

	if [ "${INTERNET6}" == "1" ];then
		check_internet6
	fi
}

ipv6_proxy_enabled() {
	[ "${ss_basic_proxy_ipv6}" == "1" ]
}

ipv6_proxy_supported() {
	case "${ss_basic_type}" in
	0|1|3|4|5|6|7|8|9)
		return 0
		;;
	esac

	[ "${ss_basic_v2ray_use_json}" == "1" ] && return 0
	[ "${ss_basic_xray_use_json}" == "1" ] && return 0

	return 1
}

check_ipv6_proxy_prerequisites() {
	ipv6_proxy_enabled || return 0
	echo_date "➡️ IPv6透明代理预检查..."
	if ! ipv6_proxy_supported; then
		echo_date "+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"
		echo_date "+ 当前节点类型暂不支持IPv6透明代理，本次将自动回退到IPv4模式！ +"
		echo_date "+ 并强制开启代理域名IPv6过滤，避免代理域名解析到IPv6后直连。 +"
		echo_date "+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"
		disable_ipv6_proxy_runtime
		echo_date "↪ 已自动关闭IPv6代理开关，回退到纯IPv4代理模式继续运行。"
		return 0
	fi

	if [ "$(nvram get ipv6_service)" == "disabled" ];then
		echo_date "+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"
		echo_date "+ 检测到路由器系统未开启IPv6，请先到【高级设置】-【IPv6】完成配置！ +"
		echo_date "+ 页面路径：/Advanced_IPv6_Content.asp                          +"
		echo_date "+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"
		disable_ipv6_proxy_runtime
		echo_date "↪ 已自动关闭IPv6代理开关，回退到纯IPv4代理模式继续运行。"
		return 0
	fi

	if [ ! -f "/usr/lib/xtables/libip6t_REDIRECT.so" ];then
		echo_date "+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"
		echo_date "+ 当前固件iptables缺少libip6t_REDIRECT扩展，无法启用ipv6代理！ +"
		echo_date "+           请尝试将固件升级到最新版本后再启用此功能！         +"
		echo_date "+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"
		disable_ipv6_proxy_runtime
		echo_date "↪ 已自动关闭IPv6代理开关，回退到纯IPv4代理模式继续运行。"
		return 0
	fi

	check_internet6_pre
	if [ "${INTERNET6}" != "1" ];then
		echo_date "+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"
		echo_date "+ 检测到路由器当前没有可用的IPv6全局地址，无法开启IPv6透明代理！ +"
		echo_date "+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"
		disable_ipv6_proxy_runtime
		echo_date "↪ 已自动关闭IPv6代理开关，回退到纯IPv4代理模式继续运行。"
		return 0
	fi

	check_internet6
	if [ "${INTERNET6}" != "1" ];then
		echo_date "+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"
		echo_date "+ 检测到路由器当前无法正常访问IPv6公网，无法开启IPv6透明代理！ +"
		echo_date "+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"
		disable_ipv6_proxy_runtime
		echo_date "↪ 已自动关闭IPv6代理开关，回退到纯IPv4代理模式继续运行。"
		return 0
	fi

	if ! ip6tables -t nat -L PREROUTING >/dev/null 2>&1; then
		echo_date "错误：当前系统不支持ip6tables nat表，无法开启IPv6透明代理！"
		disable_ipv6_proxy_runtime
		echo_date "↪ 已自动关闭IPv6代理开关，回退到纯IPv4代理模式继续运行。"
		return 0
	fi
	if ! ip6tables -t mangle -L PREROUTING >/dev/null 2>&1; then
		echo_date "错误：当前系统不支持ip6tables mangle表，无法开启IPv6透明代理！"
		disable_ipv6_proxy_runtime
		echo_date "↪ 已自动关闭IPv6代理开关，回退到纯IPv4代理模式继续运行。"
		return 0
	fi
	if ! ip6tables -t filter -L FORWARD >/dev/null 2>&1; then
		echo_date "错误：当前系统不支持ip6tables filter表，无法开启IPv6透明代理！"
		disable_ipv6_proxy_runtime
		echo_date "↪ 已自动关闭IPv6代理开关，回退到纯IPv4代理模式继续运行。"
		return 0
	fi

	echo_date "✅️ IPv6透明代理预检查通过，继续！"
}

sync_dns_ipv6_policy() {
	set_default "ss_basic_dns_plan" "1"
	set_default "ss_basic_chng_ipv6_drop_proxy" "1"
	if [ "${ss_basic_dns_plan}" == "1" ];then
		if ipv6_proxy_enabled; then
			return 0
		fi
		if [ "${ss_basic_chng_ipv6_drop_proxy}" != "1" ];then
			echo_date "⚠️检测到当前使用chinadns-ng且未开启IPv6代理，但【过滤代理】未勾选。"
			echo_date "🔁为避免代理域名解析到IPv6地址后直连访问，本次自动启用【过滤代理】。"
			ss_basic_chng_ipv6_drop_proxy="1"
			dbus set ss_basic_chng_ipv6_drop_proxy="1"
		fi
		return 0
	fi

	if [ "${ss_basic_dns_plan}" == "2" ];then
		if ipv6_proxy_enabled; then
			echo_date "ℹ️检测到当前使用smartdns且已开启IPv6代理，SmartDNS将保留代理域名的AAAA解析。"
		else
			echo_date "ℹ️检测到当前使用smartdns且未开启IPv6代理，SmartDNS将按当前代理模式动态抑制需要代理域名的AAAA解析。"
		fi
	fi
}

check_chn_public_ip(){
	echo_date "检测[公网出口IPV4地址]和[路由器WAN口IPV4地址]..."

	# 5.1 检测路由器公网出口IPV4地址
	if [ -z "${REMOTE_IP_OUT}" -o "${REMOTE_IP_OUT}" == "null" ];then
		REMOTE_IP_OUT="$(nvram get wan0_realip_ip)"
		REMOTE_IP_OUT="$(__valid_ip "${REMOTE_IP_OUT}")"
		REMOTE_IP_OUT_SRC="nvram: wan0_realip_ip"
	fi

	# FORK doge.11: 4 个在线 IP 检测源（ddnsto/clang/akamai/myip）由 ss_basic_online_ipcheck 统一开关
	# 详见 doc/design/protocol-roadmap.md §7 doge.11 的 G6 条目
	if [ -z "${REMOTE_IP_OUT}" ] && [ "${ss_basic_online_ipcheck:-1}" = "1" ];then
		echo_date "↪ 本地未获取到公网出口IPV4，尝试在线检测：ip.ddnsto.com"
		REMOTE_IP_OUT_SRC="http://ip.ddnsto.com"
		REMOTE_IP_OUT=$(detect_ip ${REMOTE_IP_OUT_SRC} 5 0)
	fi

	if [ -z "${REMOTE_IP_OUT}" ] && [ "${ss_basic_online_ipcheck:-1}" = "1" ];then
		echo_date "↪ 切换在线检测源：ip.clang.cn"
		REMOTE_IP_OUT_SRC="https://ip.clang.cn"
		REMOTE_IP_OUT=$(detect_ip ${REMOTE_IP_OUT_SRC} 5 0)
	fi

	if [ -z "${REMOTE_IP_OUT}" ] && [ "${ss_basic_online_ipcheck:-1}" = "1" ];then
		echo_date "↪ 切换在线检测源：whatismyip.akamai.com"
		REMOTE_IP_OUT_SRC="whatismyip.akamai.com"
		REMOTE_IP_OUT=$(detect_ip ${REMOTE_IP_OUT_SRC} 5 0)
	fi

	if [ -z "${REMOTE_IP_OUT}" ] && [ "${ss_basic_online_ipcheck:-1}" = "1" ];then
		echo_date "↪ 切换在线检测源：api.myip.com"
		REMOTE_IP_OUT=$(run curl-fancyss -4sk --connect-timeout 2 http://api.myip.com 2>&1 | grep -v "Terminated" | run jq -r '.ip' | grep -Eo "([0-9]{1,3}[\.]){3}[0-9]{1,3}")
		REMOTE_IP_OUT_SRC="api.myip.com"
	fi

	# FORK doge.11: 开关关闭时跳过"检测失败"警告 + close_in_five（用户主动选择不上送，不算异常）
	if [ -z "${REMOTE_IP_OUT}" ];then
		if [ "${ss_basic_online_ipcheck:-1}" != "1" ];then
			echo_date "ℹ️ 在线 IP 检测已关闭（ss_basic_online_ipcheck=0），跳过公网出口 IP 属地判断"
		else
			echo_date "+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"
			echo_date "+            经多种方法尝试，均无法检测到本机国内出口IP!               +"
			echo_date "+                 这可能是路由器DNS不通造成的!                      +"
			echo_date "+                请尝试更正此问题后重新启动插件！                    +"
			echo_date "+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"
			close_in_five flag
		fi
	fi

	# 5.2 检测路由器WAN口IPV4地址
	if [ -z "${ROUTER_IP_WAN}" ];then
		local ROUTER_IP_WAN=$(nvram get wan0_ipaddr)
		local ROUTER_IP_WAN_SRC="nvram get wan0_ipaddr"
	fi

	if [ -z "${ROUTER_IP_WAN}" ];then
		local ROUTER_IP_WAN=$(ifconfig ppp0|sed -n '2p'|grep -Eo 'inet addr:([0-9]{1,3}[\.]){3}[0-9]{1,3}'|awk -F":" '{print $2}')
		local ROUTER_IP_WAN_SRC="ipconfig ppp0"
	fi

	if [ -z "${ROUTER_IP_WAN}" ];then
		local ROUTER_IP_WAN=$(ip addr show ppp0|grep -w inet|awk '{print $2}'|awk -F "/" '{print $1}')
		local ROUTER_IP_WAN_SRC="ip addr show ppp0"
	fi

	if [ -z "${ROUTER_IP_WAN}" ];then
		local ROUTER_IP_WAN=$(ifconfig eth0|sed -n '2p'|grep -Eo 'inet addr:([0-9]{1,3}[\.]){3}[0-9]{1,3}'|awk -F":" '{print $2}')
		local ROUTER_IP_WAN_SRC="ipconfig eth0"
	fi

	if [ -z "${ROUTER_IP_WAN}" ];then
		local ROUTER_IP_WAN=$(ip addr show eth0|grep -w inet|awk '{print $2}')|awk -F "/" '{print $1}'
		local ROUTER_IP_WAN_SRC="ip addr show eth0"
	fi
	
	if [ -z "${ROUTER_IP_WAN}" ];then
		echo_date "+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"
		echo_date "+             经多种方法尝试，均无法检测到本机WAN口IP!                +"
		echo_date "+                请尝试更正此问题后重新启动插件!                     +"
		echo_date "+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"
		close_in_five flag
	fi
	
	# 5.3 判断
	# FORK doge.11: REMOTE_IP_OUT 为空时（ss_basic_online_ipcheck=0 且 nvram 也没值）跳过属地判断与 5.4 ROUTER==REMOTE 比较，避免输出 "属地：海外" 误导日志
	if [ -n "${REMOTE_IP_OUT}" ];then
		local ISCHN_OUT=$(awk -F'[./]' -v ip=${REMOTE_IP_OUT} '{for (i=1;i<=int($NF/8);i++){a=a$i"."} if (index(ip, a)==1){split( ip, A, ".");b=int($NF/8);if (A[b+1]<($(NF+b-4)+2^(8-$NF%8))&&A[b+1]>=$(NF+b-4)) print ip,"belongs to",$0} a=""}' /koolshare/ss/rules/chnroute.txt)
		if [ -n "${ISCHN_OUT}" ];then
			# 大陆地址
			echo_date "公网出口IPV4地址：${REMOTE_IP_OUT}，属地：大陆，来源：${REMOTE_IP_OUT_SRC}"
		else
			# 海外地址
			# 为日志输出标准，此处属地海外表示的是：中国外且包含港澳台地址，后同，并没有任何分裂国家的表达意思。
			echo_date "公网出口IPV4地址：${REMOTE_IP_OUT}，属地：海外，来源：${REMOTE_IP_OUT_SRC}"
		fi

		if [ "${ROUTER_IP_WAN}" == "${REMOTE_IP_OUT}" ];then
			if [ -z "${ISCHN_OUT}" ];then
				echo_date "路由WAN IPV4地址：${ROUTER_IP_WAN}，和公网出口地址相同，为海外公网IPV4地址！"
				if [ "${ss_basic_mode}" != "6" ];then
					echo_date "检测到路由器公网出口IPV4地址为海外地址，可能是以下情况："
					echo_date "-------------------------------"
					echo_date "1. 检测到路由器使用环境在海外，如果确实是这种情况，建议使用回国代理 + 回国模式"
					echo_date "2. 可能你身在大陆，但是chnroute.txt没有收录你的公网出口IPV4地址，你可以自行将该IPV4地址加入到IP/CIDR黑名单"
					echo_date "-------------------------------"
				fi
			else
				echo_date "路由WAN IPV4地址：${ROUTER_IP_WAN}，和公网出口地址相同，为大陆公网IPV4地址！"
			fi
		else
			echo_date "路由WAN IPV4地址：${ROUTER_IP_WAN}，和公网出口地址不同，为私网（局域网）IPV4地址"
			if [ -z "${ISCHN_OUT}" ];then
				if [ "${ss_basic_mode}" != "6" ];then
					echo_date "检测到路由器公网出口IPV4地址为海外地址，可能是以下情况："
					echo_date "-------------------------------"
					echo_date "1. 可能你身在大陆，但是你的网络经过了多层代理，请检查是否有上游路由器开启了代理，特别是全局代理"
					echo_date "2. 可能你身在海外，如果是这种情况，建议使用回国代理 + 回国模式"
					echo_date "3. 可能你身在大陆，但是chnroute.txt没有收录你的公网出口IPV4地址，你可以自行将该IPV4地址加入到IP/CIDR黑名单"
					echo_date "-------------------------------"
				fi
			fi
		fi
	else
		echo_date "路由WAN IPV4地址：${ROUTER_IP_WAN}（公网出口 IP 未检测，属地判断已跳过）"
	fi
}

prepare_system() {
	# prepare system
	echo_date "🛠️ 一些准备工作，请稍后..."
	echo_date "准备工作：加载当前节点和运行环境..."
	fss_base_load_current_node_env
	refresh_runtime_context
	normalize_ss2022_password
	# Default enabled in UI: block QUIC to avoid HTTP/3 direct-connect bypassing TCP-only proxy.
	set_default "ss_basic_block_quic" "1"
	set_default "ss_basic_proxy_ipv6" "0"
	normalize_server_resolv_mode
	
	# 0. set skin, 不管是否能启动成功，都检测下皮肤是否正确，如果不对，则设置下皮肤
	set_skin
	
	# 1. 检测是否是路由模式，科学上网插件工作方式为透明代理 + NAT（iptables），而非路由模式是没有NAT的，所以无法工作！
	local ROUTER_MODE=$(nvram get sw_mode)
	if [ "$(nvram get sw_mode)" != "1" ]; then
		echo_date "+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"
		echo_date "+          无法启用插件，因为当前路由器工作在非无线路由器模式下          +"
		echo_date "+     科学上网插件工作方式为透明代理，需要在NAT下，即路由模式下才能工作    +"
		echo_date "+            请前往【系统管理】- 【系统设置】去切换路由模式！           +"
		echo_date "+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"
		close_in_five
	fi
	
	# 2. 检测jffs2_script是否开启，如果没有开启，将会影响插件的自启和DNS部分（dnsmasq.postconf）
	# 判断为非官改固件的，即merlin固件，需要开启jffs2_scripts，官改固件不需要开启
	if [ -z "$(nvram get extendno | grep koolshare)" ]; then
		if [ "$(nvram get jffs2_scripts)" != "1" ]; then
			echo_date "+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"
			echo_date "+     发现你未开启Enable JFFS custom scripts and configs选项！     +"
			echo_date "+    【软件中心】和【科学上网】插件都需要此项开启才能正常使用！！         +"
			echo_date "+     请前往【系统管理】- 【系统设置】去开启，并重启路由器后重试！！      +"
			echo_date "+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"
			close_in_five
		fi
	fi

	# 3. use different xtables libdir
	if [ -d "/tmp/.xt" ];then
		export XTABLES_LIBDIR=/tmp/.xt
	fi

	# 兼容，仅chatgpt删除掉了（3.4.13），ss_basic_udpoff和ss_basic_udpall必须有一个等于1
	if [ "${ss_basic_udpoff}" != "1" -a "${ss_basic_udpall}" != "1" ];then
		ss_basic_udpoff=1
		ss_basic_udpall=0
		dbus set ss_basic_udpoff=1
		dbus set ss_basic_udpall=0
	fi
	
	# 检查端口占用情况
	# 3333 3334 23456 7913 1051 1052 1055-1070 2055 2056 1091 1092 1093
	# alpha.17 P1-3: 在 kill_used_port 前打印占用端口的具体进程，便于诊断端口冲突
	echo_date "准备工作：检查冲突端口占用 (3333/3334/23456/7913/1051-1093/2055-2056)..."
	local _occupied=$(netstat -lntup 2>/dev/null | awk 'NR>2 {split($4,a,":"); p=a[length(a)]} p~/^(3333|3334|23456|7913|1051|1052|2055|2056|1091|1092|1093)$/ {print $4"→"$7}' | tr '\n' ' ')
	[ -n "${_occupied}" ] && echo_date "⚠️ 检测到目标端口已被占用: ${_occupied} 将尝试释放"
	kill_used_port

	# 3. internet detect
	echo_date "准备工作：检测基础网络连通性..."
	check_internet
	echo_date "准备工作：同步DNS与IPv6策略..."
	check_ipv6_proxy_prerequisites
	sync_dns_ipv6_policy

	# 4. 检测路由器时间是否正确，只有vmess协议节点需要检测时间正确否
	if [ "${ss_basic_type}" == "3" ];then
		if [ "${ss_basic_v2ray_use_json}" == "0" ];then
			check_time
		elif [ "${ss_basic_v2ray_use_json}" == "1" ];then
			local _ret_vmess=$(echo "$ss_basic_v2ray_json" | base64_decode | grep protocol | grep -Eo "vmess")
			if [ -n "${_ret_vmess}" ];then
				check_time
			fi
		fi
	fi

	if [ "${ss_basic_type}" == "4" ];then
		if [ "${ss_basic_xray_use_json}" == "1" ];then
			local _ret_vmess=$(echo "$ss_basic_xray_json" | base64_decode | grep protocol | grep -Eo "vmess")
			if [ -n "${_ret_vmess}" ];then
				check_time
			fi
		fi
	fi
	
	# 检测路由器公网出口IPV4地址
	if [ "${ss_basic_nochnipcheck}" != "1" ];then
		echo_date "准备工作：检查公网出口与WAN口地址..."
		check_chn_public_ip
	fi
	
	# 6. set_ulimit
	ulimit -n 16384

	# 7. clean mem
	echo 1 >/proc/sys/vm/overcommit_memory

	# 8. more entropy
	# use command `cat /proc/sys/kernel/random/entropy_avail` to check current entropy
	# few scenario should be noticed below:
	# 1. from merlin fw 386.2, jitterentropy-rngd has been intergrated into fw, so haveged form fancyss should not be used
	# 2. from merlin fw 386.4, jitterentropy-rngd was replaced by haveged, so havege form fancyss should not be used
	# 3. newer asus fw or asus_ks_mod fw like GT-AX6000 use jitterentropy-rngd, so havege form fancyss should not be used
	# 4. older merlin or asus_ks_mod fw do not have jitterentropy-rngd or haveged, so havege form fancyss should be used
	if [ -z "$(pidof jitterentropy-rngd)" -a -z "$(pidof haveged)" -a -f "/koolshare/bin/haveged" ];then
		# run haveged form fancyss when there are not entropy software running
		echo_date "启动haveged，为系统提供更多的可用熵！"
		run /koolshare/bin/haveged -w 1024 >/dev/null 2>&1
	fi

	# 9. 用户自定义的dns不需要，新固件这里已经不管用了
	if [ -n "$(nvram get dhcp_dns1_x)" ]; then
		nvram unset dhcp_dns1_x
		nvram commit
	fi
	if [ -n "$(nvram get dhcp_dns2_x)" ]; then
		nvram unset dhcp_dns2_x
		nvram commit
	fi
	# 这些值，如果等1，则重设置为0
	if [ "$(nvram get dns_fwd_local)" == "1" ]; then
		nvram set dns_fwd_local=0
		nvram commit
	fi
	if [ "$(nvram get dns_norebind)" == "1" ]; then
		nvram set dns_norebind=0
		nvram commit
	fi
	if [ "$(nvram get dnssec_enable)" == "1" ]; then
		nvram set dnssec_enable=0
		nvram commit
	fi
	if [ "$(nvram get dnspriv_enable)" == "1" ]; then
		nvram set dnspriv_enable=0
		nvram commit
	fi

	if [ "${ss_basic_type}" == "0" ];then
		echo_date "ℹ️使用Xray-core运行ss协议节点..."
		SS_CONFIG_TEMP="/tmp/xray_tmp.json"
		SS_CONFIG_FILE="/koolshare/ss/xray.json"
	fi

	
	if [ "${ss_basic_type}" == "3" ];then
		echo_date "ℹ️使用Xray-core运行vmess协议节点..."
		VCORE_NAME=Xray
		VMESS_CONFIG_TEMP="/tmp/xray_tmp.json"
		VMESS_CONFIG_FILE="/koolshare/ss/xray.json"
	fi

	if [ "${ss_basic_type}" == "4" ];then
		VLESS_CONFIG_TEMP="/tmp/xray_tmp.json"
		VLESS_CONFIG_FILE="/koolshare/ss/xray.json"
	fi

	# 11. set tcore (trojan core) name
	if [ "${ss_basic_type}" == "5" ];then
		echo_date "ℹ️使用Xray-core运行trojan协议节点..."
		TROJAN_CONFIG_TEMP="/tmp/xray_tmp.json"
		TROJAN_CONFIG_FILE="/koolshare/ss/xray.json"
	fi

	# 11. set hy2 core name
	if [ "${ss_basic_type}" == "8" ];then
		echo_date "ℹ️使用Xray-core运行hysteia2协议节点..."
		HY2_CONFIG_TEMP="/tmp/xray_tmp.json"
		HY2_CONFIG_FILE="/koolshare/ss/xray.json"
	fi

	if ! proxy_core_supports_udp && [ "${ss_basic_mode}" == "3" ];then
		echo_date "$(proxy_core_udp_unsupported_name)不支持udp代理，因此不支持游戏模式，自动切换为大陆白名单模式！"
		ss_basic_mode="2"
		fss_set_current_node_field_plain mode "2"
	fi

	# 把当前节点名写入文件，下次启动进行对比就知道是否更换了节点
	if [ -f "/tmp/upload/fancyss_node_name.txt" ];then
		last_node_name=$(cat /tmp/upload/fancyss_node_name.txt | sed -n '1p' | base64_decode | tr -d '\r')
		last_node_hash=$(cat /tmp/upload/fancyss_node_name.txt | sed -n '2p')
		last_node_indx=$(cat /tmp/upload/fancyss_node_name.txt | sed -n '3p')
		last_node_index=$(cat /tmp/upload/fancyss_node_name.txt | sed -n '4p')
	else
		last_node_name=""
		last_node_hash=""
		last_node_indx=""
		last_node_index=""
	fi
	curr_node_name=$(printf "%s" "${ss_basic_name}" | tr -d '\r')
	curr_node_hash=$(printf "%s" "${curr_node_name}" | md5sum | awk '{print $1}')
	curr_node_index="${ssconf_basic_node}"

	local _same_node="0"
	if [ -n "${last_node_index}" -a "${last_node_index}" = "${curr_node_index}" ];then
		_same_node="1"
	elif [ "${curr_node_hash}" = "${last_node_hash}" ];then
		_same_node="1"
	elif [ -n "${last_node_name}" -a "${curr_node_name}" = "${last_node_name}" ];then
		_same_node="1"
	fi

	if [ "${_same_node}" = "1" ];then
		if [ "${ss_basic_status}" == "1" ];then
			echo_date "🟠重启节点：【${ss_basic_name}】"
		else
			echo_date "🟠继续使用节点：【${ss_basic_name}】"
		fi
		_node_change_status="0"
	else
		if [ -n "${last_node_name}" ];then
			echo_date "🟠切换节点：【${last_node_name}】 ---→ 【${ss_basic_name}】"
			_node_change_status="1"
		else
			echo_date "🟠启用节点：【${ss_basic_name}】"
			_node_change_status="2"
		fi
	fi
	
	echo "${ss_basic_name}" | base64_encode | sed 's/$/\n/' >/tmp/upload/fancyss_node_name.txt
	echo "${curr_node_hash}" >>/tmp/upload/fancyss_node_name.txt
	echo "${ss_basic_smrt}" >>/tmp/upload/fancyss_node_name.txt
	echo "${curr_node_index}" >>/tmp/upload/fancyss_node_name.txt
}

get_lan_cidr() {
	local netmask=$(nvram get lan_netmask)
	local x=${netmask##*255.}
	set -- 0^^^128^192^224^240^248^252^254^ $(((${#netmask} - ${#x}) * 2)) ${x%%.*}
	x=${1%%$3*}
	suffix=$(($2 + (${#x} / 4)))
	#prefix=`nvram get lan_ipaddr | cut -d "." -f1,2,3`
	echo $lan_ipaddr/$suffix
}

get_wan0_cidr() {
	local netmask=$(nvram get wan0_netmask)
	local x=${netmask##*255.}
	set -- 0^^^128^192^224^240^248^252^254^ $(((${#netmask} - ${#x}) * 2)) ${x%%.*}
	x=${1%%$3*}
	suffix=$(($2 + (${#x} / 4)))
	prefix=$(nvram get wan0_ipaddr)
	if [ -n "$prefix" -a -n "$netmask" ]; then
		echo $prefix/$suffix
	else
		echo ""
	fi
}

__get_type_abbr_name() {
	case "${ss_basic_type}" in
	0)
		echo "SS"
		;;
	1)
		echo "SSR"
		;;
	3)
		echo "Vmess"
		;;
	4)
		echo "Vless"
		;;
	5)
		echo "Trojan"
		;;
	6)
		echo "Naïve"
		;;
	7)
		echo "Tuic"
		;;
	8)
		echo "Hysteria2"
		;;
	9)
		echo "AnyTLS"
		;;
	esac
}

get_tproxy_port4() {
	echo "3333"
}

get_tproxy_port6() {
	echo "3333"
}

proxy_core_supports_udp() {
	case "${ss_basic_type}" in
	6|9)
		return 1
		;;
	esac
	return 0
}

proxy_core_udp_unsupported_name() {
	case "${ss_basic_type}" in
	6)
		echo "NaïveProxy"
		;;
	9)
		echo "AnyTLS"
		;;
	*)
		get_type_name "${ss_basic_type}"
		;;
	esac
}

normalize_server_resolv_mode() {
	ss_basic_server_resolv_mode="1"
	dbus set ss_basic_server_resolv_mode="1"
	dbus remove ss_basic_server_resolv
	dbus remove ss_basic_server_resolv_user
	dbus remove ss_basic_lastru
}

server_resolv_mode_is_dynamic() {
	return 0
}

clear_current_node_server_ip() {
	unset CURRENT_NODE_SERVER_RESOLVED_IP
	unset CURRENT_NODE_SERVER_RESOLVED_HOST
	unset ss_basic_server_ip
	unset ss_basic_server_ip_host
	dbus remove ss_basic_server_ip
	dbus remove ss_basic_server_ip_host
}

record_current_node_server_ip() {
	local server_ip="$1"
	[ -n "${server_ip}" ] || {
		clear_current_node_server_ip
		return 1
	}
	CURRENT_NODE_SERVER_RESOLVED_IP="${server_ip}"
	if [ -n "${ss_basic_server_orig}" ];then
		CURRENT_NODE_SERVER_RESOLVED_HOST="${ss_basic_server_orig}"
	fi
	return 0
}

extract_tuic_server_host_port() {
	local tuic_server_raw="$1"
	local tuic_server=""
	local tuic_port=""

	case "${tuic_server_raw}" in
	\[*\]:*)
		tuic_server="${tuic_server_raw#\[}"
		tuic_server="${tuic_server%\]:*}"
		tuic_port="${tuic_server_raw##*\]:}"
		;;
	\[*\])
		tuic_server="${tuic_server_raw#\[}"
		tuic_server="${tuic_server%\]}"
		;;
	*:* )
		tuic_server="${tuic_server_raw%:*}"
		tuic_port="${tuic_server_raw##*:}"
		;;
	*)
		tuic_server="${tuic_server_raw}"
		;;
	esac

	printf '%s\n%s\n' "${tuic_server}" "${tuic_port}"
}

extract_xray_like_server_field_from_json_text() {
	local json_text="$1"
	local field="$2"

	printf '%s' "${json_text}" | run jq -r --arg field "${field}" '
		(.outbound // (.outbounds[0] // {})) as $ob
		| ($ob.protocol // "") as $protocol
		| if ($protocol == "vmess" or $protocol == "vless") then
			if $field == "host" then
				($ob.settings.vnext[0].address // "")
			else
				(($ob.settings.vnext[0].port // "") | tostring)
			end
		elif ($protocol == "socks" or $protocol == "shadowsocks" or $protocol == "trojan") then
			if $field == "host" then
				($ob.settings.servers[0].address // "")
			else
				(($ob.settings.servers[0].port // "") | tostring)
			end
		else
			""
		end
	' 2>/dev/null
}

resolve_current_node_server_meta() {
	local host="" port="" json_text="" relay_server=""

	case "${ss_basic_type}" in
	0|1|5)
		host="${ss_basic_server}"
		port="${ss_basic_port}"
		;;
	3)
		if [ "${ss_basic_v2ray_use_json}" = "1" ]; then
			json_text="$(printf '%s' "${ss_basic_v2ray_json}" | base64_decode 2>/dev/null)"
			host="$(extract_xray_like_server_field_from_json_text "${json_text}" host)"
			port="$(extract_xray_like_server_field_from_json_text "${json_text}" port)"
		else
			host="${ss_basic_server}"
			port="${ss_basic_port}"
		fi
		;;
	4)
		if [ "${ss_basic_xray_use_json}" = "1" ]; then
			json_text="$(printf '%s' "${ss_basic_xray_json}" | base64_decode 2>/dev/null)"
			host="$(extract_xray_like_server_field_from_json_text "${json_text}" host)"
			port="$(extract_xray_like_server_field_from_json_text "${json_text}" port)"
		else
			host="${ss_basic_server}"
			port="${ss_basic_port}"
		fi
		;;
	6)
		host="${ss_basic_naive_server}"
		port="${ss_basic_naive_port}"
		;;
	7)
		json_text="$(printf '%s' "${ss_basic_tuic_json}" | base64_decode 2>/dev/null)"
		relay_server="$(printf '%s' "${json_text}" | run jq -r '.relay.server // empty' 2>/dev/null)"
		{
			read -r host
			read -r port
		} <<-EOF
		$(extract_tuic_server_host_port "${relay_server}")
		EOF
		;;
	8)
		host="${ss_basic_hy2_server}"
		port="${ss_basic_hy2_port}"
		;;
	9)
		host="${ss_basic_anytls_server}"
		port="${ss_basic_anytls_port}"
		;;
	*)
		host="${ss_basic_server}"
		port="${ss_basic_port}"
		;;
	esac

	CURRENT_NODE_SERVER_HOST="${host}"
	CURRENT_NODE_SERVER_PORT="${port}"
	__valid_ip46 "${host}" >/dev/null 2>&1
	CURRENT_NODE_SERVER_IS_IP="$?"
}

current_node_server_is_domain_target() {
	resolve_current_node_server_meta
	[ -n "${CURRENT_NODE_SERVER_HOST}" ] || return 1
	[ -n "$(is_domain "${CURRENT_NODE_SERVER_HOST}")" ]
}

refresh_node_direct_domain_file() {
	fss_require_base_dns >/dev/null 2>&1 || true
	fss_refresh_node_direct_cache
	fss_airport_dns_override_load >/dev/null 2>&1 || true
	if [ "${AIRPORT_DNS_ACTIVE}" = "1" ];then
		fss_refresh_airport_special_runtime_domain_files >/dev/null 2>&1 || true
		if [ -s "${FSS_NODE_DIRECT_RUNTIME_OTHER_FILE}" ];then
			cp -f "${FSS_NODE_DIRECT_RUNTIME_OTHER_FILE}" "${FSS_NODE_DIRECT_RUNTIME_FILE}"
		else
			rm -f "${FSS_NODE_DIRECT_RUNTIME_FILE}"
		fi
	else
		rm -f "${FSS_NODE_DIRECT_RUNTIME_AIRPORT_FILE}" "${FSS_NODE_DIRECT_RUNTIME_OTHER_FILE}" "${FSS_NODE_DIRECT_RUNTIME_AIRPORT_DNS_FILE}" >/dev/null 2>&1
		fss_sync_node_direct_runtime
	fi
}

refresh_node_direct_dns() {
	refresh_node_direct_domain_file || return 1
	[ "${ss_basic_enable}" = "1" ] || return 0
	case "${ss_basic_dns_plan}" in
	1|2)
		;;
	*)
		return 0
		;;
	esac
	stop_dns_process
	restart_dnsmasq
	start_dns_x
}

refresh_current_node_server_ip_runtime() {
	local resolved_ip=""
	[ -n "${ss_basic_server_orig}" ] || return 1
	[ -n "$(is_domain "${ss_basic_server_orig}")" ] || return 1

	if [ "${CURRENT_NODE_SERVER_RESOLVED_HOST}" = "${ss_basic_server_orig}" ] && [ -n "${CURRENT_NODE_SERVER_RESOLVED_IP}" ];then
		__valid_ip46 "${CURRENT_NODE_SERVER_RESOLVED_IP}" >/dev/null 2>&1
		if [ "$?" = "0" -o "$?" = "1" ];then
			echo_date "节点服务器域名运行时解析复用缓存：${ss_basic_server_orig} -> ${CURRENT_NODE_SERVER_RESOLVED_IP}"
			return 0
		fi
	fi

	resolved_ip=$(run dnsclient -46 -p 53 -t 1 -i 1 @127.0.0.1 "${ss_basic_server_orig}" 2>/dev/null | head -n1)
	__valid_ip46 "${resolved_ip}" >/dev/null 2>&1
	[ "$?" = "0" -o "$?" = "1" ] || resolved_ip=""
	[ -n "${resolved_ip}" ] || return 1
	record_current_node_server_ip "${resolved_ip}" || return 1
	echo_date "节点服务器域名运行时解析成功：${ss_basic_server_orig} -> ${resolved_ip}"
	return 0
}

should_bootstrap_dns_before_proxy() {
	[ -n "${ss_basic_server_orig}" ] || return 1
	[ -n "$(is_domain "${ss_basic_server_orig}")" ] || return 1
	return 0
}

rewrite_xray_like_outbound_server() {
	local config_file="$1"
	local target_addr="$2"
	local tmp_file="${config_file}.server"
	local protocol=""

	[ -f "${config_file}" ] || return 1
	[ -n "${target_addr}" ] || return 0

	protocol=$(cat "${config_file}" | run jq -r '.outbounds[0].protocol // empty' 2>/dev/null)
	case "${protocol}" in
	vmess|vless)
		cat "${config_file}" | run jq --arg addr "${target_addr}" '.outbounds[0].settings.vnext[0].address = $addr' > "${tmp_file}" || return 1
		;;
	socks|shadowsocks|trojan)
		cat "${config_file}" | run jq --arg addr "${target_addr}" '.outbounds[0].settings.servers[0].address = $addr' > "${tmp_file}" || return 1
		;;
	*)
		return 0
		;;
	esac

	mv -f "${tmp_file}" "${config_file}"
}

# ================================= ss stop ===============================

restore_conf() {
	echo_date "删除fancyss相关的名单配置文件..."
	rm -f /jffs/configs/dnsmasq.d/custom.conf
	rm -f /jffs/configs/dnsmasq.d/ss_host.conf
	rm -f /jffs/configs/dnsmasq.d/ss_server.conf
	rm -f /jffs/configs/dnsmasq.d/ss_domain.conf
	rm -f /jffs/scripts/dnsmasq.postconf
	rm -f /jffs/scripts/dnsmasq-sdn.postconf
	rm -f /tmp/custom.conf
	rm -f /tmp/ss_host.conf
	rm -f /tmp/gfwlist.txt
	rm -f /tmp/chnlist.txt
	rm -f /tmp/ss_node_domains.txt
	rm -f /tmp/black_list.txt
	rm -f /tmp/white_list.txt
	rm -f /tmp/block_list.txt

	if [ -z "${WEB_ACTION}" ]; then
		if [ -n "${WAN_ACTION}" ]; then
			return 0
		fi
	else
		rm -f /koolshare/ss/xray.json
		rm -f /koolshare/ss/v2ray.json
		rm -f /koolshare/ss/ssr.json
		rm -f /koolshare/ss/tuic.json
	fi
}

kill_process() {
	local v2ray_process=$(pidof v2ray)
	if [ -n "$v2ray_process" ]; then
		echo_date "关闭V2Ray进程..."
		# 有时候killall杀不了v2ray进程，所以用不同方式杀两次
		killall v2ray >/dev/null 2>&1
		kill -9 "$v2ray_process" >/dev/null 2>&1
	fi

	local xray_process=$(pidof xray)
	if [ -n "$xray_process" ]; then
		echo_date "关闭xray进程..."
		if [ -d "/koolshare/perp/xray" ];then
			perpctl d xray >/dev/null 2>&1
			rm -rf /koolshare/perp/xray >/dev/null 2>&1
		fi
		killall xray >/dev/null 2>&1
		kill -9 "$xray_process" >/dev/null 2>&1
	fi

	# FORK: cut in doge.10, see doc/design/protocol-roadmap.md §2 (SSR type=1)
	# local rssredir=$(pidof rss-redir)
	# if [ -n "$rssredir" ]; then
	# 	echo_date "关闭ssr-redir进程..."
	# 	killall rss-redir >/dev/null 2>&1
	# fi
	#
	# local ssrlocal=$(ps | grep -w rss-local | grep -v "grep" | grep -w "23456" | awk '{print $1}')
	# if [ -n "$ssrlocal" ]; then
	# 	echo_date "关闭ssr-local进程:23456端口..."
	# 	kill $ssrlocal >/dev/null 2>&1
	# fi

	local sstunnel=$(pidof ss-tunnel)
	if [ -n "$sstunnel" ]; then
		echo_date "关闭进程..."
		killall ss-tunnel >/dev/null 2>&1
	fi

	local CHNG_PID=$(pidof chinadns-ng)
	if [ -n "${CHNG_PID}" ];then
		echo_date "关闭chinadns-ng进程..."
		if [ -d "/koolshare/perp/chinadns-ng" ];then
			perpctl d chinadns-ng >/dev/null 2>&1
			rm -rf /koolshare/perp/chinadns-ng >/dev/null 2>&1
		fi
		killall chinadns-ng >/dev/null 2>&1
		kill -9 ${CHNG_PID} >/dev/null 2>&1
	fi

	local smartdns_process=$(pidof smartdns)
	if [ -n "$smartdns_process" ]; then
		echo_date "关闭smartdns进程..."
		killall smartdns >/dev/null 2>&1
	fi

	# only close haveged form fancyss, not haveged from system
	local haveged_pid=$(ps |grep "/koolshare/bin/haveged"|grep -v grep|awk '{print $1}')
	if [ -n "${haveged_pid}" ]; then
		echo_date "关闭haveged进程..."
		killall -9 ${haveged_pid} >/dev/null 2>&1
	fi

	local SOCAT_PID=$(ps | grep -E "socat" | grep -E "2055|2056" | awk '{print $1}')
	if [ -n "${SOCAT_PID}" ];then
		echo_date "关闭socat进程..."
		kill -9 ${SOCAT_PID}
	fi

	local IPT2SOCKS_PID=$(ps | grep "ipt2socks" | grep -v grep | awk '{print $1}')
	if [ -n "${IPT2SOCKS_PID}" ];then
		echo_date "关闭ipt2socks进程..."
		killall ipt2socks
	fi	

	# FORK: cut in doge.10, see doc/design/protocol-roadmap.md §2 (Naive type=6 / Tuic type=7)
	# local NAIVE_PID=$(ps | grep "naive" | grep -v grep | awk '{print $1}')
	# if [ -n "${NAIVE_PID}" ];then
	# 	echo_date "关闭naive进程..."
	# 	killall naive
	# fi
	#
	# local TUIC_PID=$(ps | grep "tuic-client" | grep -v grep | awk '{print $1}')
	# if [ -n "${TUIC_PID}" ];then
	# 	echo_date "关闭tuic-client进程..."
	# 	killall tuic-client
	# fi

	local ANYTLS_PID=$(ps | grep "anytls-zig" | grep -v grep | awk '{print $1}')
	if [ -n "${ANYTLS_PID}" ];then
		echo_date "关闭anytls-zig进程..."
		killall anytls-zig
	fi

	local OBFSLOCAL_PID=$(ps | grep "obfs-local" | grep -v grep | awk '{print $1}')
	if [ -n "${OBFSLOCAL_PID}" ];then
		echo_date "关闭obfs-local进程..."
		killall obfs-local
	fi
	
	# close tcp_fastopen
	if [ "${LINUX_VER}" != "26" ]; then
		echo 1 >/proc/sys/net/ipv4/tcp_fastopen
	fi
}

shunt_configs_equivalent() {
	local old_file="$1"
	local new_file="$2"
	local jq_bin=""
	local old_norm=""
	local new_norm=""

	[ -s "${old_file}" ] || return 1
	[ -s "${new_file}" ] || return 1
	if type fss_pick_jq_bin >/dev/null 2>&1; then
		jq_bin="$(fss_pick_jq_bin 2>/dev/null)"
	fi
	[ -n "${jq_bin}" ] || jq_bin="$(command -v jq 2>/dev/null)"
	if [ -n "${jq_bin}" ]; then
		old_norm="${old_file}.norm.$$"
		new_norm="${new_file}.norm.$$"
		"${jq_bin}" -S . "${old_file}" > "${old_norm}" 2>/dev/null || {
			rm -f "${old_norm}" "${new_norm}" >/dev/null 2>&1
			return 1
		}
		"${jq_bin}" -S . "${new_file}" > "${new_norm}" 2>/dev/null || {
			rm -f "${old_norm}" "${new_norm}" >/dev/null 2>&1
			return 1
		}
		cmp -s "${old_norm}" "${new_norm}"
		local ret=$?
		rm -f "${old_norm}" "${new_norm}" >/dev/null 2>&1
		return "${ret}"
	fi
	cmp -s "${old_file}" "${new_file}"
}
# ================================= ss start ==============================

init_current_node_server_state() {
	normalize_server_resolv_mode
	clear_current_node_server_ip
	resolve_current_node_server_meta
	fss_require_base_dns >/dev/null 2>&1 || true
	fss_airport_dns_override_load

	ss_basic_server_orig="${CURRENT_NODE_SERVER_HOST}"
	ss_basic_server="${CURRENT_NODE_SERVER_HOST}"

	if [ -n "${CURRENT_NODE_SERVER_HOST}" ]; then
		case "${ss_basic_type}_${ss_basic_v2ray_use_json}_${ss_basic_xray_use_json}" in
		3_1_*|4_*_1)
			fss_set_current_node_field_plain server "${CURRENT_NODE_SERVER_HOST}"
			;;
		esac
	fi

	case "${CURRENT_NODE_SERVER_IS_IP}" in
	0|1)
		CURRENT_NODE_SERVER_RESOLVED_IP="${CURRENT_NODE_SERVER_HOST}"
		CURRENT_NODE_SERVER_RESOLVED_HOST="${CURRENT_NODE_SERVER_HOST}"
		;;
	esac

	return 0
}

resolv_server_ip() {
	init_current_node_server_state
	refresh_node_direct_domain_file

	if [ -z "${ss_basic_server_orig}" ]; then
		return 1
	fi

	case "${CURRENT_NODE_SERVER_IS_IP}" in
	0|1)
		echo_date "检测到你的$(__get_type_abbr_name)服务器已经是IP格式：${ss_basic_server_orig}，跳过解析... "
		return 0
		;;
	esac

	echo_date "检测到你的$(__get_type_abbr_name)服务器：【${ss_basic_server_orig}】不是ip格式！"
	echo_date "当前使用【动态解析】模式，保留域名写入配置，并交由DNS方案中的直连上游解析。"
	return 0
}

# FORK: cut in doge.10, see doc/design/protocol-roadmap.md §2
# create shadowsocks config file...
: <<'FORK_CUT_DOGE10'
creat_ssr_json() {
	if [ -z "${WEB_ACTION}" ]; then
		if [ -n "${WAN_ACTION}" ]; then
			echo_date "检测到网络拨号/开机触发启动，不创建$(__get_type_abbr_name)配置文件，使用上次的配置文件！"
			return 0
		fi
	else
		echo_date "创建$(__get_type_abbr_name)配置文件到${CONFIG_FILE}"
	fi

	cat >${CONFIG_FILE} <<-EOF
		{
		    "server":"${ss_basic_server}",
		    "server_port":${ss_basic_port},
		    "local_address":"$(if ipv6_proxy_enabled; then echo '::'; else echo '0.0.0.0'; fi)",
		    "local_port":3333,
		    "password":"${ss_basic_password}",
		    "timeout":600,
		    "protocol":"$ss_basic_rss_protocol",
		    "protocol_param":"$ss_basic_rss_protocol_param",
		    "obfs":"$ss_basic_rss_obfs",
		    "obfs_param":"$ss_basic_rss_obfs_param",
		    "method":"$ss_basic_method"
		}
	EOF
}
FORK_CUT_DOGE10

get_proxy_server_ip(){
	# 获取代理服务器ip地址
	# 在代理程序启动前获取，不一定是真实的代理服务器ip，比如中转节点
	if [ -n "${ss_real_server_ip}" ]; then
		return
	fi

	if [ -n "${CURRENT_NODE_SERVER_RESOLVED_IP}" ]; then
		__valid_ip46 "${CURRENT_NODE_SERVER_RESOLVED_IP}"
		if [ "$?" == "0" ]; then
			# ipv4
			ipset test chnroute ${CURRENT_NODE_SERVER_RESOLVED_IP} >/dev/null 2>&1
			if [ "$?" != "0" ]; then
				# ss服务器是国外IP
				ss_real_server_ip="${CURRENT_NODE_SERVER_RESOLVED_IP}"
				echo_date "检测到节点服务器的ip地址为：${CURRENT_NODE_SERVER_RESOLVED_IP}，是国外IP"
			else
				# ss服务器是国内ip （可能用了国内中转）
				ss_real_server_ip=""
				echo_date "检测到代理服务器的ip地址为：${CURRENT_NODE_SERVER_RESOLVED_IP}，是国内IP，可能是国内中转节点！"
			fi
		elif [ "$?" == "1" ]; then
			# ipv6
			ipset test chnroute6 ${CURRENT_NODE_SERVER_RESOLVED_IP} >/dev/null 2>&1
			if [ "$?" != "0" ]; then
				# ss服务器是国外IP
				ss_real_server_ip="${CURRENT_NODE_SERVER_RESOLVED_IP}"
				echo_date "检测到节点服务器的ip地址为：${CURRENT_NODE_SERVER_RESOLVED_IP}，是国外IP"
			else
				# ss服务器是国内ip （可能用了国内中转）
				ss_real_server_ip=""
				echo_date "检测到代理服务器的ip地址为：${CURRENT_NODE_SERVER_RESOLVED_IP}，是国内IP，可能是国内中转节点！"
			fi
		else
			# 不是ip
			ss_real_server_ip=""
		fi
	else
		# ss服务器可能是域名且没有正确解析
		ss_real_server_ip=""
	fi
}

# FORK: cut in doge.10, see doc/design/protocol-roadmap.md §2
: <<'FORK_CUT_DOGE10'
start_ssr_local() {
	if [ -n "$(ps|grep rss-local|grep 23456)" ];then
		return
	fi

	echo_date "开启ssr-local，提供socks5代理端口：23456"
	run_bg rss-local -b 127.0.0.1 -l 23456 -c ${CONFIG_FILE} -u -f /var/run/ssrlocal.pid
	detect_running_status rss-local "/var/run/ssrlocal.pid"
}
FORK_CUT_DOGE10

dbus_dset(){
	# set key when value exist, delete when empty
	if [ -n "$2" ];then
		dbus set $1=$2
	else
		dbus remove $1
	fi
}

dbus_eset(){
	# set key when value exist
	if [ -n "$2" ];then
		dbus set $1=$2
	fi
}

start_dns_x(){
	# alpha.17 P2-1: DNS 服务启动 banner——明确告诉用户当前走的是哪条 DNS 方案
	echo_date "------------------------- 启动 DNS 服务 -----------------------------"
	echo_date "DNS 方案: plan=${ss_basic_dns_plan:-1}（1=chinadns-ng / 2=smartdns） serverx=${ss_basic_dns_serverx:-0}"
	fss_require_base_dns >/dev/null 2>&1 || true
	set_default "ss_basic_dns_plan" "1"
	set_default "ss_basic_dns_serverx" "0"
	local runtime_mode="$(get_runtime_proxy_mode)"
	local dns_plan_runtime="${ss_basic_dns_plan}"
	local special_smartdns_label=""
	local special_dns_hint=""
	if [ "${AIRPORT_DNS_CURRENT_MATCHED}" = "1" ] && [ "${AIRPORT_DNS_PREFERRED_PLAN}" = "smartdns" ];then
		if [ "${ss_basic_dns_plan}" = "2" ]; then
			special_dns_hint="ℹ️检测到机场【${AIRPORT_DNS_AIRPORT_LABEL:-${AIRPORT_DNS_AIRPORT_IDENTITY}}】需要专属节点DNS，当前使用smartdns方案。"
		else
			special_dns_hint="ℹ️检测到机场【${AIRPORT_DNS_AIRPORT_LABEL:-${AIRPORT_DNS_AIRPORT_IDENTITY}}】需要专属节点DNS，本次临时切换为smartdns方案。"
		fi
		dns_plan_runtime="2"
	else
		special_smartdns_label="$(fss_airport_special_active_labels_by_plan "smartdns" 2>/dev/null)"
		if [ -n "${special_smartdns_label}" ];then
			if [ "${ss_basic_dns_plan}" = "2" ]; then
				special_dns_hint="ℹ️检测到机场【${special_smartdns_label}】需要使用smartdns，当前已使用smartdns方案。"
			else
				special_dns_hint="ℹ️检测到机场【${special_smartdns_label}】需要使用smartdns，为保证使用节点和测速正常，将强制使用smartdns。"
			fi
			dns_plan_runtime="2"
		fi
	fi
	[ -n "${special_dns_hint}" ] && echo_date "${special_dns_hint}"
	if ! proxy_core_supports_udp;then
		if [ "${dns_plan_runtime}" = "2" ];then
			if [ -n "$(smartdns_iter_gfw_udp_relays 2>/dev/null | sed -n '1p')" ];then
				echo_date "⚠️检测到 $(proxy_core_udp_unsupported_name) 不支持 UDP 代理，smartdns gfw 组中的 UDP DNS 将不会写入运行配置。"
			fi
		fi
	fi
	if [ "${dns_plan_runtime}" == "1" ];then
		# DNS分流模式和iptables分流需要匹配，不然效果不好，这里需要检测用户当前代理模式和当前DNS模式
		if [ "${runtime_mode}" == "1" ];then
			if [ "${ss_basic_chng}" == "2" ];then
				echo_date "⚠️警告：当前代理模式GFW黑名单与当前DNS模式：[国外优先]不匹配！"
				echo_date "🔁建议使用：[国内优先/智能判断]，本次自动将当前DNS模式改为：[国内优先]！"
				ss_basic_chng="1"
				dbus set ss_basic_chng="1"
			fi
		elif [ "${runtime_mode}" == "2" -o "${runtime_mode}" == "3" ];then
			if [ "${ss_basic_chng}" == "1" ];then
				echo_date "⚠️警告：当前代理模式与当前DNS模式：[国内优先]不匹配！"
				echo_date "🔁建议使用：[国外优先/智能判断]，本次自动将当前DNS模式改为：[国外优先]！"
				ss_basic_chng="2"
				dbus set ss_basic_chng="2"
			fi
		fi

		# doge.14: 分流架构唯一路径
		start_chinadns_ng_split
	elif [ "${dns_plan_runtime}" == "2" ];then
		# DNS分流模式和iptables分流需要匹配，不然效果不好，这里需要检测用户当前代理模式和当前DNS模式
		if [ "${runtime_mode}" == "1" ];then
			if [ "${ss_basic_smrt}" == "2" ];then
				echo_date "⚠️警告：当前代理模式GFW黑名单与当前DNS模式：[国外优先]不匹配！"
				echo_date "🔁建议使用：[国内优先/智能判断]，本次自动将当前DNS模式改为：[国内优先]！"
				ss_basic_smrt="1"
				dbus set ss_basic_smrt="1"
			fi
		elif [ "${runtime_mode}" == "2" -o "${runtime_mode}" == "3" ];then
			if [ "${ss_basic_smrt}" == "1" ];then
				echo_date "⚠️警告：当前代理模式与当前DNS模式：[国内优先]不匹配！"
				echo_date "🔁建议使用：[国外优先/智能判断]，本次自动将当前DNS模式改为：[国外优先]！"
				ss_basic_smrt="2"
				dbus set ss_basic_smrt="2"
			fi
		fi
	
		echo_date "start smartdns"
		start_smartdns ${ss_basic_smrt}
	fi
	# alpha.17 P2-1: DNS 服务启动尾部 banner
	echo_date "DNS 服务启动完毕。"
}

smartdns_format_addr() {
	local addr="$1"
	local port="$2"
	if [ -z "${port}" ] || [ "${port}" = "53" ];then
		echo "${addr}"
		return
	fi
	case "${addr}" in
	*:* )
		echo "[${addr}]:${port}"
		;;
	*)
		echo "${addr}:${port}"
		;;
	esac
}

smartdns_server_flags() {
	local mode="$1"
	local scope="$2"
	case "${mode}_${scope}" in
	1_chn_group)
		echo "-group chn -blacklist-ip"
		;;
	1_gfw_group)
		echo "-group gfw -exclude-default-group"
		;;
	2_chn_group)
		echo "-group chn -blacklist-ip -exclude-default-group"
		;;
	2_gfw_group)
		echo "-group gfw"
		;;
	3_chn_group)
		echo "-group chn -blacklist-ip -exclude-default-group"
		;;
	3_gfw_group)
		echo "-group gfw -blacklist-ip -exclude-default-group"
		;;
	3_chn_default)
		echo "-whitelist-ip -blacklist-ip"
		;;
	3_gfw_default)
		echo "-blacklist-ip"
		;;
	esac
}

smartdns_append_server_line() {
	local outfile="$1"
	local proto="$2"
	local addr="$3"
	local port="$4"
	local host="$5"
	local host_ip="$6"
	local flags="$7"
	local use_proxy="$8"
	local line=""
	local extras="${flags}"
	if [ "${use_proxy}" = "1" ];then
		extras="${extras} -proxy fancy_proxy"
	fi
	case "${proto}" in
	udp)
		line="server $(smartdns_format_addr "${addr}" "${port}")"
		;;
	tcp)
		line="server-tcp $(smartdns_format_addr "${addr}" "${port}")"
		;;
	dot)
		line="server-tls ${host}"
		;;
	*)
		return 0
		;;
	esac
	[ -n "${extras}" ] && line="${line} ${extras}"
	if [ "${proto}" = "dot" ];then
		line="${line} -host-ip ${host_ip}"
		if [ -n "${port}" ] && [ "${port}" != "853" ];then
			line="${line} -port ${port}"
		fi
	fi
	echo "${line}" >> "${outfile}"
}

smartdns_append_group_servers() {
	local outfile="$1"
	local mode="$2"
	local group="$3"
	local scope="$4"
	local relay_idx=0
	local append_count=0
	local skip_udp_count=0
	local flags="$(smartdns_server_flags "${mode}" "${scope}")"
	local use_proxy="0"
	local sep="$(printf '\037')"
	[ "${group}" = "gfw" ] && use_proxy="1"
	while IFS="${sep}" read -r id proto provider description kind slot addr port host host_ip isp net
	do
		if [ "${group}" = "gfw" ] && ! proxy_core_supports_udp && [ "${proto}" = "udp" ];then
			skip_udp_count=$((skip_udp_count + 1))
			continue
		fi
		local target_addr="${addr}"
		local target_port="${port}"
		local target_proxy="${use_proxy}"
		if [ "${group}" = "gfw" ] && [ "${proto}" = "udp" ];then
			relay_idx=$((relay_idx + 1))
			target_addr="127.0.0.1"
			target_port=$((SMARTDNS_RELAY_PORT_BASE + relay_idx - 1))
			target_proxy="0"
		fi
		smartdns_append_server_line "${outfile}" "${proto}" "${target_addr}" "${target_port}" "${host}" "${host_ip}" "${flags}" "${target_proxy}"
		append_count=$((append_count + 1))
	done <<-EOF
$(smartdns_group_items_tsv "${group}")
EOF
	if [ "${group}" = "gfw" ] && ! proxy_core_supports_udp;then
		if [ "${skip_udp_count}" -gt 0 ];then
			echo_date "⚠️smartdns ${scope}：已跳过 ${skip_udp_count} 个 gfw 组 UDP DNS。"
		fi
		if [ "${append_count}" -eq 0 ];then
			smartdns_append_server_line "${outfile}" "tcp" "8.8.8.8" "53" "" "" "${flags}" "${use_proxy}"
			echo_date "⚠️smartdns ${scope}：gfw 组没有可用 TCP/DoT DNS，已使用 tcp://8.8.8.8 兜底。"
		fi
	fi
}

smartdns_append_node_direct_servers() {
	local outfile="$1"
	local sep="$(printf '\037')"
	while IFS="${sep}" read -r id proto provider description kind slot addr port host host_ip isp net
	do
		smartdns_append_server_line "${outfile}" "${proto}" "${addr}" "${port}" "${host}" "${host_ip}" "-group node_direct -exclude-default-group" "0"
	done <<-EOF
$(smartdns_group_items_tsv chn)
EOF
}

smartdns_airport_group_name() {
	local airport_identity="$1"
	[ -n "${airport_identity}" ] || return 1
	printf 'airport_%s\n' "${airport_identity}"
}

smartdns_airport_dns_group_name() {
	local airport_identity="$1"
	[ -n "${airport_identity}" ] || return 1
	printf 'airport_dns_%s\n' "${airport_identity}"
}

smartdns_append_airport_node_servers_by_identity() {
	local outfile="$1"
	local airport_identity="$2"
	local sep="$(printf '\037')"
	local proto raw addr port host host_ip
	local group_name=""
	[ -n "${airport_identity}" ] || return 0
	group_name="$(smartdns_airport_group_name "${airport_identity}" 2>/dev/null)" || return 0
	fss_airport_runtime_iter_dns_items_tsv_by_identity "${airport_identity}" 2>/dev/null | while IFS="${sep}" read -r proto raw addr port host host_ip
	do
		[ -n "${proto}" ] || continue
		case "${proto}" in
		udp)
			[ -n "${addr}" ] || continue
			[ -n "${port}" ] || port="53"
			echo "server $(smartdns_format_addr "${addr}" "${port}") -group ${group_name} -exclude-default-group" >> "${outfile}"
			;;
		tcp)
			[ -n "${addr}" ] || continue
			[ -n "${port}" ] || port="53"
			echo "server-tcp $(smartdns_format_addr "${addr}" "${port}") -group ${group_name} -exclude-default-group" >> "${outfile}"
			;;
		tls)
			[ -n "${raw}" ] || continue
			echo "server-tls ${raw#tls://} -group ${group_name} -exclude-default-group" >> "${outfile}"
			;;
		https)
			[ -n "${raw}" ] || continue
			echo "server-https ${raw} -group ${group_name} -exclude-default-group" >> "${outfile}"
			;;
		quic)
			[ -n "${raw}" ] || continue
			echo "server-quic ${raw} -group ${group_name} -exclude-default-group" >> "${outfile}"
			;;
		esac
	done
}

smartdns_append_ipv6_policy() {
	local outfile="$1"
	local mode="$2"
	local has_node_direct="0"
	local airport_identity=""
	local airport_dns_group=""
	local airport_dns_file=""
	[ -s /tmp/ss_node_domains.txt ] && has_node_direct="1"
	smartdns_append_airport_dns_ipv6_lines() {
		while IFS="$(printf '\037')" read -r airport_identity _airport_label _airport_plan
		do
			[ -n "${airport_identity}" ] || continue
			airport_dns_group="$(smartdns_airport_dns_group_name "${airport_identity}" 2>/dev/null)" || continue
			airport_dns_file="$(fss_airport_special_runtime_dns_file "${airport_identity}" 2>/dev/null)" || continue
			[ -s "${airport_dns_file}" ] && echo "address /domain-set:${airport_dns_group}/-6" >> "${outfile}"
		done <<-EOF
$(fss_airport_special_iter_active_tsv 2>/dev/null)
		EOF
	}
	if [ "${ss_basic_proxy_ipv6}" = "1" ];then
		cat >> "${outfile}" <<-'EOF'
force-AAAA-SOA no
EOF
		if [ "${has_node_direct}" = "1" ];then
			echo "address /domain-set:node_direct/-6" >> "${outfile}"
		fi
		smartdns_append_airport_dns_ipv6_lines
		return
	fi
	case "${mode}" in
	1)
		cat >> "${outfile}" <<-'EOF'
force-AAAA-SOA no
address /domain-set:gfwlist/#6
address /domain-set:black_list/#6
address /domain-set:rotlist/#6
EOF
		if [ "${has_node_direct}" = "1" ];then
			echo "address /domain-set:node_direct/-6" >> "${outfile}"
		fi
		smartdns_append_airport_dns_ipv6_lines
		;;
	2|3)
		cat >> "${outfile}" <<-'EOF'
force-AAAA-SOA yes
address /domain-set:chnlist/-6
address /domain-set:white_list/-6
EOF
		if [ "${has_node_direct}" = "1" ];then
			echo "address /domain-set:node_direct/-6" >> "${outfile}"
		fi
		smartdns_append_airport_dns_ipv6_lines
		;;
	5)
		cat >> "${outfile}" <<-'EOF'
force-AAAA-SOA yes
address /domain-set:white_list/-6
EOF
		if [ "${has_node_direct}" = "1" ];then
			echo "address /domain-set:node_direct/-6" >> "${outfile}"
		fi
		smartdns_append_airport_dns_ipv6_lines
		;;
	*)
		cat >> "${outfile}" <<-'EOF'
force-AAAA-SOA no
EOF
		if [ "${has_node_direct}" = "1" ];then
			echo "address /domain-set:node_direct/-6" >> "${outfile}"
		fi
		smartdns_append_airport_dns_ipv6_lines
		;;
	esac
}

smartdns_generate_runtime_conf() {
	local outfile="$1"
	local mode="$2"
	local listen_port="7913"
	local airport_identity=""
	local airport_label=""
	local airport_plan=""
	local airport_group=""
	local airport_dns_group=""
	local airport_domain_file=""
	local airport_dns_file=""
	[ "${ss_basic_dns_serverx}" = "1" ] && listen_port="53"
	: > "${outfile}"
	[ "${mode}" = "3" ] && generate_smartdns_whitelist_file /tmp/whitelist_ip.txt
	cat > "${outfile}" <<-EOF
# Auto-generated by fancyss.
bind [::]:${listen_port}

domain-set -name chnlist -file /tmp/chnlist.txt
domain-set -name gfwlist -file /tmp/gfwlist.txt
domain-set -name rotlist -file /koolshare/ss/rules/rotlist.txt
domain-set -name white_list -file /tmp/white_list.txt
domain-set -name black_list -file /tmp/black_list.txt
EOF
	while IFS="$(printf '\037')" read -r airport_identity airport_label airport_plan
	do
		[ -n "${airport_identity}" ] || continue
		airport_group="$(smartdns_airport_group_name "${airport_identity}" 2>/dev/null)" || continue
		airport_dns_group="$(smartdns_airport_dns_group_name "${airport_identity}" 2>/dev/null)" || continue
		airport_domain_file="$(fss_airport_special_runtime_domain_file "${airport_identity}" 2>/dev/null)" || continue
		airport_dns_file="$(fss_airport_special_runtime_dns_file "${airport_identity}" 2>/dev/null)" || continue
		[ -s "${airport_dns_file}" ] && echo "domain-set -name ${airport_dns_group} -file ${airport_dns_file}" >> "${outfile}"
		[ -s "${airport_domain_file}" ] && echo "domain-set -name ${airport_group} -file ${airport_domain_file}" >> "${outfile}"
	done <<-EOF
$(fss_airport_special_iter_active_tsv 2>/dev/null)
	EOF
	[ -s /tmp/ss_node_domains.txt ] && echo "domain-set -name node_direct -file /tmp/ss_node_domains.txt" >> "${outfile}"
	[ "${ss_basic_block_resov}" = "1" ] && echo "domain-set -name block_list -file /tmp/block_list.txt" >> "${outfile}"

	[ "${mode}" = "3" ] && echo "conf-file /tmp/whitelist_ip.txt" >> "${outfile}"
	echo "" >> "${outfile}"
	[ "${ss_basic_block_resov}" = "1" ] && echo "address /domain-set:block_list/#" >> "${outfile}"
	while IFS="$(printf '\037')" read -r airport_identity airport_label airport_plan
	do
		[ -n "${airport_identity}" ] || continue
		airport_group="$(smartdns_airport_group_name "${airport_identity}" 2>/dev/null)" || continue
		airport_dns_group="$(smartdns_airport_dns_group_name "${airport_identity}" 2>/dev/null)" || continue
		airport_domain_file="$(fss_airport_special_runtime_domain_file "${airport_identity}" 2>/dev/null)" || continue
		airport_dns_file="$(fss_airport_special_runtime_dns_file "${airport_identity}" 2>/dev/null)" || continue
		[ -s "${airport_dns_file}" ] && echo "domain-rules /domain-set:${airport_dns_group}/ -p #4:chnlist,#6:chnlist6 -c ping,tcp:80,tcp:443 -r first-ping -d yes -n chn" >> "${outfile}"
		[ -s "${airport_domain_file}" ] && echo "domain-rules /domain-set:${airport_group}/ -c none -n ${airport_group}" >> "${outfile}"
	done <<-EOF
$(fss_airport_special_iter_active_tsv 2>/dev/null)
	EOF
	[ -s /tmp/ss_node_domains.txt ] && echo "domain-rules /domain-set:node_direct/ -p #4:chnlist,#6:chnlist6 -c ping,tcp:80,tcp:443 -r first-ping -d yes -n chn" >> "${outfile}"
	cat >> "${outfile}" <<-'EOF'

domain-rules /domain-set:chnlist/ -p #4:chnlist,#6:chnlist6 -c ping,tcp:80,tcp:443 -r first-ping -d yes -n chn
domain-rules /domain-set:white_list/ -p #4:white_list,#6:white_list6 -c ping,tcp:80,tcp:443 -r first-ping -d yes -n chn
EOF
	cat >> "${outfile}" <<-'EOF'
domain-rules /domain-set:gfwlist/ -p #4:gfwlist,#6:gfwlist6 -c none -n gfw
domain-rules /domain-set:black_list/ -p #4:black_list,#6:black_list6 -c none -n gfw
domain-rules /domain-set:rotlist/ -p #4:router,#6:router6 -c none -n gfw
EOF
	case "${mode}" in
	1)
		cat >> "${outfile}" <<-'EOF'
speed-check-mode ping,tcp:80,tcp:443
response-mode first-ping
dualstack-ip-selection yes
dualstack-ip-selection-threshold 10
EOF
		;;
	2)
		cat >> "${outfile}" <<-'EOF'
speed-check-mode none
EOF
		;;
	3)
		cat >> "${outfile}" <<-'EOF'
speed-check-mode ping,tcp:80,tcp:443
response-mode fastest-ip
dualstack-ip-selection yes
dualstack-ip-selection-threshold 10
EOF
		;;
	esac
	cat >> "${outfile}" <<-EOF
cache-persist yes
cache-file /tmp/smartdns_${mode}.cache
prefetch-domain yes
EOF
	if [ "${mode}" = "3" ];then
		echo "serve-expired no" >> "${outfile}"
	else
		echo "serve-expired yes" >> "${outfile}"
	fi
	cat >> "${outfile}" <<-'EOF'
serve-expired-ttl 259200
serve-expired-reply-ttl 3
cache-checkpoint-time 86400
EOF
	smartdns_append_ipv6_policy "${outfile}" "${mode}"
	cat >> "${outfile}" <<-'EOF'
force-qtype-SOA 65
log-level info
log-file /tmp/smartdns_log.txt
log-size 2M
log-num 1
audit-enable yes
audit-file /tmp/smartdns_audit.txt
audit-size 2M
audit-num 1
ca-file /etc/ssl/certs/ca-certificates.crt
blacklist-ip 10.0.0.0/8
proxy-server socks5://127.0.0.1:23456 -name fancy_proxy
EOF
	while IFS="$(printf '\037')" read -r airport_identity airport_label airport_plan
	do
		[ -n "${airport_identity}" ] || continue
		airport_domain_file="$(fss_airport_special_runtime_domain_file "${airport_identity}" 2>/dev/null)" || continue
		[ -s "${airport_domain_file}" ] || continue
		echo "" >> "${outfile}"
		echo "# airport special upstreams: ${airport_label:-${airport_identity}}" >> "${outfile}"
		smartdns_append_airport_node_servers_by_identity "${outfile}" "${airport_identity}"
	done <<-EOF
$(fss_airport_special_iter_active_tsv 2>/dev/null)
	EOF
	echo "" >> "${outfile}"
	echo "# chn group upstreams" >> "${outfile}"
	smartdns_append_group_servers "${outfile}" "${mode}" "chn" "chn_group"
	echo "" >> "${outfile}"
	echo "# gfw group upstreams" >> "${outfile}"
	smartdns_append_group_servers "${outfile}" "${mode}" "gfw" "gfw_group"
	if [ "${mode}" = "3" ];then
		echo "" >> "${outfile}"
		echo "# default group upstreams" >> "${outfile}"
		smartdns_append_group_servers "${outfile}" "${mode}" "chn" "chn_default"
		smartdns_append_group_servers "${outfile}" "${mode}" "gfw" "gfw_default"
	fi
}

start_smartdns(){
	local idx=$1
	local smartdns_conf=/tmp/smartdns_fancyss.conf

	rm -rf /tmp/smartdns_log.txt
	rm -rf /tmp/smartdns_audit.txt

	if [ "${_node_change_status}" == "1" ];then
		if [ -f "/tmp/smartdns_${last_node_indx}.cache" ];then
			echo_date "smartdns缓存：检测到上次节点【${last_node_name}】上次使用的缓存，备份以备下次切换回使用。"
			mv /tmp/smartdns_${last_node_indx}.cache /tmp/smartdns_${last_node_indx}_${last_node_hash}.cache
		fi
		if [ -f "/tmp/smartdns_${idx}_${curr_node_hash}.cache" ];then
			echo_date "smartdns缓存：检测到节点【${ss_basic_name}】上次使用的缓存，加载到/tmp/smartdns_${idx}.cache..."
			mv /tmp/smartdns_${idx}_${curr_node_hash}.cache /tmp/smartdns_${idx}.cache
		else
			echo_date "smartdns缓存：没有检测到节点【${ss_basic_name}】上次使用的缓存"
		fi
	elif [ "${_node_change_status}" == "0" ];then
		if [ -f "/tmp/smartdns_${last_node_indx}.cache" ];then
			echo_date "smartdns缓存：检测到节点未切换，保留smartdns缓存文件..."
		else
			echo_date "smartdns缓存：检测到节点未切换，新建smartdns缓存文件..."
		fi
	elif [ "${_node_change_status}" == "2" ];then
		if [ -f "/tmp/smartdns_${idx}_${curr_node_hash}.cache" ];then
			echo_date "smartdns缓存：检测到节点【${ss_basic_name}】上次使用的缓存，加载到/tmp/smartdns_${idx}.cache...."
			mv /tmp/smartdns_${idx}_${curr_node_hash}.cache /tmp/smartdns_${idx}.cache
		else
			echo_date "smartdns缓存：没有检测到节点【${ss_basic_name}】上次使用的缓存!"
		fi
	fi

	echo_date "生成smartdns运行时配置：${smartdns_conf}"
	smartdns_generate_runtime_conf "${smartdns_conf}" "${idx}"

	echo_date "启动smartdns，使用smartdns配置文件：${smartdns_conf}"
	run_bg smartdns -c ${smartdns_conf}
	detect_running_status3 "smartdns" "53|7913" "0"

	local caches=$(head /tmp/smartdns_log.txt 2>/dev/null | grep "load cache file" | awk '{print $(NF-1)}')
	if [ -n "${caches}" ];then
		echo_date "smartdns启动成功，成功加载缓存：${caches}条"
	else
		echo_date "smartdns启动成功!"
	fi
}

# ============================================================================
# doge.14: 双轨 DNS（chinadns-ng × 2）—— 分流架构唯一路径
# 详见 doc/design/split-routing-architecture.md §6 与
#      doc/implementation/split-routing-implementation.md §1.6
# ----------------------------------------------------------------------------
# start_chinadns_ng_split / stop_chinadns_ng_split 接管，启动两个实例：
#   分流实例 chinadns-ng @127.0.0.1:65353 → 服务 dns_mode=split 的 Mode
#   全局实例 chinadns-ng @127.0.0.1:65354 → 服务 dns_mode=global 的 Mode
# ============================================================================

# alpha.15: 原 ss_split_collect_reject_domains() 函数已删除——chinadns-ng 不识别
# group-tag-noip 语法（V1-reviewer 实证 zfl9/chinadns-ng/src/opt.zig 找不到该选项），
# 该函数收集的 reject 域名喂给非法语法的 group 块会让 chinadns-ng 进程 exit(1)，
# 是潜伏地雷（用户一旦在 Mode 配 action=reject rule，DNS 全挂）。
# reject 语义由 xray blackhole outbound 完成（detail 见 generate_xray_json_split）。

# 生成分流 chinadns-ng 实例配置：/tmp/chinadns_ng_split.conf @ 端口 65353
# - 国内 / 国外 upstream 取自现有用户配置（ss_basic_chng_china_* / trust_*）
# - 不写 ipset（去掉 add-tagchn-ip / add-taggfw-ip / add-tagignore-ip）
# - reject 由 xray blackhole outbound 完成（alpha.15 移除原 DNS 层 group reject）
# - LAN 域名 → 127.0.0.1:65355 (dnsmasq let-port，由 split 路径在 start_dns_x
#   阶段配合 ss_basic_dns_serverx=1 把 dnsmasq 让到该端口)
# 双轨 DNS 路径直接从 dbus 读 CDNS/FDNS + 简化拼接。
# doge.13 beta D1 helper：解码 dbus base64 multi-line 值到 stdout，
# 一行一条 DNS server。给新的 ss_split_dns_*_upstream key 反查用。
__get_split_dns_lines() {
	local b64="$1"
	[ -z "${b64}" ] && return 0
	printf '%s' "${b64}" | tr -d '\n\r\t ' | base64 -d 2>/dev/null | grep -v '^$'
}

# doge.13 beta D1 helper：把多行 DNS server 列表 join 为 chinadns-ng 接受的逗号格式
__join_split_dns_lines() {
	local lines="$1"
	local out=""
	local line=""
	# 用 IFS=换行 读
	IFS='
'
	for line in ${lines}; do
		# strip 前后空白
		line=$(echo "${line}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
		[ -z "${line}" ] && continue
		# 注释行跳过
		case "${line}" in '#'*) continue ;; esac
		[ -z "${out}" ] && out="${line}" || out="${out},${line}"
	done
	unset IFS
	echo "${out}"
}

generate_chinadns_split_conf() {
	local conf="/tmp/chinadns_ng_split.conf"
	local CDNS_LINE=""
	local FDNS_LINE=""

	# 分流 DNS 上游从 ss_split_dns_china_upstream / overseas_upstream 读
	local _new_china_b64=$(dbus get ss_split_dns_china_upstream 2>/dev/null)
	local _new_oversea_b64=$(dbus get ss_split_dns_overseas_upstream 2>/dev/null)
	local _new_china_lines=$(__get_split_dns_lines "${_new_china_b64}")
	local _new_oversea_lines=$(__get_split_dns_lines "${_new_oversea_b64}")

	[ -n "${_new_china_lines}" ] && CDNS_LINE=$(__join_split_dns_lines "${_new_china_lines}")
	[ -n "${_new_oversea_lines}" ] && FDNS_LINE=$(__join_split_dns_lines "${_new_oversea_lines}")

	# 兜底：上游空时填补
	[ -z "${CDNS_LINE}" ] && CDNS_LINE="223.5.5.5"
	[ -z "${FDNS_LINE}" ] && FDNS_LINE="tcp://8.8.8.8"

	rm -f "${conf}" >/dev/null 2>&1
	cat > "${conf}" <<-EOF
		# fancyss_doge doge.12 alpha - chinadns-ng split instance
		# 监听: 127.0.0.1:${SS_SPLIT_DNS_SPLIT_PORT}
		bind-addr 127.0.0.1
		bind-port ${SS_SPLIT_DNS_SPLIT_PORT}@udp

		proxy-server socks5://127.0.0.1:23456
		# 只让 gfw 一档走代理（split 路径下未定义 black/router 这俩 user group）
		proxy-group gfw
		proxy-protocol tcp,tls

		# 国内上游
		china-dns ${CDNS_LINE}

		# 可信上游
		trust-dns ${FDNS_LINE}

		# 默认 chnlist 白名单 (默认 tag=gfw，命中 chnlist 改 tag=chn 走国内)
		chnlist-file /koolshare/ss/rules/chnlist.gz
		gfwlist-file /koolshare/ss/rules/gfwlist.gz
		default-tag gfw

		# LAN 域名 → dnsmasq fallback
		group lan
		group-dnl /tmp/fss_split_lan_dnl.txt
		group-upstream 127.0.0.1#${SS_SPLIT_DNS_LAN_PORT}

	EOF

	# 生成 LAN 域名清单（dnsmasq 让位端口）
	{
		echo "lan"
		echo "local"
		echo "asuscomm.com"
		# 路由器本机 hostname
		local rh=$(nvram get computer_name 2>/dev/null)
		[ -n "${rh}" ] && echo "${rh}"
		# LAN domain（路由器 DHCP 设的 .lan 后缀）
		local ld=$(nvram get lan_domain 2>/dev/null)
		[ -n "${ld}" ] && echo "${ld}"
	} > /tmp/fss_split_lan_dnl.txt

	# 节点服务器域名直连解析（避免 trust-dns 鸡生蛋：trust-dns 走 xray socks5，
	# 而 xray 起来需要先解析节点域名 → 死锁。沿用老 chinadns_ng.conf 的 group node 模式）
	if [ -s /tmp/ss_node_domains.txt ]; then
		cat >> "${conf}" <<-EOF
			group node
			group-dnl /tmp/ss_node_domains.txt
			group-upstream ${CDNS_LINE}

		EOF
	fi

	# reject 语义由 xray blackhole outbound 完成（详见 generate_xray_json_split
	# 注册的 out_reject outbound + routing.rules 中 action=reject → outboundTag=out_reject）。
	# DNS 层不参与 reject——alpha.15 移除原 group reject 配置块（chinadns-ng 不识别
	# group-tag-noip 语法，一旦 reject_file 非空 chinadns-ng 进程会 exit(1)，是潜伏地雷）。

	# IPv6 行为（沿用现有用户偏好）
	if [ "${ss_basic_chng_ipv6_drop_direc:-0}" = "0" ] && [ "${ss_basic_chng_ipv6_drop_proxy:-1}" = "1" ]; then
		echo "no-ipv6 tag:gfw" >> "${conf}"
	elif [ "${ss_basic_chng_ipv6_drop_direc:-0}" = "1" ] && [ "${ss_basic_chng_ipv6_drop_proxy:-1}" = "1" ]; then
		echo "no-ipv6 tag:chn,tag:gfw" >> "${conf}"
	elif [ "${ss_basic_chng_ipv6_drop_direc:-0}" = "1" ] && [ "${ss_basic_chng_ipv6_drop_proxy:-1}" = "0" ]; then
		echo "no-ipv6 tag:chn" >> "${conf}"
	fi

	cat >> "${conf}" <<-EOF

		# 过滤 dns
		filter-qtype 64,65

		# 不挂 hosts /etc/hosts：路由器 /etc/hosts 经常出现下划线/末尾点等
		# 非 RFC 1035 主机名（如华硕 TUF-AX3000_V2-48E0），chinadns-ng 严格解析
		# 会 invalid domain 报错并退出。LAN 名字解析交给 group lan → dnsmasq。

		# dns 缓存
		cache 8192
		cache-stale 86400
		cache-refresh 20
		cache-ignore asuscomm.com

		verdict-cache 8192

	EOF
}

# 生成全局 chinadns-ng 实例配置：/tmp/chinadns_ng_global.conf @ 端口 65354
# - 所有查询走 trust 组（代理）
# - 不挂 chnlist/gfwlist
# - LAN 域名 → 127.0.0.1:65355
generate_chinadns_global_conf() {
	local conf="/tmp/chinadns_ng_global.conf"
	local FDNS_LINE=""

	# 全局 DNS 上游从 ss_split_dns_global_upstream 读（单行单值，
	# 用 head -1 即可——全局模式不像分流那样有多上游平衡）。
	local _new_global_b64=$(dbus get ss_split_dns_global_upstream 2>/dev/null)
	local _new_global_lines=$(__get_split_dns_lines "${_new_global_b64}")
	[ -n "${_new_global_lines}" ] && FDNS_LINE=$(echo "${_new_global_lines}" | head -1 | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
	[ -z "${FDNS_LINE}" ] && FDNS_LINE="tcp://1.1.1.1"

	rm -f "${conf}" >/dev/null 2>&1
	cat > "${conf}" <<-EOF
		# fancyss_doge doge.12 alpha - chinadns-ng global instance
		# 监听: 127.0.0.1:${SS_SPLIT_DNS_GLOBAL_PORT}
		bind-addr 127.0.0.1
		bind-port ${SS_SPLIT_DNS_GLOBAL_PORT}@udp

		proxy-server socks5://127.0.0.1:23456
		# global 模式：所有未匹配域名 → tag=gfw → trust-dns（走代理）
		# 不能写 proxy-group trust——chinadns-ng 里没有 trust 这个 tag/group
		proxy-group gfw
		proxy-protocol tcp,tls

		# 单一海外可信上游（通过代理走）
		trust-dns ${FDNS_LINE}

		# 全局代理：所有未匹配域名打 gfw tag，全部交给 trust-dns 走代理
		# （default-tag none 是"同时查 china+trust"，并非"全走 trust"，语义不对）
		default-tag gfw

		# LAN 域名 → dnsmasq fallback
		group lan
		group-dnl /tmp/fss_split_lan_dnl.txt
		group-upstream 127.0.0.1#${SS_SPLIT_DNS_LAN_PORT}

	EOF

	cat >> "${conf}" <<-EOF
		filter-qtype 64,65
		# 不挂 hosts /etc/hosts：理由同 generate_chinadns_split_conf
		cache 4096
		cache-stale 86400
		verdict-cache 4096

	EOF
}

# doge.13 beta D5 兑现（方案 C-2）：起独立 dnsmasq 子实例占 65355，
# 只服务 chinadns 反查的 LAN 域名 (*.lan / *.local / asuscomm.com / lan_domain)。
# 主 dnsmasq (port=53) 不动；双实例完全隔离。
# chinadns split/global 两实例的 group lan 把查询投递到 127.0.0.1:${SS_SPLIT_DNS_LAN_PORT}，
# 由该子实例读 /etc/hosts 给出真实 LAN IP。
start_dnsmasq_lan_listener() {
	if netstat -lnup 2>/dev/null | grep -q ":${SS_SPLIT_DNS_LAN_PORT}\b"; then
		echo_date "dnsmasq_lan: port ${SS_SPLIT_DNS_LAN_PORT} 已被占用，跳过"
		return 0
	fi
	dnsmasq --port=${SS_SPLIT_DNS_LAN_PORT} \
		--listen-address=127.0.0.1 \
		--bind-interfaces \
		--no-resolv --no-poll \
		--addn-hosts=/etc/hosts \
		--domain-needed --bogus-priv \
		--conf-file=/dev/null \
		--pid-file=/tmp/dnsmasq_lan.pid \
		--user=nobody --group=nobody &
	sleep 1
	if netstat -lnup 2>/dev/null | grep -q ":${SS_SPLIT_DNS_LAN_PORT}\b"; then
		echo_date "dnsmasq_lan: 启动成功 (port=${SS_SPLIT_DNS_LAN_PORT})"
		dbus set ss_split_dnsmasq_lan_status="ok"
	else
		echo_date "dnsmasq_lan: 启动失败，chinadns LAN 反查可能超时"
		dbus set ss_split_dnsmasq_lan_status="down"
	fi
}

stop_dnsmasq_lan_listener() {
	if [ -f /tmp/dnsmasq_lan.pid ]; then
		local pid=$(cat /tmp/dnsmasq_lan.pid 2>/dev/null)
		if [ -n "${pid}" ]; then
			kill -9 ${pid} 2>/dev/null
			rm -f /tmp/dnsmasq_lan.pid
		fi
	fi
	dbus set ss_split_dnsmasq_lan_status="down"
}

# 启动双轨 chinadns-ng 实例
start_chinadns_ng_split() {
	echo_date "---------------- start chinadns-ng (split架构 双轨) ----------------"
	# doge.13 beta D5: 先起 dnsmasq_lan 子实例，否则 group lan 上游 127.0.0.1:65355
	# 第一次查询会立刻 NXDOMAIN/timeout（端口没人 LISTEN），chinadns 缓存住后续
	# *.lan / *.local 也会跟着失败。
	start_dnsmasq_lan_listener
	echo_date "💾 生成分流 DNS 实例配置 /tmp/chinadns_ng_split.conf ..."
	if ! generate_chinadns_split_conf; then
		echo_date "❌ 分流 DNS 实例配置生成失败！"
		dbus set ss_split_dns_split_status="down"
		stop_dnsmasq_lan_listener
		return 1
	fi
	echo_date "💾 生成全局 DNS 实例配置 /tmp/chinadns_ng_global.conf ..."
	if ! generate_chinadns_global_conf; then
		echo_date "❌ 全局 DNS 实例配置生成失败！"
		dbus set ss_split_dns_global_status="down"
		stop_dnsmasq_lan_listener
		return 1
	fi
	echo_date "⚡️ 启动分流 chinadns-ng 实例 @127.0.0.1:${SS_SPLIT_DNS_SPLIT_PORT} ..."
	rm -f /tmp/chinadns_split_err.log /tmp/chinadns_global_err.log >/dev/null 2>&1
	env -i PATH=${PATH} chinadns-ng -C /tmp/chinadns_ng_split.conf >/tmp/chinadns_split_err.log 2>&1 &
	echo_date "⚡️ 启动全局 chinadns-ng 实例 @127.0.0.1:${SS_SPLIT_DNS_GLOBAL_PORT} ..."
	env -i PATH=${PATH} chinadns-ng -C /tmp/chinadns_ng_global.conf >/tmp/chinadns_global_err.log 2>&1 &
	sleep 1
	# alpha 诊断：分别检查两个端口是否在 LISTEN，而不是只看 pidof（pidof 任一活着都会过）
	local split_up=0 global_up=0
	netstat -lnup 2>/dev/null | grep -q ":${SS_SPLIT_DNS_SPLIT_PORT}\b" && split_up=1
	netstat -lnup 2>/dev/null | grep -q ":${SS_SPLIT_DNS_GLOBAL_PORT}\b" && global_up=1
	if [ "${split_up}" = "1" ] && [ "${global_up}" = "1" ]; then
		dbus set ss_split_dns_split_status="ok"
		dbus set ss_split_dns_global_status="ok"
		echo_date "🆗 chinadns-ng 双实例启动完成。"
	else
		[ "${split_up}" = "1" ] && dbus set ss_split_dns_split_status="ok" || dbus set ss_split_dns_split_status="down"
		[ "${global_up}" = "1" ] && dbus set ss_split_dns_global_status="ok" || dbus set ss_split_dns_global_status="down"
		echo_date "❌ chinadns-ng 双实例启动失败！(split=${split_up} global=${global_up})"
		# alpha 诊断：把 stderr 内容回显到 WebUI 日志，方便定位配置错
		if [ -s /tmp/chinadns_split_err.log ]; then
			echo_date "--- 分流实例错误输出 ---"
			while IFS= read -r line; do echo_date "  ${line}"; done < /tmp/chinadns_split_err.log
		fi
		if [ -s /tmp/chinadns_global_err.log ]; then
			echo_date "--- 全局实例错误输出 ---"
			while IFS= read -r line; do echo_date "  ${line}"; done < /tmp/chinadns_global_err.log
		fi
	fi
	echo_date "------------------------------------------------------------------"
}

# 停止双轨 chinadns-ng 实例（由 stop_dns_process 或 ss_pre_stop 在 split 路径调用）
stop_chinadns_ng_split() {
	killall chinadns-ng >/dev/null 2>&1
	rm -f /tmp/chinadns_ng_split.conf /tmp/chinadns_ng_global.conf >/dev/null 2>&1
	dbus set ss_split_dns_split_status="down"
	dbus set ss_split_dns_global_status="down"
	# doge.13 beta D5: 停 chinadns 后顺手停 dnsmasq_lan 子实例（互锁启停语义）
	stop_dnsmasq_lan_listener
}

parse_dns_addr_port(){
	local dns_raw="$1"
	local default_port="${2:-53}"
	local addr=""
	local port="${default_port}"
	local explicit_port="0"

	case "${dns_raw}" in
	*#*)
		addr="${dns_raw%#*}"
		port="${dns_raw##*#}"
		explicit_port="1"
		;;
	\[*\]:*)
		addr="${dns_raw%\]:*}"
		addr="${addr#\[}"
		port="${dns_raw##*\]:}"
		explicit_port="1"
		;;
	*)
		if echo "${dns_raw}" | grep -Eq '^([0-9]{1,3}[.]){3}[0-9]{1,3}:[0-9]+$'; then
			addr="${dns_raw%:*}"
			port="${dns_raw##*:}"
			explicit_port="1"
		else
			addr="${dns_raw}"
		fi
		;;
	esac

	addr="${addr#\[}"
	addr="${addr%\]}"
	printf '%s\n%s\n%s\n' "${addr}" "${port}" "${explicit_port}"
}

format_dns_endpoint(){
	local dns_raw="$1"
	local default_port="${2:-53}"
	local addr port explicit_port

	{
		read -r addr
		read -r port
		read -r explicit_port
	} <<-EOF
	$(parse_dns_addr_port "${dns_raw}" "${default_port}")
	EOF

	__valid_ip46 "${addr}"
	case "$?" in
	0)
		[ "${explicit_port}" = "1" ] && echo "${addr}#${port}" || echo "${addr}"
		;;
	1)
		[ "${explicit_port}" = "1" ] && echo "${addr}#${port}" || echo "${addr}"
		;;
	*)
		echo "${dns_raw}"
		;;
	esac
}

detect_domain() {
	domain1=$(echo $1 | grep -E "^https://|^http://|/")
	domain2=$(echo $1 | grep -E "\.")
	if [ -n "${domain1}" -o -z "${domain2}" ]; then
		# url
		return 1
	else
		# domain
		return 0
	fi
}

is_domain(){
	[ -n "$1" ] || return 1
	__valid_ip46 "$1" >/dev/null 2>&1
	case "$?" in
	0|1)
		return 1
		;;
	esac
	echo $1 | awk 'BEGIN {regex = "^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$"} $0 ~ regex { print }'
}

get_proxy_type(){
	case "$1" in
	udp)
		echo "udp-relay"
		;;
	tcp|dot)
		echo "socks5"
		;;
	esac
}

get_dns_selected_net(){
	local type="$1"
	local numb="$2"
	eval echo \$ss_basic_chng_${type}_net_${numb}_typ
}

get_dns_effective_net(){
	local type="$1"
	local numb="$2"
	local net="$(get_dns_selected_net "${type}" "${numb}")"
	echo "${net}"
}

get_dns_para(){
	local type=$1
	local numb=$2
	local para=$3
	local addr="8.8.8.8"
	local port="53"
	local explicit_port=""

	# udp, tcp, dot
	local net="$(get_dns_selected_net "${type}" "${numb}")"
	
	local dns_opt=$(eval echo \$ss_basic_chng_${type}_${net}_${numb}_opt)
	local dns_usr=$(eval echo \$ss_basic_chng_${type}_${net}_${numb}_usr)
	
	if [ "${dns_opt}" == "99" ];then
		{
			read -r addr
			read -r port
			read -r explicit_port
		} <<-EOF
		$(parse_dns_addr_port "${dns_usr}")
		EOF
		[ -n "${addr}" ] || addr="8.8.8.8"
	else
		local addr="${dns_opt}"
	fi

	if [ "${para}" == "addr" ];then
		echo ${addr}
	elif [ "${para}" == "port" ];then
		echo ${port}
	fi
	
}

iter_dns_udp_relay_targets(){
	local sep="$(printf '\037')"
	if [ "${ss_basic_dns_plan}" = "2" ] && proxy_core_supports_udp;then
		smartdns_iter_gfw_udp_relays
	fi
}

has_dns_udp_relay_targets(){
	[ -n "$(iter_dns_udp_relay_targets | sed -n '1p')" ]
}

gen_xray_dns_inbound(){
	local config_file="$1"
	local sep="$(printf '\037')"
	local relay_port addr port provider description

	[ -n "${config_file}" ] || return 1
	has_dns_udp_relay_targets || return 0

	while IFS="${sep}" read -r relay_port addr port provider description
	do
		[ -n "${relay_port}" ] || continue
		cat >>"${config_file}" <<-EOF
			{
				"tag": "dns_udp_${relay_port}",
				"listen": "127.0.0.1",
				"port": ${relay_port},
				"protocol": "dokodemo-door",
				"settings": {
					"address": "${addr}",
					"port": ${port},
					"network": "udp",
					"timeout": 0,
					"followRedirect": false
				}
			},
		EOF
	done <<-EOF
$(iter_dns_udp_relay_targets)
EOF
	return 0
}

append_xray_dns_relay_inbounds(){
	local config_file="$1"
	local tmp_file="${config_file}.dnsrelay"
	local add_file="${config_file}.dnsrelay.add"
	local sep="$(printf '\037')"
	local relay_port addr port provider description
	local entry_count=0

	[ -f "${config_file}" ] || return 1
	has_dns_udp_relay_targets || return 0

	cat > "${add_file}" <<-'EOF'
[]
EOF
	while IFS="${sep}" read -r relay_port addr port provider description
	do
		[ -n "${relay_port}" ] || continue
		if cat "${config_file}" | run jq -e --argjson port "${relay_port}" '.inbounds[]? | select(.protocol == "dokodemo-door" and .port == $port)' >/dev/null 2>&1; then
			continue
		fi
		if [ "${entry_count}" -eq 0 ];then
			cat > "${add_file}" <<-EOF
[
  {
    "tag": "dns_udp_${relay_port}",
    "listen": "127.0.0.1",
    "port": ${relay_port},
    "protocol": "dokodemo-door",
    "settings": {
      "address": "${addr}",
      "port": ${port},
      "network": "udp",
      "timeout": 0,
      "followRedirect": false
    }
  }
]
EOF
		else
			if ! cat "${add_file}" | run jq '. += [{
				"tag": "dns_udp_'"${relay_port}"'",
				"listen": "127.0.0.1",
				"port": '"${relay_port}"',
				"protocol": "dokodemo-door",
				"settings": {
					"address": "'"${addr}"'",
					"port": '"${port}"',
					"network": "udp",
					"timeout": 0,
					"followRedirect": false
				}
			}]' > "${add_file}.tmp"; then
				rm -rf "${add_file}" "${add_file}.tmp" >/dev/null 2>&1
				return 1
			fi
			mv -f "${add_file}.tmp" "${add_file}"
		fi
		entry_count=$((entry_count + 1))
	done <<-EOF
$(iter_dns_udp_relay_targets)
EOF

	if [ "${entry_count}" -eq 0 ];then
		rm -rf "${add_file}" >/dev/null 2>&1
		return 0
	fi
	if ! cat "${config_file}" | run jq --slurpfile relays "${add_file}" '.inbounds += $relays[0]' > "${tmp_file}"; then
		rm -rf "${tmp_file}" "${add_file}" >/dev/null 2>&1
		return 1
	fi
	mv -f "${tmp_file}" "${config_file}"
	rm -rf "${add_file}" >/dev/null 2>&1
	return 0
}

append_xray_ipv6_tproxy_inbound() {
	local config_file="$1"
	local tmp_file="${config_file}.ipv6"
	ipv6_proxy_enabled || return 0
	[ -f "${config_file}" ] || return 1
	# Reuse the existing 3333 transparent proxy inbound for both IPv4 and IPv6.
	if cat "${config_file}" | run jq -e '.inbounds[]? | select(.protocol == "dokodemo-door" and .port == 3333)' >/dev/null 2>&1; then
		return 0
	fi
	if ! cat "${config_file}" | run jq '.inbounds += [{"listen":"0.0.0.0","port":3333,"protocol":"dokodemo-door","settings":{"network":"tcp,udp","followRedirect":true}}]' >"${tmp_file}"; then
		rm -rf "${tmp_file}" >/dev/null 2>&1
		return 1
	fi
	mv "${tmp_file}" "${config_file}"
}

get_dns(){
	local type=$1
	local numb=$2

	# udp, tcp, dot
	local net="$(get_dns_selected_net "${type}" "${numb}")"
	local eff_net="$(get_dns_effective_net "${type}" "${numb}")"
	
	local dns_opt=$(eval echo \$ss_basic_chng_${type}_${net}_${numb}_opt)
	local dns_usr=$(eval echo \$ss_basic_chng_${type}_${net}_${numb}_usr)

	if [ "${type}" = "trust" ] && ! proxy_core_supports_udp && [ "${net}" = "udp" ];then
		return 0
	fi

	if [ "${eff_net}" == "dot" ];then
		eff_net=tls
	fi

	if [ "${net}_${type}_${numb}" == "udp_trust_1" ];then
		local _port=1055
	elif [ "${net}_${type}_${numb}" == "udp_trust_2" ];then
		local _port=1056
	elif [ "${net}_${type}_${numb}" == "udp_trust_3" ];then
		local _port=1057
	fi
	
	if [ "${dns_opt}" == "99" ];then
		dns_usr=$(format_dns_endpoint "${dns_usr}")

		if [ "${eff_net}" == "udp" ];then
			if [ "${type}" == "trust" ];then
				echo "udp://127.0.0.1#${_port}?count=0?life=0"
			else
				echo "udp://${dns_usr}?count=0?life=0"
			fi
		else
			echo "${eff_net}://${dns_usr}"
		fi
	else
		if [ "${eff_net}" == "udp" ];then
			if [ "${type}" == "trust" ];then
				echo "udp://127.0.0.1#${_port}?count=0?life=0"
			else
				echo "udp://${dns_opt}?count=0?life=0"
			fi
		else
			echo "${eff_net}://${dns_opt}"
		fi
	fi
}

add_white_black() {
	# 白名单： 
	# 1. ignlist	 (ipv4 + ipv6保留地址, host地址如: router.asuscomm.com)
	# 2. chnlist	 (大陆域名，由网络整理，由fancyss更新推送)
	# 3. chnlist_ext (大陆域名-扩展，由fancyss整理 + 推送)
	# 4. chnroute   （ip/cidr, ，由网络整理，由fancyss更新推送）
	# 4. white_list （doamin, user define）
	# 5. white_list （ip/cidr, user define）
	
	# 黑名单： 
	# 1. gfwlist	 (被墙域名，来自网络整理，由fancyss更新推送)
	# 2. gfwlist_ext (被墙名单-扩展：包括ip、域名，由fancyss更新推送)
	# 3. black_list （doamin, user define）
	# 4. black_list （ip/cidr, user define）
	#
	# 黑名单-机内
	# 1. router		 (在nat output中单独处理，控制机内走tcp代理的名单)
	# ----------------------------------------------------------------------
	# 1.  gfw黑名单模式 ：
	#     构想：{gfwlist}走代理，其他走直连
	#     加黑：{gfwlist,black_list}走代理，其他走直连
	#     加白：{white_list}走直连，{gfwlist,black_list}走代理，其他走直连（white black冲突的话，以white为优先）
	#           {white_list}需要在{gfwlist}之前，不然不能达到{white_list}不走代理的目的
	#	  问题：{ignlist}理论上不需要处理，但是{gfwlist,black_list}是有可能解析到127.0.0.1的，会导致出问题，所以还是需要处理下：
	#     修正：{ignlist,white_list}走直连，{gfwlist,black_list}走代理，其他走直连
	#      DNS：{white_list domain}走chinadns-ng dnl组1解析，添加解析到ipset：white_list，{white_list ip}直接加入到ipset：white_list
	#           {black_list domain}走chinadns-ng dnl组2解析，添加解析到ipset：black_list，{black_list ip}直接加入到ipset：black_list
	#
	# 2.  大陆白名单模式（白名单优先模式，fancyss一直采用的方式）：
	#     构想：{ignlist,chnlist,chnroute}走直连，其余走代理
	#           先匹配白名单不走代理，再匹配黑名单走代理，目的先保证国内访问正常，再去翻墙。
	#			但是如果某个域名的三级域名aaa.gfw.com被墙，二级域名gfw.com没有被墙
	#			此时，gfw.com和aaa.gfw.com都会被{chnlist}匹配到，如果在iptables中，使用白名单优先模式，则都会走直连。
	#     设计：{black_list}走代理，{ignlist,chnlist,chnroute,white_list}走直连，其余走代理
	#	  问题：{ignlist}理论上在{black_list}之后，但是{black_list}是有可能解析到127.0.0.1，导致出问题，所以还是需要处理下：
	#     修正：{ignlist}走直连，{black_list}走代理，{chnlist,chnroute,white_list}走直连，其余走代理
	#           1. 修正后：如果不存在black_list，则与原设计一样
	#           2. 修正后：如果不存在black_list和white_list，则与原构想一样
	#
	# 3.  大陆白名单模式（黑名单优先模式，ss-tproxy采用的方式）：
	#     构想：{gfwlist}走代理，{ignlist,chnlist,chnroute}走直连，其余走代理
	#           目的保证走代理的域名，比如aaa.gfw.com被墙，但是gfw.com没有被墙
	#           此时aaa.gfw.com被{gfwlist}匹配后顺利走代理，gfw.com被{chnlist}匹配后不走代理
	#     设计：{gfwlist,black_list}走代理，{ignlist,chnlist,chnroute,white_list}走直连，其余走代理
	#	  问题：{ignlist}理论上在{gfwlist}之后，但是{gfwlist}是有可能解析到127.0.0.1，导致出问题，所以还是需要处理下：
	#     修正：{ignlist}走直连，{gfwlist,black_list}走代理，{chnlist,chnroute,white_list}走直连，其余走代理
	#
	#     大陆白名单模式总结：
	# 2   修正：{ignlist}走直连，{black_list}走代理，{chnlist,chnroute,white_list}走直连，其余走代理
	# 3   修正：{ignlist}走直连，{gfwlist,black_list}走代理，{chnlist,chnroute,white_list}走直连，其余走代理
	# 			修正两者差别仅仅在于3.1黑名单模式优先情况下多了gfwlist的一次匹配
	# 			但是如果某个{white_list}域名存在于{gfwlist}中，则会导致用户白名单失效
	#			而2.1白名单优先情况下不存在此问题，所以2.1效果最好
	# 			
	# 2.1 最终：SHADOWSOCKS链: 访问控制 ──┬─── SHADOWSOCKS_CHN链: {ignlist}走直连，{black_list}走代理，{chnlist,chnroute,white_list}走直连，其余走代理
	# 			                          ├─── SHADOWSOCKS_GFW链: {ignlist,white_list}走直连，{gfwlist,black_list}走代理，其他走直连
	#									  └─── SHADOWSOCKS_GLO链: {ignlist}走直连，其他走代理
	#
	# 			稍作调整，可以把{ignlist}全部调到前面
	#
	# 2.1 最终：SHADOWSOCKS链: {ignlist} -访问控制 ──┬─── SHADOWSOCKS_CHN链: {black_list}走代理，{chnlist,chnroute,white_list}走直连，其余走代理
	# 			                          			 ├─── SHADOWSOCKS_GFW链: {white_list}走直连，{gfwlist,black_list}走代理，其他走直连
	#									  			 ├─── SHADOWSOCKS_GLO链: {white_list}走直连，其他走代理
	#									  			 └─── SHADOWSOCKS_HOM链: {black_list}走代理，{gfwlist,white_list}走直连，其他走代理
	# 			
	# note-1：大陆白名单模式时，{black_list domain}走chinadns-ng dnl组1解析，{black_list ip}直接加入到ipset，{white_list domain}走chinadns-ng dnl组2解析
	# 4.  全局模式：{ignlist}走直连，其他走代理
	# ----------------------------------------------------------------------
	#
	# 回国模式：
	# 在国外访问大陆网站时，可能会出现ip区域限制等问题，导致无法正常使用大陆网络服务
	# 此时可以使用"回国模式"，通过代理回到国内，摆脱ip区域限制等问题，原理与翻墙类似
	# 1. 回国模式1 ：{black_list}走代理，{gfwlist,white_list}走直连，其他走代理
	#    {gfwlist,white_list}用国外当地DNS解析，其他走可信DNS解析（为了cdn）
	#	 {black_list}  dln1  可信DNS
	#	 {white_list}  dln2  本地DNS
	#	 {gfwlist} 	   gfw   本地DNS
	#	 default tag   chn   可信DNS
	# 2. 回国模式2 ：{white_list}走直连，{chnlist,black_list}走代理，其他走直连
	#    {chnlist,black_list}可信度DNS解析（为了cdn），其余用国外当地DNS解析
	#	 {white_list}  dln1  本地DNS
	#	 {black_list}  dln2  可信DNS
	#	 {chnlist} 	   chn   可信DNS
	#	 default tag   gfw   本地DNS

	# remove 
	rm -rf /tmp/black_list.txt
	rm -rf /tmp/white_list.txt
	rm -rf /tmp/block_list.txt
	rm -rf /tmp/chnlist.txt
	rm -rf /tmp/gfwlist.txt
	rm -rf /tmp/chnroute.txt
	rm -rf /tmp/chnroute6.txt

	# copy gfwlist.txt & chnlist.txt to tmp
	echo_date "创建/tmp/chnlist.txt 和 /tmp/gfwlist.txt！"
	gzip -d -c /koolshare/ss/rules/chnlist.gz >/tmp/chnlist.txt
	gzip -d -c /koolshare/ss/rules/gfwlist.gz >/tmp/gfwlist.txt
	#cp -rf /koolshare/ss/rules/chnlist.txt /tmp/chnlist.txt
	#cp -rf /koolshare/ss/rules/gfwlist.txt /tmp/gfwlist.txt
	
	# {router} foreign dns ip go proxy inside router
	ipset -! add router 8.8.8.8 >/dev/null 2>&1
	ipset -! add router 8.8.4.4 >/dev/null 2>&1
	ipset -! add router 1.1.1.1 >/dev/null 2>&1
	ipset -! add router 9.9.9.9 >/dev/null 2>&1
	ipset -! add router 9.9.9.10 >/dev/null 2>&1
	ipset -! add router 9.9.9.11 >/dev/null 2>&1
	ipset -! add router 149.112.112.112 >/dev/null 2>&1
	ipset -! add router 149.112.112.11 >/dev/null 2>&1
	ipset -! add router 149.112.112.10 >/dev/null 2>&1

	# {ignlist},ip: 保留 IP 段（RFC1918 / loopback / link-local / multicast / etc，必须直连）
	# FORK doge.11: 拆 R1（保留段）与 G1（中国公共 DNS），G1 受 ss_basic_direct_chndns 开关控制
	# 详见 doc/design/protocol-roadmap.md §7 doge.11 的 G1/R1 条目
	local ip_lan_reserve="0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 192.18.0.0/15 224.0.0.0/4 240.0.0.0/4"
	# FORK doge.11: 中国公共 DNS（223.5/223.6 阿里 / 114.114 / 1.2.4.8 dnspod / 117.50.* onedns / 180.76 百度 / 119.29 腾讯）
	local ip_lan_chndns="223.5.5.5 223.6.6.6 114.114.114.114 114.114.115.115 1.2.4.8 210.2.4.8 117.50.11.11 117.50.22.22 180.76.76.76 119.29.29.29"
	echo_date "应用ignlist（保留 IP 段）"
	for ip in ${ip_lan_reserve}
	do
		ipset -! add ignlist $ip >/dev/null 2>&1
	done
	# FORK doge.11: 默认开启（向后兼容），用户可关
	if [ "${ss_basic_direct_chndns:-1}" = "1" ]; then
		echo_date "应用ignlist（国内公共 DNS 强制直连）"
		for ip in ${ip_lan_chndns}
		do
			ipset -! add ignlist $ip >/dev/null 2>&1
		done
	else
		echo_date "ℹ️ 国内公共 DNS 强制直连已关闭（ss_basic_direct_chndns=0），223.5.5.5/114.114.114.114 等不再加入 ignlist"
	fi

	ipset -! add ignlist6 ::1/128 >/dev/null 2>&1
	ipset -! add ignlist6 fe80::/10 >/dev/null 2>&1
	
	# {black_list}, telegram ip
	if [ "${ss_basic_mode}" != "6" ]; then
		ip_tg="149.154.0.0/16 91.108.4.0/22 91.108.56.0/24 109.239.140.0/24 67.198.55.0/24"
		for ip in ${ip_tg}; do
			ipset -! add black_list $ip >/dev/null 2>&1
		done
	fi

	# {black_list}, black ip
	if [ -n "${ss_wan_black_ip}" ]; then
		ss_wan_black_ip=$(echo ${ss_wan_black_ip} | base64_decode | sed '/\#/d')
		echo_date "应用IP/CIDR黑名单"
		for ip in ${ss_wan_black_ip}; do
			ipset -! add black_list ${ip} >/dev/null 2>&1
		done
	fi

	# {black_list}, black domain
	echo_date "生成域名黑名单！"
	{
		printf '%s\n' ip.sb api.skk.moe ip.skk.moe ipinfo.io ip-api.com us.ip111.cn
		[ "${ss_basic_proxy_newb}" = "1" ] && printf '%s\n' "bing.com"
	} > /tmp/black_list.txt
	if [ -n "${ss_wan_black_domain}" ]; then
		fss_b64_decode "${ss_wan_black_domain}" | awk '
			{
				gsub(/\r/, "")
				sub(/#.*/, "")
				for (i = 1; i <= NF; i++) {
					domain = tolower($i)
					gsub(/^[*.]+/, "", domain)
					if (domain ~ /^[a-z0-9._-]+(\.[a-z0-9._-]+)+$/ && !seen[domain]++) {
						print domain
					}
				}
			}
		' >> /tmp/black_list.txt
	fi

	# {white_list}, white ip
	[ -n "${ISP_DNS1}" ] && ISP_DNS_a="${ISP_DNS1}" || ISP_DNS_a=""
	[ -n "${IFIP_DNS2}" ] && ISP_DNS_b="${ISP_DNS2}" || ISP_DNS_b=""
	local ALL_NODE_DOMAINS=$(dbus list ssconf|grep _server_|awk -F"=" '{print $NF}'|sort -u|grep -E "([0-9]{1,3}[\.]){3}[0-9]{1,3}")
	ss_wan_white_ip=$(echo ${ss_wan_white_ip} | base64_decode | sed '/\#/d')
	echo_date "应用IP/CIDR白名单"
	for ip in ${ss_wan_white_ip} ${ALL_NODE_DOMAINS}
	do
		ipset -! add white_list $ip >/dev/null 2>&1
	done

	# {white_list}, white domain
	true >/tmp/white_list.txt
	echo_date "生成域名白名单！"
	local ALL_NODE_DOMAINS=$(dbus list ssconf|grep _server_|awk -F"=" '{print $NF}'|sort -u|grep -Ev "([0-9]{1,3}[\.]){3}[0-9]{1,3}")
	local wanwhitedomains=$(echo ${ss_wan_white_domain} | base64_decode | sed '/^#/d' | grep "." | sort -u)
	local ALL_WHITE_DOMAINS=$(echo ${wanwhitedomains} ${ALL_NODE_DOMAINS})
	if [ -n "${ALL_WHITE_DOMAINS} " ]; then
		for wan_white_domain in ${ALL_WHITE_DOMAINS}; do
			if [ -n "$(is_domain ${wan_white_domain})" ]; then
				echo ${wan_white_domain} >>/tmp/white_list.txt
			fi
		done
	fi	

	# fork toggle（doge.9）：「直连梅林软件中心 / koolcenter 生态域名」开关
	# UI 入口：黑白名单标签页顶部第一行（hint id 202）
	# 默认开启（install.sh::install_now 在首次安装/升级时幂等置 1）
	# 上游硬编码的 4 个域名（apple.com / microsoft.com / dns.msftncsi.com / worldtimeapi.org）
	# 经验证全部失效或鸡肋，已移除。详见 doc/implementation/asusgo-whitelist-toggle.md
	#   - apple.com / microsoft.com：在 chnlist 里，chinadns-ng 优先级 chnlist > group white，
	#     IP 进 chnlist ipset 而非 white_list ipset，GLO 模式下 white_list 失效
	#   - dns.msftncsi.com：NCSI 的 HTTP 测试用 www.msftncsi.com（不同后缀，本规则覆盖不到）
	#   - worldtimeapi.org：anycast IP，强制直连不快于代理；fancyss 代码无引用
	if [ "${ss_basic_direct_asusgo:-1}" = "1" ]; then
		for wan_white_domain2 in "koolcenter.com" "ddnsto.com" "koolddns.com" "ngrok.wang"; do
			echo "${wan_white_domain2}" >>/tmp/white_list.txt
		done
	fi

	# {block_list}
	cp -rf /koolshare/ss/rules/block_list.txt /tmp
}

create_dnsmasq_conf() {
	# 0. delete pre settings
	rm -rf /tmp/custom.conf
	rm -rf /jffs/configs/dnsmasq.d/custom.conf
	rm -rf /jffs/scripts/dnsmasq.postconf
	rm -rf /jffs/scripts/dnsmasq-sdn.postconf

	# 2. custom dnsmasq settings by user
	if [ -n "${ss_dnsmasq}" ]; then
		echo_date "添加自定义dnsmasq设置到/tmp/custom.conf"
		echo "${ss_dnsmasq}" | base64_decode | sort -u >>/tmp/custom.conf
	fi

	#ln_conf
	if [ -f /tmp/custom.conf ]; then
		#echo_date 创建域自定义dnsmasq配置文件软链接到/jffs/configs/dnsmasq.d/custom.conf
		ln -sf /tmp/custom.conf /jffs/configs/dnsmasq.d/custom.conf
	fi

	# echo_date 创建dnsmasq.postconf软连接到/jffs/scripts/文件夹.
	[ ! -L "/jffs/scripts/dnsmasq.postconf" ] && ln -sf /koolshare/ss/rules/dnsmasq.postconf /jffs/scripts/dnsmasq.postconf

	VLAN_NU=$(ifconfig | grep -E "^br"|grep -v "br0"|wc -l)
	if [ "${VLAN_NU}" -ge "1" ]; then
		ln -sf /koolshare/ss/rules/dnsmasq.postconf /jffs/scripts/dnsmasq-sdn.postconf
	fi
}

auto_start() {
	[ ! -L "/koolshare/init.d/S99shadowsocks.sh" ] && ln -sf /koolshare/ss/ssconfig.sh /koolshare/init.d/S99shadowsocks.sh
	[ ! -L "/koolshare/init.d/N99shadowsocks.sh" ] && ln -sf /koolshare/ss/ssconfig.sh /koolshare/init.d/N99shadowsocks.sh
}

# FORK: cut in doge.10, see doc/design/protocol-roadmap.md §2
: <<'FORK_CUT_DOGE10'
start_ssr_redir() {
	echo_date "开启ssr-redir进程，用于透明代理."
	BIN=rss-redir
	ARG_OBFS=""
	if [ "${mangle}" == "1" ]; then
		# tcp udp go ss
		echo_date "${BIN}的 tcp 走${BIN}."
		echo_date "${BIN}的 udp 走${BIN}."
		fire_redir "rss-redir -c ${CONFIG_FILE} -u"
	else
		# tcp only go ss
		echo_date "${BIN}的 tcp 走${BIN}."
		echo_date "${BIN}的 udp 未开启."
		fire_redir "rss-redir -c ${CONFIG_FILE}"
	fi
	echo_date "${BIN} 启动完毕！"

	# start socks5，socks5端口默认提供，但目前监听在127.0.0.1，所有协议都需要开socks5端口，以前适用于dns tcp远程解析，未来用户开放给用户
	start_ssr_local
}
FORK_CUT_DOGE10

fire_redir() {
	local ARG_1 ARG_2 ARG_3
	if [ "$ss_basic_mcore" == "1" -a "${LINUX_VER}" != "26" ]; then
		echo_date "$BIN开启$THREAD线程支持."
		local i=1
		while [ $i -le $THREAD ]; do
			run_bg $1 $ARG_1 $ARG_2 $ARG_3 -f /var/run/ssr_$i.pid
			let i++
		done
	else
		run_bg $1 -f /var/run/ssr.pid
	fi
}

get_path_empty() {
	if [ -n "$1" ]; then
		echo [\"$1\"]
	else
		echo [\"/\"]
	fi
}


get_host_empty() {
	if [ -n "$1" ]; then
		echo [\"$1\"]
	else
		echo [\"\"]
	fi
}

get_function_switch() {
	case "$1" in
	1)
		echo "true"
		;;
	0 | *)
		echo "false"
		;;
	esac
}

get_reverse_switch() {
	case "$1" in
	1)
		echo "false"
		;;
	0|*)
		echo "true"
		;;
	esac
}

get_grpc_multimode(){
	case "$1" in
	multi)
		echo true
		;;
	gun|*)
		echo false
		;;
	esac
}

get_ws_header() {
	if [ -n "$1" ]; then
		echo {\"Host\": \"$1\"}
	else
		echo null
	fi
}

get_xray_ws_settings() {
	local _path="$1"
	local _host="$2"
	if [ -z "${_path}" -a -z "${_host}" ]; then
		echo "{}"
	else
		cat <<-EOF
			{
				"path": $(get_value_null "${_path}"),
				"host": $(get_value_null "${_host}")
			}
		EOF
	fi
}

get_host() {
	if [ -n "$1" ]; then
		echo [\"$1\"]
	else
		echo null
	fi
}

get_value_null(){
	if [ -n "$1" ]; then
		echo \"$1\"
	else
		echo null
	fi
}

get_value_speed(){
	if [ -n "$1" ]; then
		echo \"${1}mbps\"
	else
		echo null
	fi
}

get_value_empty(){
	if [ -n "$1" ]; then
		echo \"$1\"
	else
		echo \"\"
	fi
}

get_value_congestion(){
	if [ -n "${ss_basic_hy2_up}" -a -n "${ss_basic_hy2_dl}" ]; then
		if [ -z "${ss_basic_hy2_cg}" ];then
			# 之前的版本没有开放此选项，帮用户设置为brutal
			echo \"brutal\"
		else
			# 上下行都设置了且正确，此时可以使用用户选择的congestion
			echo \"$1\"
		fi
	elif [ -z "${ss_basic_hy2_up}" -a -z "${ss_basic_hy2_dl}" ]; then
		echo \"bbr\"
	fi
}

get_hy2_port(){
	local _match1=$(echo $1 | grep -Eo ",")
	local _match2=$(echo $1 | grep -Eo "-")
	if [ -z "${_match1}" -a -z "${_match2}" ]; then
		# single port
		echo "$1"
	else
		# multi port or port range
		echo null
	fi
}

get_hy2_udphop_port(){
	local _match1=$(echo $1 | grep -Eo ",")
	local _match2=$(echo $1 | grep -Eo "-")
	if [ -z "${_match1}" -a -z "${_match2}" ]; then
		# single port
		echo \"\"
	else
		# multi port or port range
		echo \"$1\"
	fi
}

get_hy2_quic_params(){
	local _port="$1"
	local _congestion="$(get_value_congestion ${ss_basic_hy2_cg})"
	local _brutal_up="$(get_value_speed ${ss_basic_hy2_up})"
	local _brutal_down="$(get_value_speed ${ss_basic_hy2_dl})"
	local _hop_ports="$(get_hy2_udphop_port "${_port}")"
	local _need_comma=""

	if [ "${_congestion}" = "null" -a "${_brutal_up}" = "null" -a "${_brutal_down}" = "null" -a "${_hop_ports}" = "\"\"" ]; then
		echo "null"
		return 0
	fi

	echo "{"
	if [ "${_congestion}" != "null" ]; then
		echo "						\"congestion\": ${_congestion}"
		_need_comma=","
	fi
	if [ "${_brutal_up}" != "null" ]; then
		echo "						${_need_comma}\"brutalUp\": ${_brutal_up}"
		_need_comma=","
	fi
	if [ "${_brutal_down}" != "null" ]; then
		echo "						${_need_comma}\"brutalDown\": ${_brutal_down}"
		_need_comma=","
	fi
	if [ "${_hop_ports}" != "\"\"" ]; then
		echo "						${_need_comma}\"udpHop\": {"
		echo "							\"ports\": ${_hop_ports},"
		echo "							\"interval\": 30"
		echo "						}"
	fi
	echo "					}"
}

append_hy2_finalmask(){
	local _target_file="$1"
	local _quic_params="$(get_hy2_quic_params "${ss_basic_hy2_port}")"

	if [ "${_quic_params}" = "null" -a ! \( "${ss_basic_hy2_obfs}" = "1" -a -n "${ss_basic_hy2_obfs_pass}" \) ]; then
		return 0
	fi

	cat >>"${_target_file}" <<-EOF
					,"finalmask": {
	EOF
	if [ "${_quic_params}" != "null" ]; then
		cat >>"${_target_file}" <<-EOF
						"quicParams": ${_quic_params}
		EOF
	fi
	if [ "${ss_basic_hy2_obfs}" = "1" -a -n "${ss_basic_hy2_obfs_pass}" ]; then
		if [ "${_quic_params}" != "null" ]; then
			cat >>"${_target_file}" <<-EOF
						,
			EOF
		fi
		cat >>"${_target_file}" <<-EOF
						"udp": [
						{
							"type": "salamander",
							"settings": {
								"password": "${ss_basic_hy2_obfs_pass}"
							}
						}]
		EOF
	fi
	cat >>"${_target_file}" <<-EOF
					}
	EOF
}

creat_vmess_json() {
	if [ -z "{WEB_ACTION}" ]; then
		if [ -n "${WAN_ACTION}" ]; then
			echo_date "检测到网络拨号/开机触发启动，不创建vmess配置文件，使用上次的配置文件！"
			return 0
		fi
	else
		echo_date "创建vmess配置文件到${VMESS_CONFIG_FILE}"
	fi
	
	rm -rf "${VMESS_CONFIG_TEMP}"
	rm -rf "${VMESS_CONFIG_FILE}"
	if [ "${ss_basic_v2ray_use_json}" != "1" ]; then
		echo_date 生成vmess协议配置文件...
		local tcp="null"
		local kcp="null"
		local ws="null"
		local h2="null"
		local qc="null"
		local gr="null"
		local tls="null"

		if [ "$ss_basic_v2ray_mux_enable" == "1" -a -z "$ss_basic_v2ray_mux_concurrency" ];then
			local ss_basic_v2ray_mux_concurrency=8
		fi

		if [ "$ss_basic_v2ray_mux_enable" != "1" ];then
			local ss_basic_v2ray_mux_concurrency="-1"
		fi
		
		if [ -z "$ss_basic_v2ray_network_security" ];then
			local ss_basic_v2ray_network_security="none"
		fi

		if [ "$ss_basic_v2ray_network_security" == "none" ];then
			ss_basic_v2ray_network_security_ai=""
			ss_basic_v2ray_network_security_alpn_h2=""
			ss_basic_v2ray_network_security_alpn_http=""
			ss_basic_v2ray_network_security_sni=""
		fi

		local alpn_h2=${ss_basic_v2ray_network_security_alpn_h2}
		local alpn_ht=${ss_basic_v2ray_network_security_alpn_http}

		if [ "${alpn_h2}" == "1" -a "${alpn_ht}" == "1" ];then
			local apln="[\"h2\",\"http/1.1\"]"
		elif [ "${alpn_h2}" != "1" -a "${alpn_ht}" == "1" ];then
			local apln="[\"http/1.1\"]"
		elif [ "${alpn_h2}" == "1" -a "${alpn_ht}" != "1" ];then
			local apln="[\"h2\"]"
		elif [ "${alpn_h2}" != "1" -a "${alpn_ht}" != "1" ];then
			local apln="null"
		fi

		# 如果sni空，host不空，用host代替
		if [ -z "${ss_basic_v2ray_network_security_sni}" ];then
			if [ -n "${ss_basic_v2ray_network_host}" ];then
				local ss_basic_v2ray_network_security_sni="${ss_basic_v2ray_network_host}"
			else
				local ss_basic_v2ray_network_security_sni=""
			fi
		fi

		# 如果sni空，host空，用server domain代替
		if [ -z "${ss_basic_v2ray_network_security_sni}" -a -z "${ss_basic_v2ray_network_host}" ];then
			# 判断是否域名，是就填入
			tmp=$(__valid_ip "${ss_basic_server_orig}")
			if [ $? == 0 ]; then
				# server is ip address format
				local ss_basic_v2ray_network_security_sni=""
			else
				# likely to be domain
				local ss_basic_v2ray_network_security_sni="${ss_basic_server_orig}"
			fi
		fi

		if [ "${ss_basic_v2ray_network_security}" == "tls" ];then
			local tls="{
					\"alpn\": ${apln}
					,\"serverName\": $(get_value_null $ss_basic_v2ray_network_security_sni)
					}"
		else
			local tls="null"
		fi

		local ss_basic_v2ray_network_host_raw="${ss_basic_v2ray_network_host}"
		local ss_basic_v2ray_network_host_list="${ss_basic_v2ray_network_host_raw}"
		# incase multi-domain input
		if [ "$(echo $ss_basic_v2ray_network_host_list | grep ",")" ]; then
			ss_basic_v2ray_network_host_list=$(echo $ss_basic_v2ray_network_host_list | sed 's/,/", "/g')
		fi

		case "$ss_basic_v2ray_network" in
		tcp)
			if [ "$ss_basic_v2ray_headtype_tcp" == "http" ]; then
				local tcp="{
					\"header\": {
					\"type\": \"http\"
					,\"request\": {
					\"version\": \"1.1\"
					,\"method\": \"GET\"
					,\"path\": $(get_path_empty $ss_basic_v2ray_network_path)
					,\"headers\": {
					\"Host\": $(get_host_empty $ss_basic_v2ray_network_host_list),
					\"User-Agent\": [
					\"Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/55.0.2883.75 Safari/537.36\"
					,\"Mozilla/5.0 (iPhone; CPU iPhone OS 10_0_2 like Mac OS X) AppleWebKit/601.1 (KHTML, like Gecko) CriOS/53.0.2785.109 Mobile/14A456 Safari/601.1.46\"
					]
					,\"Accept-Encoding\": [\"gzip, deflate\"]
					,\"Connection\": [\"keep-alive\"]
					,\"Pragma\": \"no-cache\"
					}
					}
					}
					}"
			else
				local tcp="null"
			fi
			;;
		kcp)
			local kcp="{
				\"mtu\": 1350
				,\"tti\": 50
				,\"uplinkCapacity\": 12
				,\"downlinkCapacity\": 100
				,\"congestion\": false
				,\"readBufferSize\": 2
				,\"writeBufferSize\": 2
				,\"header\": {
				\"type\": \"$ss_basic_v2ray_headtype_kcp\"
				}
				,\"seed\": $(get_value_null $ss_basic_v2ray_kcp_seed)
				}"
			;;
		ws)
			local ws="$(get_xray_ws_settings "${ss_basic_v2ray_network_path}" "${ss_basic_v2ray_network_host_raw}")"
			;;
		h2)

			local h2="{
				\"path\": $(get_value_empty $ss_basic_v2ray_network_path)
				,\"host\": $(get_host $ss_basic_v2ray_network_host_list)
				}"
			;;
		quic)
			local qc="{
				\"security\": $(get_value_empty $ss_basic_v2ray_network_host_raw),
				\"key\": $(get_value_empty $ss_basic_v2ray_network_path),
				\"header\": {
				\"type\": \"${ss_basic_v2ray_headtype_quic}\"
				}
				}"
			;;
		grpc)
			local gr="{
				\"serviceName\": $(get_value_empty $ss_basic_v2ray_network_path),
				\"authority\": $(get_value_empty $ss_basic_v2ray_grpc_authority),
				\"multiMode\": $(get_grpc_multimode ${ss_basic_v2ray_grpc_mode})
				}"
			;;
		esac
		# log area
		cat >"${VMESS_CONFIG_TEMP}" <<-EOF
			{
			"log": {
				"access": "none",
				"error": "none",
				"loglevel": "none"
			},
		EOF
		
		# inbounds area (23456 for socks5)
		cat >>"$VMESS_CONFIG_TEMP" <<-EOF
			"inbounds": [
		EOF

		# when user use udp trust dns in chinadns-ng
		gen_xray_dns_inbound ${VMESS_CONFIG_TEMP}
		
		cat >>"$VMESS_CONFIG_TEMP" <<-EOF
				{
					"port": 23456,
					"listen": "127.0.0.1",
					"protocol": "socks",
					"settings": {
						"auth": "noauth",
						"udp": true,
						"ip": "127.0.0.1"
					}
				},
				{
					"listen": "0.0.0.0",
					"port": 3333,
					"protocol": "dokodemo-door",
					"settings": {
						"network": "tcp,udp",
						"followRedirect": true
					}
				}
			],
		EOF
		# outbounds area
		cat >>"$VMESS_CONFIG_TEMP" <<-EOF
			"outbounds": [
				{
					"tag": "proxy",
					"protocol": "vmess",
					"settings": {
						"vnext": [
							{
								"address": "${ss_basic_server}",
								"port": $ss_basic_port,
								"users": [
									{
										"id": "$ss_basic_v2ray_uuid"
										,"alterId": $ss_basic_v2ray_alterid
										,"security": "$ss_basic_v2ray_security"
									}
								]
							}
						]
					},
					"streamSettings": {
						"network": "$ss_basic_v2ray_network"
						,"security": "$ss_basic_v2ray_network_security"
						,"tlsSettings": $tls
						,"tcpSettings": $tcp
						,"kcpSettings": $kcp
						,"wsSettings": $ws
						,"httpSettings": $h2
						,"quicSettings": $qc
						,"grpcSettings": $gr
					},
					"mux": {
						"enabled": $(get_function_switch $ss_basic_v2ray_mux_enable),
						"concurrency": $ss_basic_v2ray_mux_concurrency
					}
				}
			]
			}
		EOF
		echo_date "解析vmess协议配置文件..."
		run jq 'del(.. | nulls)' ${VMESS_CONFIG_TEMP} > /tmp/jq_strip_tmp.txt 2>/dev/null && mv /tmp/jq_strip_tmp.txt ${VMESS_CONFIG_TEMP}
		run jq --tab . ${VMESS_CONFIG_TEMP} >/tmp/jq_para_tmp.txt 2>&1
		if [ "$?" != "0" ];then
			echo_date "json配置解析错误，错误信息如下："
			echo_date $(cat /tmp/jq_para_tmp.txt) 
			echo_date "请更正你的错误然后重试！！"
			rm -rf /tmp/jq_para_tmp.txt
			close_in_five flag
		fi
		run jq --tab . $VMESS_CONFIG_TEMP >"${VMESS_CONFIG_FILE}"
		echo_date "$vmess协议配置文件写入成功到${VMESS_CONFIG_FILE}"
		if ! append_xray_ipv6_tproxy_inbound "${VMESS_CONFIG_FILE}"; then
			echo_date "错误：追加IPv6透明代理入口到${VCORE_NAME}配置文件失败！"
			close_in_five flag
		fi
	else
		echo_date "使用自定义的${VCORE_NAME} json配置文件..."
		echo "$ss_basic_v2ray_json" | base64_decode >"$VMESS_CONFIG_TEMP"
		local OB=$(cat "$VMESS_CONFIG_TEMP" | run jq .outbound)
		local OBS=$(cat "$VMESS_CONFIG_TEMP" | run jq .outbounds)

		# 兼容旧格式：outbound
		if [ "$OB" != "null" ]; then
			OUTBOUNDS=$(cat "$VMESS_CONFIG_TEMP" | run jq .outbound)
		fi
		
		# 新格式：outbound[]
		if [ "$OBS" != "null" ]; then
			OUTBOUNDS=$(cat "$VMESS_CONFIG_TEMP" | run jq .outbounds[0])
		fi
		local TEMPLATE="{
							\"log\": {
								\"access\": \"none\",
								\"error\": \"none\",
								\"loglevel\": \"none\"
							},
							\"inbounds\": [
								{
									\"port\": 23456,
									\"listen\": \"127.0.0.1\",
									\"protocol\": \"socks\",
									\"settings\": {
										\"auth\": \"noauth\",
										\"udp\": true,
										\"ip\": \"127.0.0.1\",
										\"clients\": null
									},
									\"streamSettings\": null
								},
								{
									\"listen\": \"0.0.0.0\",
									\"port\": 3333,
									\"protocol\": \"dokodemo-door\",
									\"settings\": {
										\"network\": \"tcp,udp\",
										\"followRedirect\": true
									}
								}
							]
						}"
		echo_date "解析${VCORE_NAME}配置文件..."
		echo ${TEMPLATE} | run jq --argjson args "$OUTBOUNDS" '. + {outbounds: [$args]}' >"$VMESS_CONFIG_FILE"
		echo_date "${VCORE_NAME}配置文件写入成功到$VMESS_CONFIG_FILE"
		if [ -n "${ss_basic_server}" ];then
			rewrite_xray_like_outbound_server "${VMESS_CONFIG_FILE}" "${ss_basic_server}"
		fi
		if ! append_xray_dns_relay_inbounds "${VMESS_CONFIG_FILE}"; then
			echo_date "错误：追加DNS UDP relay入口到${VCORE_NAME}配置文件失败！"
			close_in_five flag
		fi
		if ! append_xray_ipv6_tproxy_inbound "${VMESS_CONFIG_FILE}"; then
			echo_date "错误：追加IPv6透明代理入口到${VCORE_NAME}配置文件失败！"
			close_in_five flag
		fi

		if [ -n "${ss_basic_server_orig}" ]; then
			fss_set_current_node_field_plain server "${ss_basic_server_orig}"
		else
			echo_date "+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"
			echo_date "+       没有检测到你的${VCORE_NAME}服务器地址，如果你确定你的配置是正确的        +"
			echo_date "+   请自行将${VCORE_NAME}服务器的ip地址填入【IP/CIDR】黑名单中，以确保正常使用   +"
			echo_date "+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"
		fi
	fi

	# test v2ray Configuration generated from user json then run by xray
	echo_date "测试${VCORE_NAME}配置文件...."
	test_xray_conf $VMESS_CONFIG_FILE
	case $? in
	0)
		echo_date "测试结果：${_test_ret}"
		echo_date "${VCORE_NAME}配置文件通过测试!!!"
		;;
	2)
		echo_date "测试结果：${_test_ret}"
		echo_date "${VCORE_NAME}配置文件没有通过测试，尝试删除fingerprint配置后重试！"
		run jq 'del(.. | .fingerprint?)' $VMESS_CONFIG_FILE | run sponge $VMESS_CONFIG_FILE
		test_xray_conf $VMESS_CONFIG_FILE
		case $? in
		0)
			echo_date "测试结果：${_test_ret}"
			echo_date "${VCORE_NAME}配置文件通过测试!!!"
			;;
		*)
			echo_date "测试结果：${_test_ret}"
			echo_date "${VCORE_NAME}配置文件没有通过测试，请检查设置!!!"
			rm -rf "$VMESS_CONFIG_TEMP"
			rm -rf "$VMESS_CONFIG_FILE"
			close_in_five flag
			;;
		esac
		;;
	*)
		echo_date "测试结果：${_test_ret}"
		echo_date "${VCORE_NAME}配置文件没有通过测试，请检查设置!!!"
		rm -rf "$VMESS_CONFIG_TEMP"
		rm -rf "$VMESS_CONFIG_FILE"
		close_in_five flag
		;;
	esac
}

creat_xray_ss_json() {
	if [ -z "${WEB_ACTION}" ]; then
		# 非web提交
		if [ -n "${WAN_ACTION}" ]; then
			echo_date "检测到网络拨号/开机触发启动，不创建$(__get_type_abbr_name)配置文件，使用上次的配置文件！"
			return 0
		fi
	else
		echo_date "创建$(__get_type_abbr_name)节点配置文件到${VLESS_CONFIG_FILE}"
	fi

	# log area
	cat >"${SS_CONFIG_TEMP}" <<-EOF
		{
		"log": {
			"access": "none",
			"error": "none",
			"loglevel": "none"
		},
	EOF
	
	# inbounds area (23456 for socks5)
	cat >>"${SS_CONFIG_TEMP}" <<-EOF
		"inbounds": [
	EOF

	# when user use udp trust dns in chinadns-ng
	gen_xray_dns_inbound ${SS_CONFIG_TEMP}
	
	cat >>"${SS_CONFIG_TEMP}" <<-EOF
			{
				"port": 23456,
				"listen": "127.0.0.1",
				"protocol": "socks",
				"settings": {
					"auth": "noauth",
					"udp": true,
					"ip": "127.0.0.1"
				}
			},
			{
				"listen": "0.0.0.0",
				"port": 3333,
				"protocol": "dokodemo-door",
				"settings": {
					"network": "tcp,udp",
					"followRedirect": true
				}
			}
		],
	EOF
	# outbounds area
	if [ "${ss_basic_ss_obfs}" == "http" -o "${ss_basic_ss_obfs}" == "tls" ]; then
		# start obfs-local first
		echo_date "开启simple-obfs混淆..."

		if [ "${ss_basic_tfo}" == "1" -a "${LINUX_VER}" != "26" ]; then
			local OBFS_ARG="--fast-open"
			echo 3 >/proc/sys/net/ipv4/tcp_fastopen
		else
			local OBFS_ARG=""
		fi

		local obfs_port=$(get_rand_port)
		if [ -n "${ss_basic_ss_obfs_host}" ]; then
			run_bg obfs-local -s ${ss_basic_server} -p ${ss_basic_port} -l ${obfs_port} --obfs ${ss_basic_ss_obfs} --obfs-host ${ss_basic_ss_obfs_host} ${OBFS_ARG} -f /var/run/obfs_local.pid
		else
			run_bg obfs-local -s ${ss_basic_server} -p ${ss_basic_port} -l ${obfs_port} --obfs ${ss_basic_ss_obfs} ${OBFS_ARG} -f /var/run/obfs_local.pid
		fi
		detect_running_status obfs-local /var/run/obfs_local.pid
		# gen xray outbound
		cat >>"${SS_CONFIG_TEMP}" <<-EOF
			"outbounds": [
				{
					"tag": "proxy",
					"protocol": "shadowsocks",
					"settings": {
						"servers": [
							{
								"address": "127.0.0.1"
								,"port": ${obfs_port}
								,"password": "${ss_basic_password}"
								,"method": "${ss_basic_method}"
								,"uot": true
							}
						]
					},
					"streamSettings": {
						"network": "raw"
					},
					"sockopt": {
						"tcpFastOpen": $(get_function_switch ${ss_basic_tfo}),
						"tcpMptcp": false,
						"tcpcongestion": "bbr"
					}
				}
			]
			}
		EOF
	else
		# gen xray outbound
		cat >>"${SS_CONFIG_TEMP}" <<-EOF
			"outbounds": [
				{
					"tag": "proxy",
					"protocol": "shadowsocks",
					"settings": {
						"servers": [
							{
								"address": "${ss_basic_server}"
								,"port": ${ss_basic_port}
								,"password": "${ss_basic_password}"
								,"method": "${ss_basic_method}"
								,"uot": false
							}
						]
					},
					"streamSettings": {
						"network": "raw"
					},
					"sockopt": {
						"tcpFastOpen": $(get_function_switch ${ss_basic_tfo}),
						"tcpMptcp": false,
						"tcpcongestion": "bbr"
					}			
				}
			]
			}
		EOF
	fi
	
	echo_date "解析Xray配置文件..."
	run jq 'del(.. | nulls)' ${SS_CONFIG_TEMP} > /tmp/jq_strip_tmp.txt 2>/dev/null && mv /tmp/jq_strip_tmp.txt ${SS_CONFIG_TEMP}
	if [ "${LINUX_VER}" == "26" ]; then
		sed -i '/tcpFastOpen/d' ${SS_CONFIG_TEMP} 2>/dev/null
	fi
	run jq --tab . $SS_CONFIG_TEMP >/tmp/jq_para_tmp.txt 2>&1
	if [ "$?" != "0" ];then
		echo_date "json配置解析错误，错误信息如下："
		echo_date $(cat /tmp/jq_para_tmp.txt) 
		echo_date "请更正你的错误然后重试！！"
		rm -rf /tmp/jq_para_tmp.txt
		close_in_five flag
	fi
	run jq --tab . ${SS_CONFIG_TEMP} >${SS_CONFIG_FILE}
	echo_date "Xray配置文件写入成功到${SS_CONFIG_FILE}"
	if ! append_xray_ipv6_tproxy_inbound "${SS_CONFIG_FILE}"; then
		echo_date "错误：追加IPv6透明代理入口到Xray配置文件失败！"
		close_in_five flag
	fi
}

creat_vless_json() {
	if [ -z "{WEB_ACTION}" ]; then
		if [ -n "${WAN_ACTION}" ]; then
			echo_date "检测到网络拨号/开机触发启动，不创建$(__get_type_abbr_name)配置文件，使用上次的配置文件！"
			return 0
		fi
	else
		echo_date "创建$(__get_type_abbr_name)节点配置文件到${VLESS_CONFIG_FILE}"
	fi

	local tmp xray_server_ip
	rm -rf "${VLESS_CONFIG_TEMP}"
	rm -rf "${VLESS_CONFIG_FILE}"
	if [ "${ss_basic_xray_use_json}" != "1" ]; then
		echo_date "生成Xray配置文件..."
		local tcp="null"
		local kcp="null"
		local ws="null"
		local h2="null"
		local qc="null"
		local gr="null"
		local tls="null"
		local reali="null"
		local xht="null"
		local htup="null"

		if [ -z "$ss_basic_xray_network_security" ];then
			local ss_basic_xray_network_security="none"
		fi
		[ -z "${ss_basic_xray_prot}" ] && ss_basic_xray_prot="vless"
		[ -z "${ss_basic_xray_encryption}" ] && ss_basic_xray_encryption="none"

		if [ "${ss_basic_xray_network_security}" == "none" ];then
			if [ "${ss_basic_xray_prot}" != "vless" ] || [ "${ss_basic_xray_encryption}" = "none" ];then
				ss_basic_xray_flow=""
			fi
			ss_basic_xray_network_security_ai=""
			ss_basic_xray_network_security_alpn_h2=""
			ss_basic_xray_network_security_alpn_http=""
			ss_basic_xray_network_security_sni=""
		fi

		#if [ "${ss_basic_xray_network_security}" == "tls" ];then
		#	ss_basic_xray_flow=""
		#fi

		local alpn_h2=${ss_basic_xray_network_security_alpn_h2}
		local alpn_ht=${ss_basic_xray_network_security_alpn_http}
		if [ "${alpn_h2}" == "1" -a "${alpn_ht}" == "1" ];then
			local apln="[\"h2\",\"http/1.1\"]"
		elif [ "${alpn_h2}" != "1" -a "${alpn_ht}" == "1" ];then
			local apln="[\"http/1.1\"]"
		elif [ "${alpn_h2}" == "1" -a "${alpn_ht}" != "1" ];then
			local apln="[\"h2\"]"
		elif [ "${alpn_h2}" != "1" -a "${alpn_ht}" != "1" ];then
			local apln="null"
		fi

		# 如果sni空，host不空，用host代替
		if [ -z "${ss_basic_xray_network_security_sni}" ];then
			if [ -n "${ss_basic_xray_network_host}" ];then
				local ss_basic_xray_network_security_sni="${ss_basic_xray_network_host}"
			else
				local ss_basic_xray_network_security_sni=""
			fi
		fi

		# 如果sni空，host空，用server domain代替
		if [ -z "${ss_basic_xray_network_security_sni}" -a -z "${ss_basic_xray_network_host}" ];then
			# 判断是否域名，是就填入
			tmp=$(__valid_ip "${ss_basic_server_orig}")
			if [ $? == 0 ]; then
				# server is ip address format
				local ss_basic_xray_network_security_sni=""
			else
				# likely to be domain
				local ss_basic_xray_network_security_sni="${ss_basic_server_orig}"
			fi
		fi

		if [ "${ss_basic_xray_network_security}" == "tls" ];then
			if [ -z "${ss_basic_xray_fingerprint}" ];then
				echo_date "fingerprint为空，默认使用chrome作为指纹"
				ss_basic_xray_fingerprint="chrome"
				fss_set_current_node_field_plain xray_fingerprint "chrome"
			fi
			# allowInsecure removed by Xray (2026.x); always use pinnedPeerCertSha256/verifyPeerCertByName (FORK doge.14)
			local tls="{
					\"alpn\": ${apln}
					,\"serverName\": $(get_value_null ${ss_basic_xray_network_security_sni})
					,\"fingerprint\": $(get_value_empty ${ss_basic_xray_fingerprint})
					,\"pinnedPeerCertSha256\": $(get_value_empty ${ss_basic_xray_pcs})
					,\"verifyPeerCertByName\": $(get_value_empty ${ss_basic_xray_vcn})
					}"
		else
			local tls="null"
		fi

		if [ "${ss_basic_xray_network_security}" == "reality" ];then
			local reali="{
					\"show\": $(get_function_switch $ss_basic_xray_show)
					,\"fingerprint\": $(get_value_empty $ss_basic_xray_fingerprint)
					,\"serverName\": $(get_value_null $ss_basic_xray_network_security_sni)
					,\"publicKey\": $(get_value_null $ss_basic_xray_publickey)
					,\"shortId\": $(get_value_empty $ss_basic_xray_shortid)
					,\"spiderX\": $(get_value_empty $ss_basic_xray_spiderx)
					}"
		else
			local reali="null"		
		fi
		local ss_basic_xray_network_host_raw="${ss_basic_xray_network_host}"
		local ss_basic_xray_network_host_list="${ss_basic_xray_network_host_raw}"
		# incase multi-domain input
		if [ "$(echo $ss_basic_xray_network_host_list | grep ",")" ]; then
			ss_basic_xray_network_host_list=$(echo ${ss_basic_xray_network_host_list} | sed 's/,/", "/g')
		fi

		case "${ss_basic_xray_network}" in
		tcp)
			if [ "${ss_basic_xray_headtype_tcp}" == "http" ]; then
				local tcp="{
					\"header\": {
					\"type\": \"http\"
					,\"request\": {
					\"version\": \"1.1\"
					,\"method\": \"GET\"
					,\"path\": $(get_path_empty $ss_basic_xray_network_path)
					,\"headers\": {
					\"Host\": $(get_host_empty $ss_basic_xray_network_host_list),
					\"User-Agent\": [
					\"Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/55.0.2883.75 Safari/537.36\"
					,\"Mozilla/5.0 (iPhone; CPU iPhone OS 10_0_2 like Mac OS X) AppleWebKit/601.1 (KHTML, like Gecko) CriOS/53.0.2785.109 Mobile/14A456 Safari/601.1.46\"
					]
					,\"Accept-Encoding\": [\"gzip, deflate\"]
					,\"Connection\": [\"keep-alive\"]
					,\"Pragma\": \"no-cache\"
					}
					}
					}
					}"
			else
				local tcp="null"
			fi
			;;
		kcp)
			local kcp="{
				\"mtu\": 1350
				,\"tti\": 50
				,\"uplinkCapacity\": 12
				,\"downlinkCapacity\": 100
				,\"congestion\": false
				,\"readBufferSize\": 2
				,\"writeBufferSize\": 2
				,\"header\": {
				\"type\": \"$ss_basic_xray_headtype_kcp\"
				}
				,\"seed\": $(get_value_null $ss_basic_xray_kcp_seed)
				}"
			;;
		ws)
			local ws="$(get_xray_ws_settings "${ss_basic_xray_network_path}" "${ss_basic_xray_network_host_raw}")"
			;;
		h2)
			local h2="{
				\"path\": $(get_value_empty $ss_basic_xray_network_path)
				,\"host\": $(get_host $ss_basic_xray_network_host_list)
				}"
			;;
		quic)
			local qc="{
				\"security\": $(get_value_empty $ss_basic_xray_network_host_raw),
				\"key\": $(get_value_empty $ss_basic_xray_network_path),
				\"header\": {
				\"type\": \"${ss_basic_xray_headtype_quic}\"
				}
				}"
			;;
		grpc)
			local gr="{
				\"serviceName\": $(get_value_empty $ss_basic_xray_network_path),
				\"authority\": $(get_value_empty $ss_basic_xray_grpc_authority),
				\"multiMode\": $(get_grpc_multimode ${ss_basic_xray_grpc_mode})
				}"
			;;
		xhttp)
			local xht="{
				\"path\": $(get_value_empty $ss_basic_xray_network_path)
				,\"host\": $(get_value_empty $ss_basic_xray_network_host_raw)
				,\"mode\": \"${ss_basic_xray_xhttp_mode}\"
				}"
			;;
		httpupgrade)
			local htup="{
				\"path\": $(get_value_empty $ss_basic_xray_network_path)
				,\"host\": $(get_value_empty $ss_basic_xray_network_host_raw)
				}"
			;;
		esac
		# log area
		cat >"${VLESS_CONFIG_TEMP}" <<-EOF
			{
			"log": {
				"access": "none",
				"error": "none",
				"loglevel": "none"
			},
		EOF
		
		# inbounds area (23456 for socks5)
		cat >>"${VLESS_CONFIG_TEMP}" <<-EOF
			"inbounds": [
		EOF

		# when user use udp trust dns in chinadns-ng
		gen_xray_dns_inbound ${VLESS_CONFIG_TEMP}

		# continue
		cat >>"${VLESS_CONFIG_TEMP}" <<-EOF
				{
					"port": 23456,
					"listen": "127.0.0.1",
					"protocol": "socks",
					"settings": {
						"auth": "noauth",
						"udp": true,
						"ip": "127.0.0.1"
					}
				},
				{
					"listen": "0.0.0.0",
					"port": 3333,
					"protocol": "dokodemo-door",
					"settings": {
						"network": "tcp,udp",
						"followRedirect": true
					}
				}
			],
		EOF
		
		# outbounds area
		local xray_user_json
		if [ "${ss_basic_xray_prot}" = "vless" ];then
			xray_user_json=$(cat <<-EOF
									"id": "$ss_basic_xray_uuid"
									,"encryption": "$ss_basic_xray_encryption"
									,"flow": $(get_value_null $ss_basic_xray_flow)
			EOF
			)
		else
			[ -z "${ss_basic_xray_encryption}" -o "${ss_basic_xray_encryption}" = "none" ] && ss_basic_xray_encryption="auto"
			xray_user_json=$(cat <<-EOF
									"id": "$ss_basic_xray_uuid"
									,"security": "$ss_basic_xray_encryption"
			EOF
			)
		fi
		cat >>"${VLESS_CONFIG_TEMP}" <<-EOF
			"outbounds": [
				{
					"tag": "proxy",
					"protocol": "${ss_basic_xray_prot}",
					"settings": {
						"vnext": [
							{
								"address": "${ss_basic_server}",
								"port": ${ss_basic_port},
								"users": [
									{
${xray_user_json}
									}
								]
							}
						]
					},
					"streamSettings": {
						"network": "$ss_basic_xray_network"
						,"security": "$ss_basic_xray_network_security"
						,"tlsSettings": $tls
						,"realitySettings": $reali
						,"tcpSettings": $tcp
						,"kcpSettings": $kcp
						,"wsSettings": $ws
						,"httpSettings": $h2
						,"quicSettings": $qc
						,"grpcSettings": $gr
						,"httpupgradeSettings": $htup
						,"xhttpSettings": $xht
						,"sockopt": {"tcpFastOpen": $(get_function_switch ${ss_basic_tfo})}
					},
					"mux": {
						"enabled": false,
						"concurrency": -1
					}
				}
			]
			}
		EOF
		echo_date "解析Xray配置文件..."
		run jq 'del(.. | nulls)' ${VLESS_CONFIG_TEMP} > /tmp/jq_strip_tmp.txt 2>/dev/null && mv /tmp/jq_strip_tmp.txt ${VLESS_CONFIG_TEMP}
		if [ "${LINUX_VER}" == "26" ]; then
			sed -i '/tcpFastOpen/d' ${VLESS_CONFIG_TEMP} 2>/dev/null
		fi
		run jq --tab . $VLESS_CONFIG_TEMP >/tmp/jq_para_tmp.txt 2>&1
		if [ "$?" != "0" ];then
			echo_date "json配置解析错误，错误信息如下："
			echo_date $(cat /tmp/jq_para_tmp.txt) 
			echo_date "请更正你的错误然后重试！！"
			rm -rf /tmp/jq_para_tmp.txt
			close_in_five flag
		fi
		run jq --tab . ${VLESS_CONFIG_TEMP} >${VLESS_CONFIG_FILE}
		echo_date "Xray配置文件写入成功到${VLESS_CONFIG_FILE}"
		if ! append_xray_ipv6_tproxy_inbound "${VLESS_CONFIG_FILE}"; then
			echo_date "错误：追加IPv6透明代理入口到Xray配置文件失败！"
			close_in_five flag
		fi
	else
		echo_date "使用自定义的Xray json配置文件..."
		echo "$ss_basic_xray_json" | base64_decode >"$VLESS_CONFIG_TEMP"
		local OB=$(cat "$VLESS_CONFIG_TEMP" | run jq .outbound)
		local OBS=$(cat "$VLESS_CONFIG_TEMP" | run jq .outbounds)

		# 兼容旧格式：outbound
		if [ "$OB" != "null" ]; then
			OUTBOUNDS=$(cat "$VLESS_CONFIG_TEMP" | run jq .outbound)
		fi
		
		# 新格式：outbound[]
		if [ "$OBS" != "null" ]; then
			OUTBOUNDS=$(cat "$VLESS_CONFIG_TEMP" | run jq .outbounds[0])
		fi
		local TEMPLATE="{
							\"log\": {
								\"access\": \"none\",
								\"error\": \"none\",
								\"loglevel\": \"none\"
							},
							\"inbounds\": [
								{
									\"port\": 23456,
									\"listen\": \"127.0.0.1\",
									\"protocol\": \"socks\",
									\"settings\": {
										\"auth\": \"noauth\",
										\"udp\": true,
										\"ip\": \"127.0.0.1\",
										\"clients\": null
									},
									\"streamSettings\": null
								},
								{
									\"listen\": \"0.0.0.0\",
									\"port\": 3333,
									\"protocol\": \"dokodemo-door\",
									\"settings\": {
										\"network\": \"tcp,udp\",
										\"followRedirect\": true
									}
								}
							]
						}"
		
		echo_date "解析Xray配置文件..."
		echo ${TEMPLATE} | run jq --argjson args "$OUTBOUNDS" '. + {outbounds: [$args]}' >"${VLESS_CONFIG_FILE}"
		echo_date "Xray配置文件写入成功到${VLESS_CONFIG_FILE}"
		if [ -n "${ss_basic_server}" ];then
			rewrite_xray_like_outbound_server "${VLESS_CONFIG_FILE}" "${ss_basic_server}"
		fi
		if ! append_xray_dns_relay_inbounds "${VLESS_CONFIG_FILE}"; then
			echo_date "错误：追加DNS UDP relay入口到Xray配置文件失败！"
			close_in_five flag
		fi
		if ! append_xray_ipv6_tproxy_inbound "${VLESS_CONFIG_FILE}"; then
			echo_date "错误：追加IPv6透明代理入口到Xray配置文件失败！"
			close_in_five flag
		fi

		if [ -n "${ss_basic_server_orig}" ]; then
			fss_set_current_node_field_plain server "${ss_basic_server_orig}"
		else
			echo_date "+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"
			echo_date "+       没有检测到你的Xray服务器地址，如果你确定你的配置是正确的        +"
			echo_date "+   请自行将Xray服务器的ip地址填入【IP/CIDR】黑名单中，以确保正常使用   +"
			echo_date "+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"
		fi
	fi
	
	# test xray Configuration run by xray
	test_xray_conf $VLESS_CONFIG_FILE
	case $? in
	0)
		echo_date "测试结果：${_test_ret}"
		echo_date "Xray配置文件通过测试!!!"
		;;
	2)
		#echo_date "测试结果：${_test_ret}"
		echo_date "Xray配置文件没有通过测试，尝试删除fingerprint配置后重试！"
		run jq 'del(.. | .fingerprint?)' $VLESS_CONFIG_FILE | run sponge $VLESS_CONFIG_FILE
		test_xray_conf $VLESS_CONFIG_FILE
		case $? in
		0)
			echo_date "测试结果：${_test_ret}"
			echo_date "Xray配置文件通过测试!!!"
			;;
		*)
			echo_date "测试结果：${_test_ret}"
			echo_date "Xray配置文件没有通过测试，请检查设置!!!"
			rm -rf "$VLESS_CONFIG_TEMP"
			rm -rf "$VLESS_CONFIG_FILE"
			close_in_five flag
			;;
		esac
		;;
	*)
		echo_date "测试结果：${_test_ret}"
		echo_date "Xray配置文件没有通过测试，请检查设置!!!"
		rm -rf "$VLESS_CONFIG_TEMP"
		rm -rf "$VLESS_CONFIG_FILE"
		close_in_five flag
		;;
	esac
}

# ============================================================================
# FORK doge.12 alpha: generate_xray_json_split
# 详见 doc/design/split-routing-architecture.md §4
# ----------------------------------------------------------------------------
# 策略：
#   1) apply_ss() 已经依据 ss_basic_type 调用对应 creat_xxx_json() 产出基线
#      /koolshare/ss/xray.json（包含 socks 入站:23456 + 主节点 outbound）
#   2) 本函数用 jq 在该基线上：
#      - 重写 inbounds 数组：保留 socks/DNS-relay 入站，新增 per-active-Mode
#        dokodemo-door TPROXY 入站（带 sniffing）
#      - 重写 outbounds：保留主节点 outbound 作为 "out_main"，按去重算法补齐
#        direct / reject 等其他 outbound；doge.13 beta D12 起 proxy_node:X /
#        proxy_chain:Y:X 通过 fss_split_build_node_outbound_json 真实 build 出
#        out_node_X / out_chain_Y_X / chain_front_Y outbound（不再 collapse 到 out_main）。
#        helper 未部署或 build 失败时 graceful fallback 到 out_main collapse。
#      - 重写 routing.rules：按 §4.4 顺序铺 RFC1918→黑白名单→Mode rules→兜底
#   3) 失败回退：jq 任意一步失败则保留基线 xray.json，写 warning dbus key
# doge.13 beta 改造点：
#   - D12 sentinel: ss_split_action_to_tag 新增 proxy_main case
#   - D12 解除 collapse: proxy_node:X / proxy_chain:Y:X 各自 build 独立 outbound
#   - D8 端口 gate 解除: 全部已声明 Mode 都进 active_indices + 端口分配
#   - D5 dnsmasq_lan 子实例: start_chinadns_ng_split 内 hook
#   - D1 chinadns 新 key: 优先读 ss_split_dns_china/overseas/global_upstream
# ============================================================================

# 把 rule 文件解析为 jq 友好的 JSON 数组（domains + ip_v4 + ip_v6）
# 用法：ss_split_rule_to_json <rfile> <outfile>
#   - outfile 必传——rule_1.txt 可能 11 万行 chnlist (~1.6MB JSON)，灌进 shell 变量
#     必爆 busybox `[` 内置 ARG_MAX ~128KB（alpha.12 实地踩坑）。
#   - 不留 stdout fallback：hnd_v8 busybox 1.25 路由器 `/dev/stdout` 不存在，
#     默认值会被当物理文件路径写垃圾到 /dev/ 下（alpha.13 dry-run 实测）。
ss_split_rule_to_json() {
	local rfile="$1"
	local outfile="$2"
	if [ -z "${outfile}" ]; then
		echo "ss_split_rule_to_json: missing outfile arg" >&2
		return 1
	fi
	if [ ! -f "${rfile}" ]; then
		echo "{}" > "${outfile}"
		return 0
	fi
	# alpha.14 性能优化：原 awk 用 `ip_buf = ip_buf "..."` 字符串累加，每次拷贝整段
	# buffer，10k+ ip 行触发 O(n²) → 处理 11 万行 chnlist+cn.txt 单次 37.5s
	# （user 报 50s hang 的主因）。改为：ip 行 streaming 写到临时文件 ip_tmp，
	# END 阶段先关闭 fd flush 再 getline 拼回主输出。实测 37.5s → 3.88s（9.7x）。
	# Domain 路径无需改（一直是 streaming printf，没累加）。
	local ip_tmp="${outfile}.iptmp"
	awk -v ip_out="${ip_tmp}" '
		BEGIN { print "{"; print "  \"domains\": ["; first_d = 1; first_i = 1; }
		/^[[:space:]]*#/ { next }
		{ sub(/#.*/, ""); gsub(/[[:space:]]+/, ""); }
		!$0 { next }
		/\// {
			# CIDR
			if (first_i) first_i = 0; else print "," > ip_out
			print "    \"" $0 "\"" > ip_out
			next
		}
		/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {
			if (first_i) first_i = 0; else print "," > ip_out
			print "    \"" $0 "/32\"" > ip_out
			next
		}
		/^[0-9a-fA-F:]+$/ {
			if (first_i) first_i = 0; else print "," > ip_out
			print "    \"" $0 "/128\"" > ip_out
			next
		}
		/^\+/ {
			d = substr($0, 2);
			if (first_d) first_d = 0; else printf(",\n");
			printf("    \"full:%s\"", d);
			next;
		}
		{
			if (first_d) first_d = 0; else printf(",\n");
			printf("    \"domain:%s\"", $0);
		}
		END {
			print ""
			print "  ], \"ips\": ["
			# 关 fd 让 buffered write 落盘，再从同一文件 getline 拼回主输出
			# 完全没有 ip 行时 ip_out 文件不存在，getline 直接返回 0，输出空 ips 数组
			close(ip_out)
			while ((getline line < ip_out) > 0) print line
			print "  ] }"
		}
	' "${rfile}" > "${outfile}"
	rm -f "${ip_tmp}"
}

# 从 action 字符串导出 canonical tag（与 §4.3 算法对齐）
ss_split_action_to_tag() {
	local action="$1"
	case "${action}" in
	direct) echo "out_direct" ;;
	reject) echo "out_reject" ;;
	proxy_main) echo "out_main" ;;
	proxy_node:*)
		local nid="${action#proxy_node:}"
		echo "out_node_${nid}"
		;;
	proxy_chain:*:*)
		local rest="${action#proxy_chain:}"
		local fid="${rest%%:*}"
		local lid="${rest#*:}"
		echo "out_chain_${fid}_${lid}"
		;;
	*)
		echo "out_main"
		;;
	esac
}

# 主函数：在 /koolshare/ss/xray.json 基线上做 split 改造
generate_xray_json_split() {
	local xray_json="/koolshare/ss/xray.json"
	local tmp_json="/tmp/fss_split_xray.$$.json"
	local rules_user_dir="/koolshare/ss/rules_user"

	if [ ! -f "${xray_json}" ]; then
		echo_date "❌ split: 基线 ${xray_json} 不存在，跳过 split 改造。"
		dbus set fss_split_xray_warn="baseline_missing"
		return 1
	fi
	if ! type jq >/dev/null 2>&1; then
		echo_date "❌ split: jq 不可用，跳过 split 改造。"
		dbus set fss_split_xray_warn="jq_missing"
		return 1
	fi

	echo_date "----------- 开始生成 xray 分流配置 (doge.12 alpha) -----------"

	# alpha.12: 运行时健康检查 + hot reseed（同形漏修补丁，详见 install.sh::migrate_split_routing_v1）
	# 老路径：rule_<rid>.txt 缺失时 line 5305 `[ -n "${rid}" ] && [ -f "${rfile}" ]` 守卫静默跳过，
	# 没 warn 没 error，整条 Mode 只剩兜底规则 → 所有流量走 default_action（用户报"全代理"现象）。
	# 修：xray 生成前枚举 ss_split_rule_<i>_id，对每个 Rule 检查 rule_${rid}.txt 是否存在且非空；
	#     缺失则 source helper 触发 reseed，再验证一遍。
	# CLAUDE.md 硬规则 #13 1-indexed：用 `while [ $rcheck -le ${rule_count_total} ]`。
	local rule_count_total=$(dbus get ss_split_rule_count 2>/dev/null)
	rule_count_total=${rule_count_total:-0}
	local missing_rule_files=""
	local rcheck=1
	while [ "${rcheck}" -le "${rule_count_total}" ]; do
		local rid_check=$(dbus get ss_split_rule_${rcheck}_id 2>/dev/null)
		if [ -n "${rid_check}" ] && [ ! -s "/koolshare/ss/rules_user/rule_${rid_check}.txt" ]; then
			missing_rule_files="${missing_rule_files} rule_${rid_check}.txt"
		fi
		rcheck=$((rcheck + 1))
	done

	if [ -n "${missing_rule_files}" ]; then
		echo_date "⚠️ split: 检测到 Rule 源文件缺失:${missing_rule_files}，触发自愈"
		dbus set fss_split_xray_warn="rule_files_missing_autoseed"
		if [ -f /koolshare/scripts/ss_split_rule_seed.sh ]; then
			. /koolshare/scripts/ss_split_rule_seed.sh
			if type fancyss_split_seed_rule_files_v1 >/dev/null 2>&1; then
				fancyss_split_seed_rule_files_v1
				# 再次验证
				local still_missing=""
				local rrecheck=1
				while [ "${rrecheck}" -le "${rule_count_total}" ]; do
					local rid_recheck=$(dbus get ss_split_rule_${rrecheck}_id 2>/dev/null)
					if [ -n "${rid_recheck}" ] && [ ! -s "/koolshare/ss/rules_user/rule_${rid_recheck}.txt" ]; then
						still_missing="${still_missing} rule_${rid_recheck}.txt"
					fi
					rrecheck=$((rrecheck + 1))
				done
				if [ -z "${still_missing}" ]; then
					echo_date "✅ split: Rule 源文件自愈完成"
					dbus set fss_split_xray_warn=""
				else
					echo_date "❌ split: 自愈失败仍缺:${still_missing}"
					dbus set fss_split_xray_warn="rule_files_reseed_failed"
				fi
			else
				echo_date "❌ split: helper 已 source 但 function 不存在"
				dbus set fss_split_xray_warn="reseed_helper_function_missing"
			fi
		else
			echo_date "❌ split: helper /koolshare/scripts/ss_split_rule_seed.sh 不存在"
			dbus set fss_split_xray_warn="reseed_helper_file_missing"
		fi
	fi

	# 1. 扫描 Mode 元数据
	local mode_count=$(dbus get ss_split_mode_count 2>/dev/null)
	[ -z "${mode_count}" ] && mode_count=0
	local default_mode_id=$(dbus get ss_split_default_mode_id 2>/dev/null)
	[ -z "${default_mode_id}" ] && default_mode_id=2  # 大陆白名单兜底

	# 收集 active modes
	# doge.13 beta D8 兑现：去掉 alpha 的 `is_default || builtin` 过滤
	# —— 全部已声明的 Mode 都进 active_indices，与 __split_mode_port_by_id 端口
	# 分配同步。alpha 期会让自定义 Mode 拿不到 TPROXY 端口 + xray inbound，
	# ACL 切到这些 Mode 后流量丢失。
	# 索引按 1-based（与 install.sh::migrate_split_routing_v1 一致），
	# 详见 doc/implementation/split-routing-implementation.md §1.5 索引规范
	local active_indices=""
	local active_count=0
	local m=1
	while [ "${m}" -le "${mode_count}" ]; do
		local mid=$(dbus get ss_split_mode_${m}_id 2>/dev/null)
		if [ -n "${mid}" ]; then
			active_indices="${active_indices} ${m}"
			active_count=$((active_count + 1))
		fi
		m=$((m + 1))
	done
	if [ "${active_count}" -eq 0 ]; then
		echo_date "⚠️ split: 没有 active Mode，跳过 split 改造。"
		dbus set fss_split_xray_warn="no_active_mode"
		return 1
	fi
	echo_date "ℹ️ split: 检测到 ${active_count} 个 active Mode（共 ${mode_count}）"
	# alpha.17 P2-2: 列出每个 Mode 的名字和 rule 数,默认 Mode 用 # 标识
	local _mode_names=""
	local _midx=1
	while [ "${_midx}" -le "${mode_count}" ]; do
		local _mname=$(dbus get ss_split_mode_${_midx}_name 2>/dev/null)
		local _mrcnt=$(dbus get ss_split_mode_${_midx}_rule_count 2>/dev/null)
		_mode_names="${_mode_names} #${_midx}=${_mname:-未命名}(${_mrcnt:-0}规则)"
		_midx=$((_midx + 1))
	done
	echo_date "    Mode 列表:${_mode_names}; 默认 Mode=#${default_mode_id}"

	# 2. 收集所有 unique action（去重）
	local actions_seen=""
	local main_node_id="${ssconf_basic_node}"
	local main_front_id=$(dbus get ssconf_basic_node_front 2>/dev/null)
	local main_action=""
	if [ -n "${main_front_id}" ]; then
		main_action="proxy_chain:${main_front_id}:${main_node_id}"
	elif [ -n "${main_node_id}" ]; then
		main_action="proxy_node:${main_node_id}"
	fi

	# 总是注册 direct / reject / out_main（主节点 outbound 来自基线）
	actions_seen="out_direct out_reject out_main"

	# doge.13 beta D12 兑现：解除 alpha 期的 collapse → out_main 兜底。
	# 收集所有 unique node/chain outbound tag 与对应 ID，待 jq 合并前一批 build。
	# - node_outbounds_to_build: "out_node_X" tag 集合（去重，空格分隔）
	# - chain_outbounds_to_build: "out_chain_Y_X" tag 集合（去重）
	# - chain_fronts_to_build: 前置 node id 集合 (去重) — 跨节点 chain 需要 build
	#   chain_front_Y outbound 供 streamSettings.sockopt.dialerProxy 引用
	local node_outbounds_to_build=""
	local chain_outbounds_to_build=""
	local chain_fronts_to_build=""

	# 内嵌 helper：注册 tag 到 build 集合（按形态分桶）
	__split_register_outbound_tag() {
		local _tag="$1"
		case "${_tag}" in
		out_node_*)
			case " ${node_outbounds_to_build} " in
			*" ${_tag} "*) : ;;
			*) node_outbounds_to_build="${node_outbounds_to_build} ${_tag}" ;;
			esac
			;;
		out_chain_*)
			case " ${chain_outbounds_to_build} " in
			*" ${_tag} "*) : ;;
			*) chain_outbounds_to_build="${chain_outbounds_to_build} ${_tag}" ;;
			esac
			# 拆出 front_id (out_chain_Y_X → Y)
			local _rest="${_tag#out_chain_}"
			local _fid="${_rest%%_*}"
			if [ -n "${_fid}" ]; then
				case " ${chain_fronts_to_build} " in
				*" ${_fid} "*) : ;;
				*) chain_fronts_to_build="${chain_fronts_to_build} ${_fid}" ;;
				esac
			fi
			;;
		esac
	}

	local mi=""
	for mi in ${active_indices}; do
		local rcnt=$(dbus get ss_split_mode_${mi}_rule_count 2>/dev/null)
		[ -z "${rcnt}" ] && rcnt=0
		local r=1
		while [ "${r}" -le "${rcnt}" ]; do
			local act=$(dbus get ss_split_mode_${mi}_rule_${r}_action 2>/dev/null)
			local tag=$(ss_split_action_to_tag "${act}")
			# doge.13: 不再 collapse，按真实 tag 注册到 actions_seen + 待 build 集合
			case " ${actions_seen} " in
			*" ${tag} "*) : ;;
			*) actions_seen="${actions_seen} ${tag}" ;;
			esac
			__split_register_outbound_tag "${tag}"
			r=$((r + 1))
		done
		local da=$(dbus get ss_split_mode_${mi}_default_action 2>/dev/null)
		local dtag=$(ss_split_action_to_tag "${da}")
		# 兜底未识别的 default_action（空串等）→ out_main
		case "${dtag}" in
		out_direct|out_reject|out_main|out_node_*|out_chain_*) : ;;
		*) dtag="out_main" ;;
		esac
		case " ${actions_seen} " in
		*" ${dtag} "*) : ;;
		*) actions_seen="${actions_seen} ${dtag}" ;;
		esac
		__split_register_outbound_tag "${dtag}"
	done

	# 3. 用 jq 重写 inbounds + outbounds + routing
	# 3a. inbounds：保留 socks 入站(:23456) 与可能存在的 DNS-relay 入站；
	#     再为每个 active Mode 追加 dokodemo-door TPROXY (mark sniffing)
	local sniff_blocks="["
	local sniff_first=1
	local m_index=0
	local active_mode_ports=""    # 给 routing 用，记录每 active mode 的 inboundTag→端口
	for mi in ${active_indices}; do
		local port=$((SS_SPLIT_PORT_BASE + m_index))
		local mid=$(dbus get ss_split_mode_${mi}_id 2>/dev/null)
		local block_quic=$(dbus get ss_split_mode_${mi}_block_quic 2>/dev/null)
		local network="tcp,udp"
		# block_quic 不在 inbound 控制；走 iptables 层屏蔽 udp/443
		if [ "${sniff_first}" = "1" ]; then sniff_first=0; else sniff_blocks="${sniff_blocks},"; fi
		sniff_blocks="${sniff_blocks}$(cat <<EOF
{
  "tag": "mode_${mid}",
  "listen": "0.0.0.0",
  "port": ${port},
  "protocol": "dokodemo-door",
  "settings": { "network": "${network}", "followRedirect": true },
  "sniffing": {
    "enabled": true,
    "destOverride": ["http", "tls", "quic"],
    "metadataOnly": false,
    "routeOnly": true
  },
  "streamSettings": { "sockopt": { "tproxy": "tproxy" } }
}
EOF
)"
		active_mode_ports="${active_mode_ports} ${mi}:${mid}:${port}"
		m_index=$((m_index + 1))
	done
	sniff_blocks="${sniff_blocks}]"

	# 3b. outbounds 去重：保留基线 outbounds[0] 作为 out_main；追加 direct / reject
	local outb_appends="[
		{ \"tag\": \"out_direct\", \"protocol\": \"freedom\", \"settings\": { \"domainStrategy\": \"UseIP\" } },
		{ \"tag\": \"out_reject\", \"protocol\": \"blackhole\" }
	]"

	# 3c. routing.rules：按 §4.4 顺序生成
	local routing_rules_file="/tmp/fss_split_routing_rules.$$.json"
	echo "[" > "${routing_rules_file}"
	local first_rule=1
	__split_emit_rule() {
		# 接收 jq object 字符串，追加到 routing_rules_file
		local rule_json="$1"
		if [ "${first_rule}" = "1" ]; then
			first_rule=0
		else
			echo "," >> "${routing_rules_file}"
		fi
		printf '%s' "${rule_json}" >> "${routing_rules_file}"
	}

	# 每个 active Mode 一组规则
	for mi in ${active_indices}; do
		local mid=$(dbus get ss_split_mode_${mi}_id 2>/dev/null)
		local apply_bw=$(dbus get ss_split_mode_${mi}_apply_blackwhite 2>/dev/null)
		local da=$(dbus get ss_split_mode_${mi}_default_action 2>/dev/null)
		local dtag=$(ss_split_action_to_tag "${da}")
		# doge.13 beta D12: 不再 collapse 到 out_main；按真实 tag emit。
		# 兜底只对 dtag 不识别的情况（空 / 异常），不影响 node/chain tag。
		case "${dtag}" in
		out_direct|out_reject|out_main|out_node_*|out_chain_*) : ;;
		*) dtag="out_main" ;;
		esac

		# §4.4 #1: RFC1918 / loopback → out_direct
		# 注意：不能用 "geoip:private"——xray 加载该标记需要 geoip.dat 文件存在于
		# /data/geoip.dat 或 XRAY_LOCATION_ASSET 指定的目录，fancyss 默认包没带这个
		# 文件，所以 xray -test 会以 "failed to open file: geoip.dat" 失败 → split
		# 改造整体回滚到老路径 → LAN 客户端 TCP/UDP 全废。alpha.8 实地踩到这个坑。
		# 改用显式 RFC1918 + RFC6598(CGNAT) + RFC3927(link-local) 等 CIDR。
		__split_emit_rule "$(jq -n --arg tag "mode_${mid}" '{
			type: "field",
			inboundTag: [$tag],
			ip: ["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","100.64.0.0/10","127.0.0.0/8","169.254.0.0/16","224.0.0.0/4","240.0.0.0/4","0.0.0.0/8"],
			outboundTag: "out_direct"
		}')"

		# §4.4 #2: 黑白名单（仅 apply_blackwhite=1）
		if [ "${apply_bw}" = "1" ]; then
			# 2a. 白名单 → out_direct
			if [ -n "${ss_wan_white_domain}" ]; then
				local wdoms=$(fss_b64_decode "${ss_wan_white_domain}" 2>/dev/null | awk '/^[[:space:]]*#/{next}{gsub(/[[:space:]]+/,""); if($0)print "domain:"$0}' | jq -R . | jq -s .)
				[ -z "${wdoms}" ] && wdoms="[]"
				if [ "${wdoms}" != "[]" ]; then
					__split_emit_rule "$(jq -n --arg tag "mode_${mid}" --argjson d "${wdoms}" '{
						type: "field", inboundTag: [$tag], domain: $d, outboundTag: "out_direct"
					}')"
				fi
			fi
			# 2b. 黑名单 → default_action tag
			if [ -n "${ss_wan_black_domain}" ] && [ "${dtag}" != "out_direct" ]; then
				local bdoms=$(fss_b64_decode "${ss_wan_black_domain}" 2>/dev/null | awk '/^[[:space:]]*#/{next}{gsub(/[[:space:]]+/,""); if($0)print "domain:"$0}' | jq -R . | jq -s .)
				[ -z "${bdoms}" ] && bdoms="[]"
				if [ "${bdoms}" != "[]" ]; then
					__split_emit_rule "$(jq -n --arg tag "mode_${mid}" --argjson d "${bdoms}" --arg ob "${dtag}" '{
						type: "field", inboundTag: [$tag], domain: $d, outboundTag: $ob
					}')"
				fi
			fi
		fi

		# §4.4 #3: Mode 内的 Rule（按顺序）
		local rcnt=$(dbus get ss_split_mode_${mi}_rule_count 2>/dev/null)
		[ -z "${rcnt}" ] && rcnt=0
		local r=1
		while [ "${r}" -le "${rcnt}" ]; do
			local rid=$(dbus get ss_split_mode_${mi}_rule_${r}_rid 2>/dev/null)
			local act=$(dbus get ss_split_mode_${mi}_rule_${r}_action 2>/dev/null)
			local rtag=$(ss_split_action_to_tag "${act}")
			# doge.13 beta D12: 不再 collapse 到 out_main；按真实 tag emit。
			case "${rtag}" in
			out_direct|out_reject|out_main|out_node_*|out_chain_*) : ;;
			*) rtag="out_main" ;;
			esac
			local rfile="${rules_user_dir}/rule_${rid}.txt"
			if [ -n "${rid}" ] && [ -f "${rfile}" ]; then
				# alpha.13: rule 文件可能 11 万行 chnlist（~1.6MB JSON）—— 不能灌进
				# shell 变量。busybox `[ "${X}" ]` 内置 ARG_MAX ~128KB 必爆，alpha.12
				# 实地踩坑（41s hang + Mode 2 大文件 rule 静默吞掉）。
				# 改用文件中转：ss_split_rule_to_json 直接写文件，jq 读文件、输出
				# 写另一文件，最后 cat 流式 append 到 routing_rules_file —— 全程不经 argv。
				local rdata_file="/tmp/fss_split_rdata.$$.${mi}.${r}.json"
				local emit_tmp="/tmp/fss_split_emit.$$.${mi}.${r}.json"
				ss_split_rule_to_json "${rfile}" "${rdata_file}"
				if [ -s "${rdata_file}" ]; then
					# jq filter：空 rule 文件（仅 header 或 reseed 半失败）会产出
					# {"domains":[],"ips":[]}，若直接生成 routing rule 就是"只有 inboundTag
					# 没 domain/ip"的 field rule → xray 当全匹配 → 抢在兜底前命中 → 整 Mode
					# 流量被这条空 rule 吞掉。所以用 `if length>0 then ... else empty end`
					# 包一层，让空 rule 文件不产 routing 条目，让兜底接管（行为更安全）。
					# doge.14.x BLOCKER fix (UDP/STUN 不按白名单直连): domain 与 ip 不能塞进同一条 routing
					# rule —— xray 同一 rule 内多 matcher 是 AND，UDP(STUN/WebRTC/部分游戏)无可嗅探域名 →
					# domain 条件恒不命中 → 整条 rule 对 UDP 失效 → 落兜底走代理(即便目标 IP 在白名单 ip 段)。
					# 拆成两条独立 rule(同 outboundTag): TCP 命中域名、UDP 命中 IP，各自按规则走。
					# 实现约束(两次踩坑): ①不能 map(tojson)|join——大陆白名单 domain 11 万条会再复制 ~2MB
					# 字符串在 armv7l OOM 被 Killed；②不能 jq -c 流式 + while-read 逐行——domain rule 是
					# ~2MB 单行，busybox read 截断变量 → JSON 损坏 → jq_merge_failed 回退基线丢分流。
					# 故两次 jq -c 各 emit 单 object(各自 empty-guard)，用 cat 追加(cat 不受行长限制；
					# jq 单 object 引用输入数组不复制，峰值内存与旧版持平)。空 rule 两次都 empty → [ -s ]
					# 跳过 → 兜底接管(空 rule guard 保留)。
					# domain-only rule (TCP 按嗅探域名命中)
					if jq -c --arg tag "mode_${mid}" --arg ob "${rtag}" 'if (.domains | length) > 0 then {type:"field",inboundTag:[$tag],domain:.domains,outboundTag:$ob} else empty end' "${rdata_file}" > "${emit_tmp}" 2>/dev/null && [ -s "${emit_tmp}" ]; then
						if [ "${first_rule}" = "1" ]; then first_rule=0; else echo "," >> "${routing_rules_file}"; fi
						cat "${emit_tmp}" >> "${routing_rules_file}"
					fi
					# ip-only rule (UDP/STUN 等无域名流量按目标 IP 命中 —— 本次 BLOCKER 修复点)
					if jq -c --arg tag "mode_${mid}" --arg ob "${rtag}" 'if (.ips | length) > 0 then {type:"field",inboundTag:[$tag],ip:.ips,outboundTag:$ob} else empty end' "${rdata_file}" > "${emit_tmp}" 2>/dev/null && [ -s "${emit_tmp}" ]; then
						if [ "${first_rule}" = "1" ]; then first_rule=0; else echo "," >> "${routing_rules_file}"; fi
						cat "${emit_tmp}" >> "${routing_rules_file}"
					fi
				fi
				rm -f "${rdata_file}" "${emit_tmp}"
			fi
			r=$((r + 1))
		done

		# §4.4 #4: 兜底
		__split_emit_rule "$(jq -n --arg tag "mode_${mid}" --arg ob "${dtag}" '{
			type: "field", inboundTag: [$tag], outboundTag: $ob
		}')"
	done

	echo "]" >> "${routing_rules_file}"

	# 4. doge.13 beta D12: build node/chain outbounds 并写到 slurpfile
	# 按收集到的 node_outbounds_to_build / chain_outbounds_to_build / chain_fronts_to_build
	# 调 fss_split_build_node_outbound_json 生成 outbound JSON。文件中转 → jq slurpfile
	# 合入 .outbounds。任何 build 失败 → graceful fallback：该 tag 回退 out_main 的 outbound
	# (用 jq 重写 routing rules 中该 tag 的引用)。
	# CLAUDE.md 硬规则 #16: 调用必须显式传 outfile 临时路径，不能走 /dev/stdout。
	local extra_outbounds_file="/tmp/fss_split_extra_obs.$$.json"
	echo "[]" > "${extra_outbounds_file}"
	local extra_first=1
	local fallback_tags=""     # build 失败的 tag 集合，后面要在 routing rules 里 fallback 到 out_main

	__split_append_outbound() {
		# $1 = 单个 outbound JSON 文件路径（fss_split_build_node_outbound_json 的 outfile）
		local _ob_file="$1"
		local _ob_tag="$2"
		if [ ! -s "${_ob_file}" ]; then
			echo_date "⚠️ split: outbound build 失败 (${_ob_tag})，routing rule 中该 tag 将 fallback 到 out_main"
			fallback_tags="${fallback_tags} ${_ob_tag}"
			return 1
		fi
		# 合并到 extra_outbounds_file (走 jq 保证 JSON 正确)
		local _merge_tmp="/tmp/fss_split_obmerge.$$.json"
		if jq --slurpfile new "${_ob_file}" '. + $new' "${extra_outbounds_file}" > "${_merge_tmp}" 2>/dev/null; then
			mv -f "${_merge_tmp}" "${extra_outbounds_file}"
			extra_first=0
		else
			echo_date "⚠️ split: jq 合并 outbound 失败 (${_ob_tag}), fallback 到 out_main"
			fallback_tags="${fallback_tags} ${_ob_tag}"
			rm -f "${_merge_tmp}" >/dev/null 2>&1
		fi
	}

	if type fss_split_build_node_outbound_json >/dev/null 2>&1; then
		# 4a. build 跨节点 chain 的前置 outbound（chain_front_<Y>）
		# 这些是给 chain landing outbound 的 dialerProxy 引用的，必须先 build。
		local _fid=""
		for _fid in ${chain_fronts_to_build}; do
			local _front_tag="chain_front_${_fid}"
			local _front_ob_file="/tmp/fss_split_front_${_fid}.$$.json"
			fss_split_build_node_outbound_json "${_fid}" "${_front_tag}" "${_front_ob_file}" 2>/tmp/fss_split_build.err
			__split_append_outbound "${_front_ob_file}" "${_front_tag}"
			rm -f "${_front_ob_file}" >/dev/null 2>&1
		done

		# 4b. build 普通 node outbound（out_node_<X>）
		local _ntag=""
		for _ntag in ${node_outbounds_to_build}; do
			local _nid="${_ntag#out_node_}"
			local _nob_file="/tmp/fss_split_node_${_nid}.$$.json"
			fss_split_build_node_outbound_json "${_nid}" "${_ntag}" "${_nob_file}" 2>/tmp/fss_split_build.err
			__split_append_outbound "${_nob_file}" "${_ntag}"
			rm -f "${_nob_file}" >/dev/null 2>&1
		done

		# 4c. build chain landing outbound（out_chain_<Y>_<X>）
		# helper 第 4 参数 dialer_tag 指定 dialerProxy → chain_front_<Y>
		local _ctag=""
		for _ctag in ${chain_outbounds_to_build}; do
			# out_chain_Y_X
			local _rest="${_ctag#out_chain_}"
			local _yfid="${_rest%%_*}"
			local _xlid="${_rest#*_}"
			local _cob_file="/tmp/fss_split_chain_${_yfid}_${_xlid}.$$.json"
			fss_split_build_node_outbound_json "${_xlid}" "${_ctag}" "${_cob_file}" "chain_front_${_yfid}" 2>/tmp/fss_split_build.err
			__split_append_outbound "${_cob_file}" "${_ctag}"
			rm -f "${_cob_file}" >/dev/null 2>&1
		done
	else
		# Graceful fallback：helper 未部署（ss_split_node_outbound.sh 缺失或 source 失败）
		# → 所有 node/chain tag 都 fallback 到 out_main，行为退化为 alpha 期 collapse
		# (不让 ssconfig.sh restart 死掉)。
		if [ -n "${node_outbounds_to_build}${chain_outbounds_to_build}" ]; then
			echo_date "⚠️ split: fss_split_build_node_outbound_json 未定义（ss_split_node_outbound.sh 未部署）"
			echo_date "⚠️ split: 所有 node/chain outbound 退化为 out_main collapse (alpha 行为)"
			fallback_tags="${fallback_tags} ${node_outbounds_to_build} ${chain_outbounds_to_build}"
			dbus set fss_split_xray_warn="outbound_builder_missing"
		fi
	fi

	# 4d. fallback_tags 处理：把 routing_rules_file 里失败 tag 的 outboundTag 改成 out_main
	if [ -n "${fallback_tags}" ]; then
		local _fb_tmp="/tmp/fss_split_routing_fb.$$.json"
		# 构造 jq 的 fallback set
		local _fb_jq_args=""
		local _fb_jq_filter='map(if (.outboundTag as $t | $fbset | index($t)) then .outboundTag = "out_main" else . end)'
		local _fb_set_json="["
		local _fb_first=1
		local _ft=""
		for _ft in ${fallback_tags}; do
			[ -z "${_ft}" ] && continue
			if [ "${_fb_first}" = "1" ]; then _fb_first=0; else _fb_set_json="${_fb_set_json},"; fi
			_fb_set_json="${_fb_set_json}\"${_ft}\""
		done
		_fb_set_json="${_fb_set_json}]"
		if jq --argjson fbset "${_fb_set_json}" "${_fb_jq_filter}" "${routing_rules_file}" > "${_fb_tmp}" 2>/dev/null; then
			mv -f "${_fb_tmp}" "${routing_rules_file}"
		else
			rm -f "${_fb_tmp}" >/dev/null 2>&1
		fi
	fi

	# 5. 用 jq 合并到 xray.json
	if ! jq --argjson sniff "${sniff_blocks}" \
	         --argjson appendOb "${outb_appends}" \
	         --slurpfile rules "${routing_rules_file}" \
	         --slurpfile extraObs "${extra_outbounds_file}" \
	         '
	           # 只删除新生成器自己写的 dokodemo-door 入站（tag 以 mode_ 开头），
	           # 保留基线 xray.json 已有的其他入站（socks:23456 + dns_udp_1055
	           # DNS-relay 入站等）。旧代码靠 "port==23456" 白名单太狭窄——
	           # dns_udp_1055 也是 dokodemo-door 但 port=1055，会被误删，
	           # 导致 chinadns-ng 的 trust-dns 第一个上游 udp://127.0.0.1#1055
	           # 拿不到响应 → LAN 客户端 DNS 全超时（alpha.8 实地踩到）。
	           .inbounds = (
	             [ .inbounds[] | select(.protocol != "dokodemo-door" or ((.tag // "") | startswith("mode_") | not)) ]
	             + $sniff
	           )
	           # 给主 outbound (originally outbounds[0]) 改 tag 为 out_main
	           | .outbounds[0].tag = "out_main"
	           # 追加 direct / reject outbound（若已存在则去重）
	           | .outbounds = (
	             .outbounds + ($appendOb | map(select(.tag as $t | (.outbounds // []) | map(.tag) | index($t) | not)))
	           )
	           # doge.13 beta D12: 追加 node/chain/chain_front outbounds（与已存在 tag 去重）
	           | .outbounds = (
	             .outbounds + ($extraObs[0] | map(select(.tag as $t | (.outbounds // []) | map(.tag) | index($t) | not)))
	           )
	           | .routing = { domainStrategy: "IPIfNonMatch", rules: $rules[0] }
	         ' \
	         "${xray_json}" > "${tmp_json}" 2>/tmp/fss_split_xray.err; then
		echo_date "❌ split: jq 合并失败，详见 /tmp/fss_split_xray.err，保留基线 xray.json。"
		dbus set fss_split_xray_warn="jq_merge_failed"
		rm -f "${tmp_json}" "${routing_rules_file}" "${extra_outbounds_file}" >/dev/null 2>&1
		return 1
	fi

	if [ ! -s "${tmp_json}" ]; then
		echo_date "❌ split: 合并产出为空，保留基线 xray.json。"
		dbus set fss_split_xray_warn="output_empty"
		rm -f "${tmp_json}" "${routing_rules_file}" "${extra_outbounds_file}" >/dev/null 2>&1
		return 1
	fi

	# 在覆盖基线前备份，xray -test 失败时回滚（避免坏配置卡死 xray）
	local xray_json_bak="${xray_json}.fss_split.bak"
	cp -f "${xray_json}" "${xray_json_bak}" 2>/dev/null

	mv -f "${tmp_json}" "${xray_json}"
	rm -f "${routing_rules_file}" "${extra_outbounds_file}" >/dev/null 2>&1

	# 5. 自检（失败时显式回滚基线）
	if [ -x /koolshare/bin/xray ]; then
		if ! /koolshare/bin/xray run -test -c "${xray_json}" >/tmp/fss_split_xray.testlog 2>&1; then
			echo_date "❌ split: xray -test 自检失败，详见 /tmp/fss_split_xray.testlog。回滚到基线 xray.json。"
			dbus set fss_split_xray_warn="xray_test_failed"
			if [ -s "${xray_json_bak}" ]; then
				mv -f "${xray_json_bak}" "${xray_json}"
			fi
			return 1
		fi
	fi

	# 备份用毕清理
	rm -f "${xray_json_bak}" >/dev/null 2>&1

	# 6. 状态 dbus 写入
	local ob_count=$(jq '.outbounds | length' "${xray_json}" 2>/dev/null)
	[ -z "${ob_count}" ] && ob_count=0
	dbus set ss_split_xray_outbound_count="${ob_count}"
	dbus set ss_split_active_mode_count="${active_count}"
	dbus set ss_split_last_restart_ts="$(date +%s)"
	# doge.13 beta D12 诊断：build/fallback 计数
	local _n_cnt=$(echo "${node_outbounds_to_build}" | tr ' ' '\n' | grep -c '^out_node_')
	local _c_cnt=$(echo "${chain_outbounds_to_build}" | tr ' ' '\n' | grep -c '^out_chain_')
	local _f_cnt=$(echo "${chain_fronts_to_build}" | tr ' ' '\n' | grep -cv '^$')
	dbus set ss_split_node_outbound_count="${_n_cnt}"
	dbus set ss_split_chain_outbound_count="${_c_cnt}"
	if [ -z "${fallback_tags}" ]; then
		dbus set fss_split_xray_warn=""
	fi
	echo_date "✅ split: xray 配置生成完成 (active_mode=${active_count} outbound=${ob_count}; node=${_n_cnt} chain=${_c_cnt} front=${_f_cnt})"
	if [ -n "${fallback_tags}" ]; then
		echo_date "⚠️ split: 以下 tag build 失败，已 fallback 到 out_main:${fallback_tags}"
	fi
	echo_date "---------------------------------------------------------------"
	return 0
}

start_xray() {
	# tfo start
	if [ "${LINUX_VER}" != "26" ]; then
		if [ "$ss_basic_tfo" == "1" ]; then
			echo_date "开启tcp fast open支持."
			echo 3 >/proc/sys/net/ipv4/tcp_fastopen
		else
			echo 1 >/proc/sys/net/ipv4/tcp_fastopen
		fi
	fi
	# FORK doge.12 alpha: 在 split 路径下用新生成器改造基线 xray.json
	# rules_user 目录不存在时自动 mkdir 兜底——install.sh 的 seed_rules_user_dir
	# 是 install-time 一次性，被 migrate_split_routing_v1 的 idempotent 守卫保护，
	# 若用户在路由器上误删目录（或 jffs 出问题），dbus 标志位仍是 1，迁移不再重跑
	# 会让 split 整段静默跳过。alpha.8 实地踩过这个坑。
	# mode 内 rule_count=0 时不需要任何 rule 文件，所以目录存在即可，无需重 seed。
	# doge.14: 分流架构唯一路径
	if [ ! -d /koolshare/ss/rules_user ]; then
		echo_date "⚠️ split: /koolshare/ss/rules_user 目录不存在，自动创建（若曾装过 doge.12，install.sh 应该建过；可能是被误删或文件系统问题）"
		mkdir -p /koolshare/ss/rules_user 2>/dev/null
		chmod 755 /koolshare/ss/rules_user 2>/dev/null
	fi
	if ! generate_xray_json_split; then
		echo_date "⚠️ split: 新生成器失败，回退到基线 xray.json + 旧链式注入。"
	fi
	# xray start
	echo_date "开启Xray主进程..."
	cd /koolshare/bin
	# 链式代理（前置节点）注入：
	# split 路径下 generate_xray_json_split 只动主 outbound tag（→ out_main）和追加
	# direct/reject 两个 outbound，**不注入链式 outbound**。链式由 fss_chain_apply
	# 唯一一次注入——在 split 产物的 out_main 上覆盖 streamSettings.sockopt.dialerProxy
	# 并追加 proxy_front outbound（其 tag 在 xray.json 此前不存在），无 duplicate tag
	# 冲突。
	type fss_chain_apply >/dev/null 2>&1 && fss_chain_apply /koolshare/ss/xray.json
	# doge.14: 捕获 xray 启动 stderr（run_bg 会吞掉），配合 detect_running_status3 的崩溃 dump，
	# 让“配置 -test 过但运行时崩/慢”的情况能看到真实原因。
	rm -f /tmp/xray_run.err
	env -i PATH=${PATH} /koolshare/bin/xray run -c /koolshare/ss/xray.json >/tmp/xray_run.err 2>&1 &
	# alpha.17 P1-2: VERBOSE=1 让 detect_running_status3 打印探测结果；启动后探 pid/监听端口
	detect_running_status3 xray 23456 1 force /tmp/xray_run.err
	local _xray_pid=$(pidof xray | awk '{print $1}')
	local _xray_listen=$(netstat -lntup 2>/dev/null | grep -E "xray" | awk '{print $4}' | sort -u | tr '\n' ' ')
	echo_date "✅ Xray 启动完成 pid=${_xray_pid:-N/A} 监听端口=${_xray_listen:-无}"
}

creat_trojan_json(){
	# do not create json file on start
	if [ -z "${WEB_ACTION}" ]; then
		if [ -n "${WAN_ACTION}" ]; then
			echo_date "检测到网络拨号/开机触发启动，不创建$(__get_type_abbr_name)配置文件，使用上次的配置文件！"
			return 0
		fi
	else
		echo_date "创建xray的trojan配置文件到${TROJAN_CONFIG_FILE}"
	fi

	# trojan协议由xray来运行
	rm -rf "${TROJAN_CONFIG_TEMP}"
	rm -rf "${TROJAN_CONFIG_FILE}"
	# log area
	cat >"${TROJAN_CONFIG_TEMP}" <<-EOF
		{
		"log": {
			"access": "none",
			"error": "none",
			"loglevel": "none"
		},
	EOF

	# inbounds area (23456 for socks5)
	cat >>"$TROJAN_CONFIG_TEMP" <<-EOF
		"inbounds": [
	EOF

	# when user use udp trust dns in chinadns-ng
	gen_xray_dns_inbound ${TROJAN_CONFIG_TEMP}
	
	cat >>"$TROJAN_CONFIG_TEMP" <<-EOF
			{
				"port": 23456,
				"listen": "127.0.0.1",
				"protocol": "socks",
				"settings": {
					"auth": "noauth",
					"udp": true,
					"ip": "127.0.0.1"
				}
			},
			{
				"listen": "0.0.0.0",
				"port": 3333,
				"protocol": "dokodemo-door",
				"settings": {
					"network": "tcp,udp",
					"followRedirect": true
				}
			}
		],
	EOF
	
	if [ -n "${ss_basic_trojan_plugin}" -a "${ss_basic_trojan_plugin}" == "obfs-local" -a "${ss_basic_trojan_obfs}" == "websocket" ];then
		echo_date "检测到该trojan节点为obfs-local WebSocket伪装，继续！"
		local _trojan_network="ws"
		local _trojan_ws="{
			\"path\": \"${ss_basic_trojan_obfsuri}\",
			\"host\": \"${ss_basic_trojan_obfshost}\"
		}"
	else
		local _trojan_network="tcp"
		local _trojan_ws=null
	fi
	
	# outbounds area
	cat >>"${TROJAN_CONFIG_TEMP}" <<-EOF
		"outbounds": [
			{
				"protocol": "trojan",
				"settings": {
					"servers": [{
					"address": "${ss_basic_server}",
					"port": ${ss_basic_port},
					"password": "${ss_basic_trojan_uuid}"
					}]
				},
				"streamSettings": {
					"network": "${_trojan_network}",
					"security": "tls",
					"tlsSettings": {
						"serverName": $(get_value_null ${ss_basic_trojan_sni}),
						"pinnedPeerCertSha256": $(get_value_empty ${ss_basic_trojan_pcs}),
						"verifyPeerCertByName": $(get_value_empty ${ss_basic_trojan_vcn})
					}
					,"wsSettings": ${_trojan_ws}
					,"sockopt": {"tcpFastOpen": $(get_function_switch ${ss_basic_trojan_tfo})}
				}
			}
		]
		}
	EOF
	echo_date "解析xray的trojan配置文件..."
	if [ "${LINUX_VER}" == "26" ]; then
		sed -i '/tcpFastOpen/d' ${TROJAN_CONFIG_TEMP} 2>/dev/null
	fi
	run jq --tab . ${TROJAN_CONFIG_TEMP} >/tmp/trojan_para_tmp.txt 2>&1
	if [ "$?" != "0" ];then
		echo_date "json配置解析错误，错误信息如下："
		echo_date $(cat /tmp/trojan_para_tmp.txt) 
		echo_date "请更正你的错误然后重试！！"
		rm -rf /tmp/trojan_para_tmp.txt
		close_in_five flag
	fi
	run jq --tab . ${TROJAN_CONFIG_TEMP} >${TROJAN_CONFIG_FILE}
	echo_date "解析成功！xray的trojan配置文件成功写入到${TROJAN_CONFIG_FILE}"
	if ! append_xray_ipv6_tproxy_inbound "${TROJAN_CONFIG_FILE}"; then
		echo_date "错误：追加IPv6透明代理入口到Xray配置文件失败！"
		close_in_five flag
	fi
}

start_trojan(){
	# tfo
	if [ "${LINUX_VER}" != "26" ]; then
		if [ "${ss_basic_trojan_tfo}" == "1" ]; then
			echo_date Trojan协议开启tcp fast open支持.
			echo 3 >/proc/sys/net/ipv4/tcp_fastopen
		else
			echo 1 >/proc/sys/net/ipv4/tcp_fastopen
		fi
	fi

	echo_date "开启Xray主进程，用以运行trojan协议节点..."
	cd /koolshare/bin
	# 链式代理（前置节点）注入
	type fss_chain_apply >/dev/null 2>&1 && fss_chain_apply "$TROJAN_CONFIG_FILE"
	run_bg /koolshare/bin/xray run -c $TROJAN_CONFIG_FILE
	detect_running_status3 xray 23456 0 force
}

creat_hy2_json(){
	# do not create json file on start
	if [ -z "${WEB_ACTION}" ]; then
		if [ -n "${WAN_ACTION}" ]; then
			echo_date "检测到网络拨号/开机触发启动，不创建$(__get_type_abbr_name)配置文件，使用上次的配置文件！"
			return 0
		fi
	else
		echo_date "创建xray的hysteria2配置文件到${HY2_CONFIG_FILE}"
	fi

	# hysteria2协议由xray来运行
	rm -rf "${HY2_CONFIG_TEMP}"
	rm -rf "${HY2_CONFIG_FILE}"
	
	# log area
	cat >"${HY2_CONFIG_TEMP}" <<-EOF
		{
		"log": {
			"access": "none",
			"error": "none",
			"loglevel": "none"
		},
	EOF
	
	# inbounds area (23456 for socks5)
	cat >>"$HY2_CONFIG_TEMP" <<-EOF
		"inbounds": [
	EOF

	# when user use udp trust dns in chinadns-ng
	gen_xray_dns_inbound ${HY2_CONFIG_TEMP}
	
	# continue
	cat >>"$HY2_CONFIG_TEMP" <<-EOF
			{
				"port": 23456,
				"listen": "127.0.0.1",
				"protocol": "socks",
				"settings": {
					"auth": "noauth",
					"udp": true,
					"ip": "127.0.0.1"
				}
			},
			{
				"listen": "0.0.0.0",
				"port": 3333,
				"protocol": "dokodemo-door",
				"settings": {
					"network": "tcp,udp",
					"followRedirect": true
				}
			}
		],
	EOF

	if [ -z "${ss_basic_hy2_sni}" ];then
		__valid_ip_silent "${ss_basic_hy2_server}"
		if [ "$?" != "0" ];then
			# not ip, should be a domain
			ss_basic_hy2_sni=${ss_basic_hy2_server}
		else
			ss_basic_hy2_sni=""
		fi
	else
		ss_basic_hy2_sni="${ss_basic_hy2_sni}"
	fi

	# 避免用户输入单位，检测下是否是纯数值
	if [ $(number_test ${ss_basic_hy2_up}) != "0" ];then
		echo_date "错误！当前hysteria2节点上行速度设置不正确，请输入纯数字！"
		close_in_five
	fi
	if [ $(number_test ${ss_basic_hy2_dl}) != "0" ];then
		echo_date "错误！当前hysteria2节点下行速度设置不正确，请输入纯数字！"
		close_in_five
	fi

	# 默认情况：有 up/down 时 brutal，无 up/down 时 bbr: https://github.com/XTLS/Xray-core/issues/5546
	if [ -n "${ss_basic_hy2_up}" -a -z "${ss_basic_hy2_dl}" ]; then
		echo_date "错误！当前hysteria2节点设置了上行速度未设置下行！请更正！"
		close_in_five
	elif [ -z "${ss_basic_hy2_up}" -a -n "${ss_basic_hy2_dl}" ]; then
		echo_date "错误！当前hysteria2节点设置了下行速度未设置下行！请更正！"
		close_in_five
	elif [ -z "${ss_basic_hy2_up}" -a -z "${ss_basic_hy2_dl}" ]; then
		# 未设置上下行可以允许，但是congestion必须设置为bbr，设置逻辑在：get_value_congestion
		if [ -z "${ss_basic_hy2_cg}" ];then
			echo_date "提醒！hysteria2协议未设置上行和下行速度，拥塞算法将采用：bbr！"
		else
			echo_date "提醒！hysteria2协议未设置上行和下行速度，拥塞算法将采用：bbr，而不是你设置的：${ss_basic_hy2_cg}"
		fi
	elif [ -n "${ss_basic_hy2_up}" -a -n "${ss_basic_hy2_dl}" ]; then
		if [ -z "${ss_basic_hy2_cg}" ];then
			# 之前的版本没有开放此选项，帮用户设置为brutal
			echo_date "hysteria2协议拥塞算法将采用有上下行情况下的默认设置：brutal"
		else
			# 上下行都设置了且正确，此时可以使用用户选择的congestion
			echo_date "hysteria2协议拥塞算法将采用你设置的：${ss_basic_hy2_cg}"
		fi
	fi
	
	# outbounds area
	cat >>"${HY2_CONFIG_TEMP}" <<-EOF
		"outbounds": [
			{
				"protocol": "hysteria",
				"settings": {
					"version": 2,
					"address": "${ss_basic_server}",
					"port": $(get_hy2_port ${ss_basic_hy2_port})
				},
				"streamSettings": {
					"network": "hysteria",
					"hysteriaSettings": {
						"version": 2
						,"auth": $(get_value_empty ${ss_basic_hy2_pass})
					}
					,"security": "tls"
					,"tlsSettings": {
						"serverName": "${ss_basic_hy2_sni}"
	EOF

	# allowInsecure removed by Xray (2026.x); always use pinnedPeerCertSha256/verifyPeerCertByName (FORK doge.14)
	cat >>"${HY2_CONFIG_TEMP}" <<-EOF
							,"pinnedPeerCertSha256": $(get_value_empty ${ss_basic_hy2_pcs})
							,"verifyPeerCertByName": $(get_value_empty ${ss_basic_hy2_vcn})
	EOF

	cat >>"${HY2_CONFIG_TEMP}" <<-EOF
						,"alpn": ["h3"]
					}
					,"sockopt": {"tcpFastOpen": $(get_function_switch ${ss_basic_hy2_tfo})}
	EOF

	append_hy2_finalmask "${HY2_CONFIG_TEMP}"
					
	cat >>"${HY2_CONFIG_TEMP}" <<-EOF
				}
			}
		]
		}
	EOF
	echo_date "解析xray的hysteria2配置文件..."
	if [ "${LINUX_VER}" == "26" ]; then
		sed -i '/tcpFastOpen/d' ${HY2_CONFIG_TEMP} 2>/dev/null
	fi
	run jq --tab . ${HY2_CONFIG_TEMP} >/tmp/hy2_para_tmp.txt 2>&1
	if [ "$?" != "0" ];then
		echo_date "json配置解析错误，错误信息如下："
		echo_date $(cat /tmp/hy2_para_tmp.txt) 
		echo_date "请更正你的错误然后重试！！"
		#rm -rf /tmp/hy2_para_tmp.txt
		close_in_five flag
	fi
	run jq --tab . ${HY2_CONFIG_TEMP} >${HY2_CONFIG_FILE}
	echo_date "解析成功！xray的hysteria2配置文件成功写入到${HY2_CONFIG_FILE}"
	if ! append_xray_ipv6_tproxy_inbound "${HY2_CONFIG_FILE}"; then
		echo_date "错误：追加IPv6透明代理入口到Xray配置文件失败！"
		close_in_five flag
	fi
}

start_hy2(){
	# tfo
	if [ "${LINUX_VER}" != "26" ]; then
		if [ "${ss_basic_hy2_tfo}" == "1" ]; then
			echo_date "hysteria2协议开启tcp fast open支持"
			echo 3 >/proc/sys/net/ipv4/tcp_fastopen
		else
			echo 1 >/proc/sys/net/ipv4/tcp_fastopen
		fi
	fi

	echo_date "开启Xray主进程，用以运行hysteria2协议节点..."
	cd /koolshare/bin
	run_bg /koolshare/bin/xray run -c $HY2_CONFIG_FILE
	detect_running_status3 xray 23456 0 force
}


# FORK: cut in doge.10, see doc/design/protocol-roadmap.md §2
: <<'FORK_CUT_DOGE10'
start_naive(){
	if [ -f "/koolshare/bin/naive" ];then
		chmod +x /koolshare/bin/naive
		local ret=$(run /koolshare/bin/naive --version 2>&1)
		if [ -z "${ret}" ];then
			echo_date "检测到/koolshare/bin/目录下存在naive文件，但是无法运行！"
			echo_date "请确保你下载了正确的二进制文件！"
			close_in_five flag
		fi
	else
		local pkg_arch=$(cat /koolshare/webs/Module_shadowsocks.asp | tr -d '\r' | grep -Eo "PKG_ARCH=.+"|awk -F "=" '{print $2}'|sed 's/"//g')
		echo_date ""
		echo_date "+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"
		echo_date ""
		echo_date "重要提醒！！"
		echo_date ""
		echo_date "检测到你需要使用naive！但是本插件默认没有提供相关的二进制文件！"
		echo_date "请前往下面的链接下载naive二进制，并将其放置在路由器的/koolshare/bin目录后重启插件！"
		echo_date "https://raw.githubusercontent.com/hq450/fancyss/3.0/fancyss/bin-${pkg_arch}/naive"
		echo_date ""
		echo_date "+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"
		echo_date ""
		close_in_five flag
	fi

	echo_date "开启ipt2socks进程..."
	run_bg ipt2socks -p 23456 -l 3333 -b 0.0.0.0 -B :: -n 10000 -R
	detect_running_status2 ipt2socks 23456

	echo_date "开启NaïveProxy主进程..."
	run_bg naive --listen=socks://127.0.0.1:23456 --proxy=${ss_basic_naive_prot}://${ss_basic_naive_user}:${ss_basic_password}@${ss_basic_server}:${ss_basic_naive_port}
	detect_running_status2 naive 23456
}
FORK_CUT_DOGE10

# FORK: cut in doge.10, see doc/design/protocol-roadmap.md §2
: <<'FORK_CUT_DOGE10'
start_tuic(){
	if [ -f "/koolshare/bin/tuic-client" ];then
		chmod +x /koolshare/bin/tuic-client
		local ret=$(run /koolshare/bin/tuic-client --help 2>&1)
		if [ -z "${ret}" ];then
			echo_date "检测到/koolshare/bin/目录下存在tuic-client文件，但是无法运行！"
			echo_date "请确保你下载了正确的二进制文件！"
			close_in_five flag
		fi
	else
		local pkg_arch=$(cat /koolshare/webs/Module_shadowsocks.asp | tr -d '\r' | grep -Eo "PKG_ARCH=.+"|awk -F "=" '{print $2}'|sed 's/"//g')
		echo_date ""
		echo_date "+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"
		echo_date ""
		echo_date "重要提醒！！"
		echo_date ""
		echo_date "检测到你需要使用tuic-client！但是当前/koolshare/bin目录下缺少此二进制文件！"
		echo_date "请前往下面的链接下载对应平台的tuic-client，并将其放置在路由器的/koolshare/bin目录后重启插件！"
		echo_date "https://raw.githubusercontent.com/hq450/fancyss/3.0/fancyss/bin-${pkg_arch}/tuic-client"
		echo_date ""
		echo_date "+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"
		echo_date ""
		close_in_five flag
	fi
	
	rm -rf /koolshare/ss/tuic.json 2>/dev/null
	echo "${ss_basic_tuic_json}" | base64_decode >/tmp/tuic_tmp_1.json
	local RELAY=$(cat /tmp/tuic_tmp_1.json | run jq '.relay')

	echo_date "解析tuic配置文件..."
	echo "{\"local\": {\"server\": \"127.0.0.1:23456\"},\"log_level\": \"warn\"}" | run jq --argjson args "$RELAY" '. + {relay: ($args + {startup_mode: "eager"})}' >/koolshare/ss/tuic.json

	# 检测用户是否配置了ip地址
	local tuic_server_raw=$(cat /koolshare/ss/tuic.json | run jq -r '.relay.server')
	local tuic_server=""
	case "${tuic_server_raw}" in
	\[*\]:*)
		tuic_server="${tuic_server_raw#\[}"
		tuic_server="${tuic_server%\]:*}"
		;;
	\[*\])
		tuic_server="${tuic_server_raw#\[}"
		tuic_server="${tuic_server%\]}"
		;;
	*:* )
		tuic_server="${tuic_server_raw%:*}"
		;;
	*)
		tuic_server="${tuic_server_raw}"
		;;
	esac
	if [ -z "${tuic_server}" -o "${tuic_server}" == "null" ];then
		echo_date "检测到你的tuic配置文件未配置服务器地址/域名，请修改配置，退出！"
		close_in_five
	fi

	local tuic_server_is_domain=""
	[ -n "$(is_domain "${tuic_server}")" ] && tuic_server_is_domain="1"
	cat /koolshare/ss/tuic.json | run jq 'del(.relay.ip)' | run sponge /koolshare/ss/tuic.json
	if [ -n "${tuic_server_is_domain}" ];then
		echo_date "检测到tuic节点使用【动态解析】模式，移除 relay.ip，保留 relay.server 域名直连解析。"
	else
		echo_date "检测到tuic配置server已直接使用ip地址：${tuic_server}，跳过域名解析。"
	fi
	
	echo_date "开启ipt2socks进程..."
	run_bg ipt2socks -p 23456 -l 3333 -b 0.0.0.0 -B :: -n 10000 -R
	detect_running_status2 ipt2socks 23456
	
	echo_date "开启tuic-client主进程..."
	run_bg tuic-client -c /koolshare/ss/tuic.json
	detect_running_status tuic-client
}
FORK_CUT_DOGE10

anytls_hostport() {
	local host="$1"
	local port="$2"

	case "${host}" in
	*:* )
		case "${host}" in
		\[*\])
			printf '%s:%s' "${host}" "${port}"
			;;
		*)
			printf '[%s]:%s' "${host}" "${port}"
			;;
		esac
		;;
	*)
		printf '%s:%s' "${host}" "${port}"
		;;
	esac
}

start_anytls(){
	local ret=""
	local server_addr=""
	local pass_file="/tmp/anytls_pass"
	local verify_arg=""

	if [ -f "/koolshare/bin/anytls-zig" ];then
		chmod +x /koolshare/bin/anytls-zig
		ret=$(run /koolshare/bin/anytls-zig --version 2>&1)
		if [ -z "${ret}" ];then
			echo_date "检测到/koolshare/bin/目录下存在anytls-zig文件，但是无法运行！"
			echo_date "请确保你下载了正确的二进制文件！"
			close_in_five flag
		fi
	else
		local pkg_arch=$(cat /koolshare/webs/Module_shadowsocks.asp | tr -d '\r' | grep -Eo "PKG_ARCH=.+"|awk -F "=" '{print $2}'|sed 's/"//g')
		echo_date ""
		echo_date "+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"
		echo_date ""
		echo_date "重要提醒！！"
		echo_date ""
		echo_date "检测到你需要使用AnyTLS！但是当前/koolshare/bin目录下缺少anytls-zig二进制文件！"
		echo_date "请安装fancyss full版本，或确认对应平台的anytls-zig已经正确安装。"
		echo_date "当前平台：${pkg_arch}"
		echo_date ""
		echo_date "+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"
		echo_date ""
		close_in_five flag
	fi

	[ -n "${ss_basic_anytls_server}" ] || {
		echo_date "检测到AnyTLS节点未配置服务器地址/域名，请修改配置，退出！"
		close_in_five flag
	}
	[ -n "${ss_basic_anytls_port}" ] || ss_basic_anytls_port="443"
	[ -n "${ss_basic_anytls_pass}" ] || {
		echo_date "检测到AnyTLS节点未配置密码，请修改配置，退出！"
		close_in_five flag
	}

	server_addr="$(anytls_hostport "${ss_basic_anytls_server}" "${ss_basic_anytls_port}")"
	printf '%s' "${ss_basic_anytls_pass}" > "${pass_file}"
	if [ "${ss_basic_anytls_ai}" = "1" ]; then
		verify_arg="--insecure"
	else
		verify_arg="--verify"
	fi

	echo_date "开启ipt2socks进程..."
	run_bg ipt2socks -p 23456 -l 3333 -b 0.0.0.0 -B :: -n 10000 -R
	detect_running_status2 ipt2socks 23456

	echo_date "开启AnyTLS客户端进程..."
	if [ -n "${ss_basic_anytls_sni}" ]; then
		run_bg /koolshare/bin/anytls-zig -server "${server_addr}" --password-file "${pass_file}" -l 127.0.0.1:23456 -sni "${ss_basic_anytls_sni}" "${verify_arg}"
	else
		run_bg /koolshare/bin/anytls-zig -server "${server_addr}" --password-file "${pass_file}" -l 127.0.0.1:23456 "${verify_arg}"
	fi
	detect_running_status3 anytls-zig 23456 1 force
}

write_cron_job() {
	# 定时规则更新
	sed -i '/ssupdate/d' /var/spool/cron/crontabs/* >/dev/null 2>&1
	if [ "1" == "${ss_basic_rule_update}" ]; then
		echo_date "⏰️fancyss规则定时更新任务启用，每天${ss_basic_rule_update_time}点自动检测更新规则."
		cru a ssupdate "0 ${ss_basic_rule_update_time} * * * /bin/sh /koolshare/scripts/ss_rule_update.sh"
	else
		echo_date "❎️fancyss规则定时更新任务未启用！"
	fi
	
	# 定时订阅
	sed -i '/ssnodeupdate/d' /var/spool/cron/crontabs/* >/dev/null 2>&1
	if [ "${ss_basic_node_update}" == "1" ]; then
		if [ "${ss_basic_node_update_day}" == "0" ]; then
			cru a ssnodeupdate "0 ${ss_basic_node_update_hr} * * * /koolshare/scripts/ss_node_subscribe.sh fancyss 3"
			echo_date "⏰️fancyss规则定时更新任务启用，每天${ss_basic_node_update_hr}点自动更新订阅。"
		else
			cru a ssnodeupdate "0 ${ss_basic_node_update_hr} * * ${ss_basic_node_update_day} /koolshare/scripts/ss_node_subscribe.sh fancyss 3"
			echo_date "⏰️fancyss规则定时更新任务启用，每周${ss_basic_node_update_day}的${ss_basic_node_update_hr}点自动更新订阅。"
		fi
	else
		echo_date "❎️fancyss定时更新订阅节点任务未启用！"
	fi
	
	# 定时webtest
	sed -i '/sslatencyjob/d' /var/spool/cron/crontabs/* >/dev/null 2>&1
	if [ "${ss_basic_lt_cru_opts}" == "1" ]; then
		echo_date "⏰️fancyss 节点web落地延迟检测任务启用，设置每隔${ss_basic_lt_cru_time}分钟检测一次..."
		sed -i '/sslatencyjob/d' /var/spool/cron/crontabs/* >/dev/null 2>&1
		cru a sslatencyjob "*/${ss_basic_lt_cru_time} * * * * /koolshare/scripts/ss_webtest.sh 2"
	else
		echo_date "❎️fancyss节点web落地延迟检测任务未启用！"
	fi
}

kill_cron_job() {
	if [ -n "$(cru l | grep ssupdate)" ]; then
		echo_date "删除fancyss规则定时更新任务..."
		sed -i '/ssupdate/d' /var/spool/cron/crontabs/* >/dev/null 2>&1
	fi
	if [ -n "$(cru l | grep ssnodeupdate)" ]; then
		echo_date "删除定时订阅任务..."
		sed -i '/ssnodeupdate/d' /var/spool/cron/crontabs/* >/dev/null 2>&1
	fi
	if [ -n "$(cru l | grep sslatencyjob)" ]; then
		echo_date 删除SSR定时订阅任务...
		sed -i '/sslatencyjob/d' /var/spool/cron/crontabs/* >/dev/null 2>&1
	fi
}
#--------------------------------------nat part begin------------------------------------------------
load_tproxy() {
	MODULES="xt_TPROXY xt_socket xt_comment"
	for MODULE in ${MODULES}
	do
		lsmod | grep ${MODULE} &>/dev/null
		if [ "$?" != "0" ]; then
			echo_date "加载${MODULE}模块..."
			modprobe ${MODULE}.ko
		else
			echo_date "${MODULE}模块已加载..."
		fi
	done
}

flush_ipset() {
	# doge.14: 分流架构唯一路径，直接走 split 实现（只 flush ignlist_minimal）
	flush_ipset_split
	return $?
}

# FORK doge.12 alpha: 极简化 ipset flush（只清 ignlist_minimal / 6）
flush_ipset_split() {
	# alpha.17 P2-4: split 路径 ipset 清理日志
	echo_date "清除 split 路径 ignlist_minimal ipset..."
	local existing_sets=$(ipset list -name 2>/dev/null)
	if [ -n "${existing_sets}" ]; then
		echo "${existing_sets}" | while IFS= read -r set_name; do
			case "${set_name}" in
			ignlist_minimal|ignlist_minimal6)
				ipset -F "${set_name}" >/dev/null 2>&1
				ipset -X "${set_name}" >/dev/null 2>&1
				;;
			esac
		done
	fi
	# 同时清 TPROXY 用的 ip rule / ip route
	local ip_rule_exist=$(ip rule show | grep "lookup 310" | grep -c 310)
	if [ -n "${ip_rule_exist}" ]; then
		until [ "${ip_rule_exist}" = "0" ]; do
			IP_ARG=$(ip rule show | grep "lookup 310" | head -n 1 | cut -d " " -f3,4,5,6)
			ip rule del $IP_ARG
			ip_rule_exist=$(expr $ip_rule_exist - 1)
		done
	fi
	ip route del local 0.0.0.0/0 dev lo table 310 >/dev/null 2>&1
	return 0
}

flush_iptables_restore_append() {
	local ipt="$1"
	local table="$2"
	local match="$3"
	local label="$4"
	local restore_file="$5"
	local rules=""
	local line=""
	local chain=""

	[ -n "${ipt}" ] || return 1
	[ -n "${restore_file}" ] || return 1
	rules="$("${ipt}" -t "${table}" -S 2>/dev/null | grep -E "${match}")"
	[ -n "${rules}" ] || return 1
	echo_date "${label}"
	{
		printf '*%s\n' "${table}"
		while IFS= read -r line
		do
			case "${line}" in
			-A\ *)
				printf -- '-D %s\n' "${line#-A }"
				;;
			esac
		done <<EOF
${rules}
EOF
		while IFS= read -r line
		do
			case "${line}" in
			-N\ *)
				chain="${line#-N }"
				printf -- '-F %s\n-X %s\n' "${chain}" "${chain}"
				;;
			esac
		done <<EOF
${rules}
EOF
		echo COMMIT
	} >> "${restore_file}"
	return 0
}

flush_iptables_legacy_table() {
	local ipt="$1"
	local table="$2"
	local match="$3"
	local label="$4"
	local rules=""
	local line=""
	local chain=""

	rules="$("${ipt}" -t "${table}" -S 2>/dev/null | grep -E "${match}" | sort)"
	[ -n "${rules}" ] || return 0
	echo_date "${label}"
	while IFS= read -r line
	do
		case "${line}" in
		-A\ *)
			set -- ${line}
			shift
			run_bg "${ipt}" -t "${table}" -D "$@"
			;;
		-N\ *)
			chain="${line#-N }"
			run_bg "${ipt}" -t "${table}" -F "${chain}"
			run_bg "${ipt}" -t "${table}" -X "${chain}"
			;;
		esac
	done <<EOF
${rules}
EOF
}

# creat ipset rules
creat_ipset() {
	echo_date "创建ipset名单"
	local chnroute4_file="/koolshare/ss/rules/chnroute.txt"
	local chnroute6_file="/koolshare/ss/rules/chnroute6.txt"

	# 使用ipset restore批量创建/清空并导入网段，减少大量 ipset 子进程调用，加快启动速度
	{
		echo "create ignlist nethash -exist"
		echo "flush ignlist"
		echo "create ignlist6 nethash family inet6 -exist"
		echo "flush ignlist6"

		echo "create white_list nethash -exist"
		echo "flush white_list"
		echo "create white_list6 nethash family inet6 -exist"
		echo "flush white_list6"

		echo "create black_list nethash -exist"
		echo "flush black_list"
		echo "create black_list6 nethash family inet6 -exist"
		echo "flush black_list6"

		echo "create chnlist nethash -exist"
		echo "flush chnlist"
		echo "create chnlist6 nethash family inet6 -exist"
		echo "flush chnlist6"

		echo "create gfwlist nethash -exist"
		echo "flush gfwlist"
		echo "create gfwlist6 nethash family inet6 -exist"
		echo "flush gfwlist6"

		echo "create router nethash -exist"
		echo "flush router"
		echo "create router6 nethash family inet6 -exist"
		echo "flush router6"

		echo "create chnroute nethash -exist"
		echo "flush chnroute"
		sed -e "s/^/add chnroute &/g" "${chnroute4_file}"

		echo "create chnroute6 nethash family inet6 -exist"
		echo "flush chnroute6"
		sed -e "s/^/add chnroute6 &/g" "${chnroute6_file}"

		echo "COMMIT"
	} | ipset -R
}

get_action_chain() {
	case "$1" in
	0)
		echo "RETURN"
		;;
	1)
		echo "SHADOWSOCKS_GFW"
		;;
	2)
		echo "SHADOWSOCKS_CHN"
		;;
	3)
		echo "SHADOWSOCKS_GAM"
		;;
	5)
		echo "SHADOWSOCKS_GLO"
		;;
	6)
		echo "SHADOWSOCKS_HOM"
		;;
	esac
}

get_action_chain6() {
	case "$1" in
	0)
		echo "RETURN"
		;;
	1)
		echo "SHADOWSOCKS6_GFW"
		;;
	2)
		echo "SHADOWSOCKS6_CHN"
		;;
	3)
		echo "SHADOWSOCKS6_GAM"
		;;
	5)
		echo "SHADOWSOCKS6_GLO"
		;;
	6)
		echo "SHADOWSOCKS6_HOM"
		;;
	esac
}

get_mode_name() {
	case "$1" in
	0)
		echo "不通过代理"
		;;
	1)
		echo "gfwlist模式"
		;;
	2)
		echo "大陆白名单模式"
		;;
	3)
		echo "游戏模式"
		;;
	5)
		echo "全局模式"
		;;
	6)
		echo "回国模式"
		;;
	7)
		echo "xray分流模式"
		;;
	esac
}

factor() {
	if [ -z "$1" -o -z "$2" ]; then
		echo ""
	else
		echo "$2 $1"
	fi
}

get_jump_mode() {
	case "$1" in
	0)
		echo "j"
		;;
	*)
		echo "g"
		;;
	esac
}

acl_proxy_supports_udp() {
	proxy_core_supports_udp || return 1
	return 0
}

note_acl_udp_unsupported_once() {
	if [ "${ACL_UDP_UNSUPPORTED_NOTICE}" != "1" ]; then
		echo_date "⚠️因当前节点协议不支持UDP代理，访问控制中的UDP代理开关将被忽略，并默认屏蔽对应规则的QUIC流量。"
		ACL_UDP_UNSUPPORTED_NOTICE="1"
	fi
}

note_acl_quic_forced_once() {
	if [ "${ACL_QUIC_FORCED_NOTICE}" != "1" ]; then
		echo_date "⚠️检测到访问控制存在“UDP代理关闭且未屏蔽QUIC”的组合，已自动按“屏蔽QUIC”处理。"
		ACL_QUIC_FORCED_NOTICE="1"
	fi
}

get_acl_udp_flag() {
	local acl="$1"
	local proxy_mode="$2"
	local udp_flag=""
	if ! acl_proxy_supports_udp; then
		if [ "${proxy_mode}" != "0" ]; then
			note_acl_udp_unsupported_once
		fi
		echo "0"
		return
	fi
	if [ "${proxy_mode}" == "3" ];then
		echo "1"
		return
	fi
	if [ -n "${acl}" ];then
		eval udp_flag=\$ss_acl_udp_${acl}
	else
		udp_flag="$(resolve_acl_default_udp_raw)"
	fi
	if [ -z "${udp_flag}" ];then
		if [ -n "${acl}" ];then
			if [ "${ss_basic_udpall}" == "1" ];then
				udp_flag="1"
			else
				udp_flag="0"
			fi
		else
			udp_flag="0"
		fi
	fi
	echo "${udp_flag}"
}

get_acl_quic_flag() {
	local acl="$1"
	local proxy_mode="$2"
	local udp_flag="$3"
	local quic_flag=""
	if [ -n "${acl}" ];then
		eval quic_flag=\$ss_acl_quic_${acl}
	else
		quic_flag="${ss_acl_default_quic}"
	fi
	if [ -z "${quic_flag}" ];then
		if [ -n "${acl}" ];then
			if [ -n "${ss_basic_block_quic}" ];then
				quic_flag="${ss_basic_block_quic}"
			else
				quic_flag="1"
			fi
		else
			quic_flag="1"
		fi
	fi
	if [ "${proxy_mode}" != "0" ]; then
		if ! acl_proxy_supports_udp; then
			note_acl_udp_unsupported_once
			quic_flag="1"
		elif [ "${udp_flag}" != "1" ] && [ "${quic_flag}" != "1" ]; then
			note_acl_quic_forced_once
			quic_flag="1"
		fi
	fi
	echo "${quic_flag}"
}

get_acl_source_rule4() {
	local acl="$1"
	local ipaddr=""
	local acl_mac=""
	eval ipaddr=\$ss_acl_ip_${acl}
	if acl_is_cidr_rule "${ipaddr}"; then
		echo "$(factor "${ipaddr}" "-s")"
		return 0
	fi
	acl_mac=$(resolve_acl_mac "${acl}")
	if [ -n "${acl_mac}" ]; then
		echo "-m mac --mac-source ${acl_mac}"
	else
		echo "$(factor "${ipaddr}" "-s")"
	fi
}

get_acl_source_rule6() {
	local acl="$1"
	local ipaddr=""
	local acl_mac=""
	eval ipaddr=\$ss_acl_ip_${acl}
	acl_is_cidr_rule "${ipaddr}" && return 1
	acl_mac=$(resolve_acl_mac "${acl}")
	[ -n "${acl_mac}" ] || return 1
	echo "-m mac --mac-source ${acl_mac}"
}

apply_acl_udp_rule() {
	local acl_desc="$1"
	local source_rule="$2"
	local ports="$3"
	local proxy_mode="$4"
	local udp_flag="$5"
	local quic_flag="$6"

	if [ "${proxy_mode}" != "0" -a "${udp_flag}" == "1" ];then
		echo_date "UDP代理规则：【${acl_desc}】开启UDP代理，模式：$(get_mode_name ${proxy_mode})"
		if [ "${quic_flag}" == "1" ];then
			echo_date "UDP 443处理：【${acl_desc}】屏蔽QUIC流量，先直连放行至filter表进一步处理。"
			iptables -t mangle -A SHADOWSOCKS ${source_rule} -p udp --dport 443 -j RETURN
		else
			echo_date "UDP 443处理：【${acl_desc}】不屏蔽QUIC流量。"
		fi
		iptables -t mangle -A SHADOWSOCKS ${source_rule} -p udp $(factor ${ports} "-m multiport --dport") -$(get_jump_mode ${proxy_mode}) $(get_action_chain ${proxy_mode})
	else
		if [ "${proxy_mode}" == "0" ];then
			echo_date "UDP代理规则：【${acl_desc}】不通过代理，UDP流量直连。"
		elif ! acl_proxy_supports_udp; then
			echo_date "UDP代理规则：【${acl_desc}】当前节点不支持UDP代理，已忽略UDP代理设置。"
		else
			echo_date "UDP代理规则：【${acl_desc}】关闭UDP代理。"
		fi
		iptables -t mangle -A SHADOWSOCKS ${source_rule} -p udp -j RETURN
	fi
}

apply_acl_quic_filter_rule() {
	local acl_desc="$1"
	local source_rule="$2"
	local proxy_mode="$3"
	local quic_flag="$4"

	if [ "${proxy_mode}" == "0" ];then
		echo_date "UDP 443过滤规则：【${acl_desc}】不通过代理，UDP 443直连。"
		append_if_not_exists filter -A SHADOWSOCKS ${source_rule} -p udp --dport 443 -j RETURN
	elif ! acl_proxy_supports_udp; then
		echo_date "UDP 443过滤规则：【${acl_desc}】因当前节点不支持UDP代理，默认屏蔽QUIC流量，按$(get_mode_name ${proxy_mode})处理海外UDP 443。"
		append_if_not_exists filter -A SHADOWSOCKS ${source_rule} -p udp --dport 443 -$(get_jump_mode ${proxy_mode}) $(get_action_chain ${proxy_mode})
	elif [ "${quic_flag}" == "1" ];then
		echo_date "UDP 443过滤规则：【${acl_desc}】屏蔽QUIC流量，按$(get_mode_name ${proxy_mode})处理海外UDP 443。"
		append_if_not_exists filter -A SHADOWSOCKS ${source_rule} -p udp --dport 443 -$(get_jump_mode ${proxy_mode}) $(get_action_chain ${proxy_mode})
	else
		echo_date "UDP 443过滤规则：【${acl_desc}】不屏蔽QUIC流量。"
		append_if_not_exists filter -A SHADOWSOCKS ${source_rule} -p udp --dport 443 -j RETURN
	fi
}

append_acl_desc_list() {
	local current="$1"
	local value="$2"
	if [ -z "${value}" ];then
		echo "${current}"
	elif [ -n "${current}" ];then
		echo "${current}、${value}"
	else
		echo "${value}"
	fi
}

resolve_ipv6_default_acl() {
	local acl_nu=$(get_acl_rule_indexes)
	local acl=""
	local ipaddr=""
	local source_rule6=""

	IPV6_ACL_RULES=""
	IPV6_ACL_SKIP_CIDR=""
	IPV6_ACL_SKIP_NOMAC=""
	IPV6_ACL_TOTAL_COUNT="0"
	IPV6_ACL_ACTIVE_COUNT="0"

	if [ -n "${acl_nu}" ]; then
		IPV6_ACL_HAS_CUSTOM="1"
		IPV6_ACL_DEFAULT_MODE="$(resolve_acl_default_mode 1)"
		for acl in ${acl_nu}
		do
			ipaddr=$(eval echo \$ss_acl_ip_${acl})
			IPV6_ACL_TOTAL_COUNT=$((${IPV6_ACL_TOTAL_COUNT} + 1))
			if acl_is_cidr_rule "${ipaddr}"; then
				IPV6_ACL_SKIP_CIDR=$(append_acl_desc_list "${IPV6_ACL_SKIP_CIDR}" "${ipaddr}")
				continue
			fi
			source_rule6=$(get_acl_source_rule6 ${acl})
			if [ -n "${source_rule6}" ];then
				IPV6_ACL_RULES="${IPV6_ACL_RULES} ${acl}"
				IPV6_ACL_ACTIVE_COUNT=$((${IPV6_ACL_ACTIVE_COUNT} + 1))
			else
				IPV6_ACL_SKIP_NOMAC=$(append_acl_desc_list "${IPV6_ACL_SKIP_NOMAC}" "${ipaddr}")
			fi
		done
		if [ "${IPV6_ACL_ACTIVE_COUNT}" -gt "0" ];then
			IPV6_ACL_DEFAULT_LABEL="剩余IPv6主机"
		else
			IPV6_ACL_DEFAULT_LABEL="全部IPv6主机"
		fi
	else
		IPV6_ACL_DEFAULT_LABEL="全部IPv6主机"
		IPV6_ACL_HAS_CUSTOM="0"
		IPV6_ACL_DEFAULT_MODE="$(resolve_acl_default_mode 0)"
	fi
	IPV6_ACL_DEFAULT_PORTS="$(resolve_acl_ports "$(resolve_acl_default_ports_raw)" "${IPV6_ACL_DEFAULT_MODE}")"
}

apply_acl_udp_rule6() {
	local acl_desc="$1"
	local source_rule="$2"
	local ports="$3"
	local proxy_mode="$4"
	local udp_flag="$5"
	local quic_flag="$6"

	if [ "${proxy_mode}" != "0" -a "${udp_flag}" == "1" ];then
		echo_date "IPv6 UDP代理规则：【${acl_desc}】开启UDP代理，模式：$(get_mode_name ${proxy_mode})"
		if [ "${quic_flag}" == "1" ];then
			echo_date "IPv6 UDP 443处理：【${acl_desc}】屏蔽QUIC流量，先直连放行至filter表进一步处理。"
			append_if_not_exists6 mangle -A SHADOWSOCKS6 ${source_rule} -p udp --dport 443 -j RETURN || return 1
		else
			echo_date "IPv6 UDP 443处理：【${acl_desc}】不屏蔽QUIC流量。"
		fi
		append_if_not_exists6 mangle -A SHADOWSOCKS6 ${source_rule} -p udp $(factor ${ports} "-m multiport --dport") -$(get_jump_mode ${proxy_mode}) $(get_action_chain6 ${proxy_mode}) || return 1
	else
		if [ "${proxy_mode}" == "0" ];then
			echo_date "IPv6 UDP代理规则：【${acl_desc}】不通过代理，UDP流量直连。"
		elif ! acl_proxy_supports_udp; then
			echo_date "IPv6 UDP代理规则：【${acl_desc}】当前节点不支持UDP代理，已忽略UDP代理设置。"
		else
			echo_date "IPv6 UDP代理规则：【${acl_desc}】关闭UDP代理。"
		fi
		append_if_not_exists6 mangle -A SHADOWSOCKS6 ${source_rule} -p udp -j RETURN || return 1
	fi
}

apply_acl_quic_filter_rule6() {
	local acl_desc="$1"
	local source_rule="$2"
	local proxy_mode="$3"
	local quic_flag="$4"

	if [ "${proxy_mode}" == "0" ];then
		echo_date "IPv6 UDP 443过滤规则：【${acl_desc}】不通过代理，UDP 443直连。"
		append_if_not_exists6 filter -A SHADOWSOCKS6 ${source_rule} -p udp --dport 443 -j RETURN || return 1
	elif ! acl_proxy_supports_udp; then
		echo_date "IPv6 UDP 443过滤规则：【${acl_desc}】因当前节点不支持UDP代理，默认屏蔽QUIC流量，按$(get_mode_name ${proxy_mode})处理海外UDP 443。"
		append_if_not_exists6 filter -A SHADOWSOCKS6 ${source_rule} -p udp --dport 443 -$(get_jump_mode ${proxy_mode}) $(get_action_chain6 ${proxy_mode}) || return 1
	elif [ "${quic_flag}" == "1" ];then
		echo_date "IPv6 UDP 443过滤规则：【${acl_desc}】屏蔽QUIC流量，按$(get_mode_name ${proxy_mode})处理海外UDP 443。"
		append_if_not_exists6 filter -A SHADOWSOCKS6 ${source_rule} -p udp --dport 443 -$(get_jump_mode ${proxy_mode}) $(get_action_chain6 ${proxy_mode}) || return 1
	else
		echo_date "IPv6 UDP 443过滤规则：【${acl_desc}】不屏蔽QUIC流量。"
		append_if_not_exists6 filter -A SHADOWSOCKS6 ${source_rule} -p udp --dport 443 -j RETURN || return 1
	fi
}

apply_quic_block() {
	# lan access control
	local default_mode=""
	acl_nu=$(get_acl_rule_indexes)
	if [ -n "$acl_nu" ]; then
		# 先设定访问控制内的主机
		for acl in $acl_nu; do
			ipaddr=$(eval echo \$ss_acl_ip_$acl)
			proxy_mode=$(eval echo \$ss_acl_mode_$acl)
			udp_flag=$(get_acl_udp_flag ${acl} ${proxy_mode})
			quic_flag=$(get_acl_quic_flag ${acl} ${proxy_mode} "${udp_flag}")
			apply_acl_quic_filter_rule "${ipaddr}" "$(get_acl_source_rule4 ${acl})" "${proxy_mode}" "${quic_flag}"
		done
		default_mode="$(resolve_acl_default_mode 1)"
		udp_flag=$(get_acl_udp_flag "" "${default_mode}")
		quic_flag=$(get_acl_quic_flag "" "${default_mode}" "${udp_flag}")
		apply_acl_quic_filter_rule "剩余主机" "" "${default_mode}" "${quic_flag}"
	else
		default_mode="$(resolve_acl_default_mode 0)"
		udp_flag=$(get_acl_udp_flag "" "${default_mode}")
		quic_flag=$(get_acl_quic_flag "" "${default_mode}" "${udp_flag}")
		apply_acl_quic_filter_rule "全部主机" "" "${default_mode}" "${quic_flag}"
	fi
}

lan_access_control() {
	# lan access control
	local default_mode=""
	local default_ports=""
	acl_nu=$(get_acl_rule_indexes)
	if [ -n "$acl_nu" ]; then
		acl_default_label="剩余主机"
		for acl in $acl_nu; do
			ipaddr=$(eval echo \$ss_acl_ip_$acl)
			ipaddr_hex=$(get_acl_ip_mark "${ipaddr}")
			source_rule=$(get_acl_source_rule4 ${acl})
			proxy_mode=$(eval echo \$ss_acl_mode_$acl)
			ports=$(resolve_acl_ports "$(eval echo \$ss_acl_port_$acl)" "${proxy_mode}")
			proxy_name=$(eval echo \$ss_acl_name_$acl)
			udp_flag=$(get_acl_udp_flag ${acl} ${proxy_mode})
			quic_flag=$(get_acl_quic_flag ${acl} ${proxy_mode} "${udp_flag}")
			if [ "$ports" == "all" ]; then
				ports=""
				echo_date "加载ACL规则：【$ipaddr】【全部端口】模式为：$(get_mode_name $proxy_mode)"
			else
				echo_date "加载ACL规则：【$ipaddr】【$ports】模式为：$(get_mode_name $proxy_mode)"
			fi
			# 1 acl in SHADOWSOCKS for nat
			iptables -t nat -A SHADOWSOCKS ${source_rule} -p tcp $(factor $ports "-m multiport --dport") -$(get_jump_mode $proxy_mode) $(get_action_chain $proxy_mode)
			
			# 2 acl in OUTPUT（used by koolproxy）
			iptables -t nat -A SHADOWSOCKS_EXT -p tcp $(factor $ports "-m multiport --dport") -m mark --mark "$ipaddr_hex" -$(get_jump_mode $proxy_mode) $(get_action_chain $proxy_mode)
			
			# 3 acl in SHADOWSOCKS for mangle
			apply_acl_udp_rule "${ipaddr}" "${source_rule}" "${ports}" "${proxy_mode}" "${udp_flag}" "${quic_flag}"
		done

		default_mode="$(resolve_acl_default_mode 1)"
		default_ports="$(resolve_acl_ports "$(resolve_acl_default_ports_raw)" "${default_mode}")"
		if [ "${default_ports}" == "all" ]; then
			default_ports=""
			echo_date "加载ACL规则：【${acl_default_label}】【全部端口】模式为：$(get_mode_name ${default_mode})"
		else
			echo_date "加载ACL规则：【${acl_default_label}】【${default_ports}】模式为：$(get_mode_name ${default_mode})"
		fi
	else
		acl_default_label="全部主机"
		default_mode="$(resolve_acl_default_mode 0)"
		default_ports="$(resolve_acl_ports "$(resolve_acl_default_ports_raw)" "${default_mode}")"
		if [ "${default_ports}" == "all" ]; then
			default_ports=""
			echo_date "加载ACL规则：【${acl_default_label}】【全部端口】模式为：$(get_mode_name ${default_mode})"
		else
			echo_date "加载ACL规则：【${acl_default_label}】【${default_ports}】模式为：$(get_mode_name ${default_mode})"
		fi
	fi
	dbus remove ss_acl_ip
	dbus remove ss_acl_mac
	dbus remove ss_acl_name
	dbus remove ss_acl_mode
	dbus remove ss_acl_port
	dbus remove ss_acl_udp
	dbus remove ss_acl_quic
}

dns_hijack_control() {
	local type=${1:-4}
	if [ "${type}" == "4" ];then
		local iptab=iptables
		local chain_prefix=SHADOWSOCKS_DNS
	elif [ "${type}" == "6" ];then
		local iptab=ip6tables
		local chain_prefix=SHADOWSOCKS6_DNS
	fi
	
	if [ "$ss_basic_dns_hijack" == "1" ]; then
		for VLAN_INDEX in ${VLAN_INDEXS}
		do
			if [ "${type}" == "4" ];then
				local dest_ipaddr=$(ifconfig br${VLAN_INDEX} | grep "inet addr" | awk '{print $2}'|awk -F ":" '{print $2}')
			else
				local dest_ipaddr=$(ip -6 addr show dev br${VLAN_INDEX} scope global 2>/dev/null | awk '/inet6/ {print $2}' | head -n1 | awk -F "/" '{print $1}')
				if [ -z "${dest_ipaddr}" ];then
					echo_date "IPv6 DNS劫持：未获取到br${VLAN_INDEX}的IPv6地址，跳过该接口。"
					continue
				fi
			fi
			local acl_nu=$(get_acl_rule_indexes)
			if [ -n "$acl_nu" ]; then
				for acl in $acl_nu; do
					ipaddr=$(eval echo \$ss_acl_ip_$acl)
					proxy_mode=$(eval echo \$ss_acl_mode_$acl)
					if [ "${proxy_mode}" == "0" ]; then
						if [ "${type}" == "4" ];then
							local source_rule=$(get_acl_source_rule4 ${acl})
							${iptab} -t nat -A ${chain_prefix}_${VLAN_INDEX} ${source_rule} -p udp -j RETURN
						else
							local source_rule6=$(get_acl_source_rule6 ${acl})
							if [ -n "${source_rule6}" ]; then
								${iptab} -t nat -A ${chain_prefix}_${VLAN_INDEX} ${source_rule6} -p udp -j RETURN
							elif acl_is_cidr_rule "${ipaddr}"; then
								echo_date "IPv6 DNS劫持：ACL【${ipaddr}】为CIDR规则，无法按设备豁免DNS劫持，继续按IPv6默认DNS规则处理。"
							else
								echo_date "IPv6 DNS劫持：ACL【${ipaddr}】未获取到MAC地址，无法按设备豁免DNS劫持，继续按IPv6默认DNS规则处理。"
							fi
						fi
					fi
				done
			fi
			if [ "${type}" == "4" ];then
				${iptab} -t nat -A ${chain_prefix}_${VLAN_INDEX} -p udp -j DNAT --to ${dest_ipaddr}:53
			else
				${iptab} -t nat -A ${chain_prefix}_${VLAN_INDEX} -p udp -j DNAT --to-destination [${dest_ipaddr}]:53
			fi
		done
	fi
}

flush_iptables() {
	# use different xtables libdir
	local restore_v4="/tmp/fss_iptables_flush.$$"
	local restore_v6="/tmp/fss_ip6tables_flush.$$"
	local need_v4="0"
	local need_v6="0"
	local restore_v4_ok="0"
	local restore_v6_ok="0"
	if [ -d "/tmp/.xt" ];then
		export XTABLES_LIBDIR=/tmp/.xt
	fi

	: > "${restore_v4}" || true
	: > "${restore_v6}" || true
	flush_iptables_restore_append iptables nat "SHADOWSOCKS|3333" "清除iptables nat规则..." "${restore_v4}" && need_v4="1"
	flush_iptables_restore_append iptables mangle "SHADOWSOCKS|3333|0x7" "清除iptables mangle规则..." "${restore_v4}" && need_v4="1"
	flush_iptables_restore_append iptables filter "SHADOWSOCKS" "清除iptables filter规则..." "${restore_v4}" && need_v4="1"
	flush_iptables_restore_append ip6tables nat "SHADOWSOCKS6|3333|3334" "清除ip6tables nat规则..." "${restore_v6}" && need_v6="1"
	flush_iptables_restore_append ip6tables mangle "SHADOWSOCKS6|3333|3334|0x7" "清除ip6tables mangle规则..." "${restore_v6}" && need_v6="1"
	flush_iptables_restore_append ip6tables filter "SHADOWSOCKS6" "清除ip6tables filter规则..." "${restore_v6}" && need_v6="1"
	if [ "${need_v4}" = "1" ] && iptables-restore -n < "${restore_v4}" >/dev/null 2>&1; then
		restore_v4_ok="1"
	fi
	if [ "${need_v6}" = "1" ] && ip6tables-restore -n < "${restore_v6}" >/dev/null 2>&1; then
		restore_v6_ok="1"
	fi
	rm -f "${restore_v4}" "${restore_v6}" >/dev/null 2>&1
	if [ "${need_v4}" = "1" ] && [ "${restore_v4_ok}" != "1" ]; then
		flush_iptables_legacy_table iptables nat "SHADOWSOCKS|3333" "清除iptables nat规则..."
		flush_iptables_legacy_table iptables mangle "SHADOWSOCKS|3333|0x7" "清除iptables mangle规则..."
		flush_iptables_legacy_table iptables filter "SHADOWSOCKS" "清除iptables filter规则..."
	fi
	if [ "${need_v6}" = "1" ] && [ "${restore_v6_ok}" != "1" ]; then
		flush_iptables_legacy_table ip6tables nat "SHADOWSOCKS6|3333|3334" "清除ip6tables nat规则..."
		flush_iptables_legacy_table ip6tables mangle "SHADOWSOCKS6|3333|3334|0x7" "清除ip6tables mangle规则..."
		flush_iptables_legacy_table ip6tables filter "SHADOWSOCKS6" "清除ip6tables filter规则..."
	fi

	local ip6_rule_exist=$(ip -6 rule show 2>/dev/null | grep "lookup 310" | grep -c 310)
	if [ -n "${ip6_rule_exist}" ]; then
		until [ "${ip6_rule_exist}" == "0" ]; do
			IP6_ARG=$(ip -6 rule show 2>/dev/null | grep "lookup 310" | head -n 1 | cut -d " " -f3,4,5,6)
			ip -6 rule del $IP6_ARG >/dev/null 2>&1
			ip6_rule_exist=$(expr $ip6_rule_exist - 1)
		done
	fi
	ip -6 route del local ::/0 dev lo table 310 >/dev/null 2>&1
}

stop_dns_process() {
	local CHNG_PID=$(pidof chinadns-ng)
	if [ -n "${CHNG_PID}" ];then
		echo_date "关闭chinadns-ng进程..."
		if [ -d "/koolshare/perp/chinadns-ng" ];then
			perpctl d chinadns-ng >/dev/null 2>&1
			rm -rf /koolshare/perp/chinadns-ng >/dev/null 2>&1
		fi
		killall chinadns-ng >/dev/null 2>&1
		kill -9 ${CHNG_PID} >/dev/null 2>&1
	fi

	local smartdns_process=$(pidof smartdns)
	if [ -n "$smartdns_process" ]; then
		echo_date "关闭smartdns进程..."
		killall smartdns >/dev/null 2>&1
	fi

}

flush_ip6tables() {
	if [ -d "/tmp/.xt" ];then
		export XTABLES_LIBDIR=/tmp/.xt
	fi

	local NAT6_RULES=$(ip6tables -t nat -S 2>/dev/null | grep -E "SHADOWSOCKS6|3333|3334" | sort)
	if [ -n "${NAT6_RULES}" ];then
		echo_date "清除ip6tables nat规则..."
		echo "${NAT6_RULES}" | while read line
		do
			local TYPE=$(echo "$line" | awk '{print $1}' | sed 's/^-//g')
			if [ "${TYPE}" == "A" ];then
				local CMD1=$(echo "$line" | sed 's/^-A/ip6tables -t nat -D/g')
				run_bg $CMD1
			elif [ "${TYPE}" == "N" ];then
				local CMD2=$(echo "$line" | sed 's/^-N/ip6tables -t nat -F/g')
				run_bg $CMD2
				local CMD3=$(echo "$line" | sed 's/^-N/ip6tables -t nat -X/g')
				run_bg $CMD3
			fi
		done
	fi

	local MANGLE6_RULES=$(ip6tables -t mangle -S 2>/dev/null | grep -E "SHADOWSOCKS6|3333|3334|0x7" | sort)
	if [ -n "${MANGLE6_RULES}" ];then
		echo_date "清除ip6tables mangle规则..."
		echo "${MANGLE6_RULES}" | while read line
		do
			local TYPE=$(echo "$line" | awk '{print $1}' | sed 's/^-//g')
			if [ "${TYPE}" == "A" ];then
				local CMD1=$(echo "$line" | sed 's/^-A/ip6tables -t mangle -D/g')
				run_bg $CMD1
			elif [ "${TYPE}" == "N" ];then
				local CMD2=$(echo "$line" | sed 's/^-N/ip6tables -t mangle -F/g')
				run_bg $CMD2
				local CMD3=$(echo "$line" | sed 's/^-N/ip6tables -t mangle -X/g')
				run_bg $CMD3
			fi
		done
	fi

	local FILTER6_RULES=$(ip6tables -t filter -S 2>/dev/null | grep -E "SHADOWSOCKS6" | sort)
	if [ -n "${FILTER6_RULES}" ];then
		echo_date "清除ip6tables filter规则..."
		echo "${FILTER6_RULES}" | while read line
		do
			local TYPE=$(echo "$line" | awk '{print $1}' | sed 's/^-//g')
			if [ "${TYPE}" == "A" ];then
				local CMD1=$(echo "$line" | sed 's/^-A/ip6tables -t filter -D/g')
				run_bg $CMD1
			elif [ "${TYPE}" == "N" ];then
				local CMD2=$(echo "$line" | sed 's/^-N/ip6tables -t filter -F/g')
				run_bg $CMD2
				local CMD3=$(echo "$line" | sed 's/^-N/ip6tables -t filter -X/g')
				run_bg $CMD3
			fi
		done
	fi

	local ip6_rule_exist=$(ip -6 rule show 2>/dev/null | grep "lookup 310" | grep -c 310)
	if [ -n "${ip6_rule_exist}" ]; then
		until [ "${ip6_rule_exist}" == "0" ]; do
			IP6_ARG=$(ip -6 rule show 2>/dev/null | grep "lookup 310" | head -n 1 | cut -d " " -f3,4,5,6)
			ip -6 rule del $IP6_ARG >/dev/null 2>&1
			ip6_rule_exist=$(expr $ip6_rule_exist - 1)
		done
	fi
	ip -6 route del local ::/0 dev lo table 310 >/dev/null 2>&1
}

disable_ipv6_proxy_runtime() {
	ss_basic_proxy_ipv6="0"
	ss_basic_chng_ipv6_drop_proxy="1"
	dbus set ss_basic_proxy_ipv6="0"
	dbus set ss_basic_chng_ipv6_drop_proxy="1"
}

fallback_ipv6_proxy_to_ipv4() {
	echo_date "⚠️检测到IPv6透明代理规则写入失败，开始回退到IPv4代理模式..."
	flush_ip6tables
	disable_ipv6_proxy_runtime
	echo_date "↪ 已同步关闭前端的IPv6代理开关，并强制开启代理域名IPv6过滤。"
	stop_dns_process
	start_dns_x
	echo_date "✅ 已回退为IPv4代理模式，IPv4透明代理规则继续生效。"
}

load_iptables() {
	# doge.14: 分流架构唯一路径，直接走 split 实现
	load_iptables_split
	return $?
}

# ============================================================================
# FORK doge.12 alpha: load_iptables_split / load_tproxy_split / flush_ipset_split
# 详见 doc/design/split-routing-architecture.md §5 / §6.3
# ----------------------------------------------------------------------------
# 极简化路径：
#   - 不再为 GLO/GFW/CHN/GAM/HOM 等模式建独立 chain
#   - 只创建 SHADOWSOCKS / SHADOWSOCKS_DNS_${VLAN} / SHADOWSOCKS_USER
#   - PREROUTING 按 acl MAC 分流到 per-Mode TPROXY 端口
#   - SHADOWSOCKS_DNS_${VLAN} per-MAC DNAT 到对应 mode 的 DNS 端口 (65353/65354)
# ============================================================================

load_tproxy_split() {
	# 仍要加载内核模块
	MODULES="xt_TPROXY xt_socket xt_comment"
	for MODULE in ${MODULES}
	do
		lsmod | grep ${MODULE} &>/dev/null
		if [ "$?" != "0" ]; then
			echo_date "加载${MODULE}模块..."
			modprobe ${MODULE}.ko
		else
			echo_date "${MODULE}模块已加载..."
		fi
	done
}

# 极简 ignlist_minimal ipset：RFC1918 + 链路本地 + 多播段
# 用于 PREROUTING 提前 RETURN（保险机制）
creat_ipset_split() {
	echo_date "创建极简 ignlist_minimal ipset (split 路径专用)"
	{
		echo "create ignlist_minimal nethash -exist"
		echo "flush ignlist_minimal"
		echo "create ignlist_minimal6 nethash family inet6 -exist"
		echo "flush ignlist_minimal6"
		# RFC1918 / loopback / link-local / multicast / reserved
		# 沿用 ssconfig.sh:3249 ip_lan_reserve 数据
		for ip in 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 \
		          172.16.0.0/12 192.168.0.0/16 192.18.0.0/15 224.0.0.0/4 240.0.0.0/4
		do
			echo "add ignlist_minimal ${ip}"
		done
		echo "add ignlist_minimal6 ::1/128"
		echo "add ignlist_minimal6 fe80::/10"
		echo "add ignlist_minimal6 ff00::/8"
		echo "COMMIT"
	} | ipset -R
}

# 按 mode 索引计算 TPROXY 端口 (SS_SPLIT_PORT_BASE + index)
# doge.13 beta D8 兑现：解除 alpha 的 `is_default || builtin` gate。
# alpha 期只给"默认 Mode + 内置 Mode"分配端口，自定义/未引用 Mode 拿不到端口
# → ACL 切到这些 Mode 后 iptables 找不到 TPROXY 端口，流量丢失。
# 现在按 mode 顺序枚举无差别分配，idx 每命中一次 +1。
# 同步 generate_xray_json_split::active_indices 收集逻辑也去掉同样过滤。
__split_mode_port_by_id() {
	# 索引按 1-based（合同 §1.5）
	local target_mid="$1"
	local mode_count=$(dbus get ss_split_mode_count 2>/dev/null)
	[ -z "${mode_count}" ] && mode_count=0
	local m=1
	local idx=0
	while [ "${m}" -le "${mode_count}" ]; do
		local mid=$(dbus get ss_split_mode_${m}_id 2>/dev/null)
		if [ "${mid}" = "${target_mid}" ]; then
			echo $((SS_SPLIT_PORT_BASE + idx))
			return 0
		fi
		idx=$((idx + 1))
		m=$((m + 1))
	done
	# 没找到 → 兜底默认 mode 的端口
	# alpha.17 W2 修：兜底前打 warn 日志（>&2 走 stderr，避免污染 $(...) 捕获的 stdout）。
	echo_date "⚠️ split: __split_mode_port_by_id 找不到 mode_id=${target_mid}，兜底返回 ${SS_SPLIT_PORT_BASE}" >&2
	echo "${SS_SPLIT_PORT_BASE}"
	return 1
}

# 根据 mode_id 返回 DNS 端口（split→65353 / global→65354）
__split_mode_dns_port_by_id() {
	# 索引按 1-based（合同 §1.5）
	local target_mid="$1"
	local mode_count=$(dbus get ss_split_mode_count 2>/dev/null)
	[ -z "${mode_count}" ] && mode_count=0
	local m=1
	while [ "${m}" -le "${mode_count}" ]; do
		local mid=$(dbus get ss_split_mode_${m}_id 2>/dev/null)
		if [ "${mid}" = "${target_mid}" ]; then
			local dm=$(dbus get ss_split_mode_${m}_dns_mode 2>/dev/null)
			if [ "${dm}" = "global" ]; then
				echo "${SS_SPLIT_DNS_GLOBAL_PORT}"
			else
				echo "${SS_SPLIT_DNS_SPLIT_PORT}"
			fi
			return 0
		fi
		m=$((m + 1))
	done
	# 兜底
	# alpha.17 W2 修：兜底前打 warn 日志（>&2 走 stderr，避免污染 $(...) 捕获的 stdout）。
	echo_date "⚠️ split: __split_mode_dns_port_by_id 找不到 mode_id=${target_mid}，兜底返回 ${SS_SPLIT_DNS_SPLIT_PORT}" >&2
	echo "${SS_SPLIT_DNS_SPLIT_PORT}"
	return 1
}

# alpha.16: 根据 mode_id 返回 block_quic（0/1），未设置默认 0
# Mode 管理 UI 里"屏蔽 QUIC"复选框 → ss_split_mode_<m>_block_quic dbus key
__split_mode_block_quic_by_id() {
	local target_mid="$1"
	local mode_count=$(dbus get ss_split_mode_count 2>/dev/null)
	[ -z "${mode_count}" ] && mode_count=0
	local m=1
	while [ "${m}" -le "${mode_count}" ]; do
		local mid=$(dbus get ss_split_mode_${m}_id 2>/dev/null)
		if [ "${mid}" = "${target_mid}" ]; then
			local v=$(dbus get ss_split_mode_${m}_block_quic 2>/dev/null)
			[ -z "${v}" ] && v=0
			echo "${v}"
			return 0
		fi
		m=$((m + 1))
	done
	# alpha.17 W2 修：兜底前打 warn 日志（>&2 走 stderr，避免污染 $(...) 捕获的 stdout）。
	echo_date "⚠️ split: __split_mode_block_quic_by_id 找不到 mode_id=${target_mid}，兜底返回 0" >&2
	echo 0
	return 1
}

# alpha.16: 根据 mode_id 返回 udp_proxy（0/1），未设置默认 1（启用 UDP 代理）
# Mode 管理 UI 里"UDP 代理"复选框 → ss_split_mode_<m>_udp_proxy dbus key
__split_mode_udp_proxy_by_id() {
	local target_mid="$1"
	local mode_count=$(dbus get ss_split_mode_count 2>/dev/null)
	[ -z "${mode_count}" ] && mode_count=0
	local m=1
	while [ "${m}" -le "${mode_count}" ]; do
		local mid=$(dbus get ss_split_mode_${m}_id 2>/dev/null)
		if [ "${mid}" = "${target_mid}" ]; then
			local v=$(dbus get ss_split_mode_${m}_udp_proxy 2>/dev/null)
			[ -z "${v}" ] && v=1
			echo "${v}"
			return 0
		fi
		m=$((m + 1))
	done
	# alpha.17 W2 修：兜底前打 warn 日志（>&2 走 stderr，避免污染 $(...) 捕获的 stdout）。
	echo_date "⚠️ split: __split_mode_udp_proxy_by_id 找不到 mode_id=${target_mid}，兜底返回 1" >&2
	echo 1
	return 1
}

# 主函数：装配 split 路径下的 iptables
load_iptables_split() {
	echo_date "------------ 写入 iptables 规则 (split 极简化路径) ------------"
	# 等待 nat 表准备好
	local nat_ready=$(iptables -t nat -L PREROUTING -v -n --line-numbers | grep -v PREROUTING | grep -v destination)
	local i=300
	until [ -n "${nat_ready}" ]; do
		i=$((i - 1))
		if [ "${i}" -lt 1 ]; then
			echo_date "错误：不能正确加载 nat 规则!"
			close_in_five
		fi
		usleep 100000
		nat_ready=$(iptables -t nat -L PREROUTING -v -n --line-numbers | grep -v PREROUTING | grep -v destination)
	done

	# 加载 TPROXY 模块
	load_tproxy_split
	# 建立极简 ignlist
	creat_ipset_split

	# 默认 Mode + 端口
	local default_mid=$(dbus get ss_split_default_mode_id 2>/dev/null)
	[ -z "${default_mid}" ] && default_mid=2
	local default_port=$(__split_mode_port_by_id "${default_mid}")
	local default_dns_port=$(__split_mode_dns_port_by_id "${default_mid}")

	# 建立 ip rule / ip route（TPROXY 必须）
	if [ -z "$(ip rule show table 310 2>/dev/null)" ]; then
		ip rule add fwmark 0x07 table 310
	fi
	if [ -z "$(ip route show table 310 2>/dev/null)" ]; then
		ip route add local 0.0.0.0/0 dev lo table 310
	fi

	# 主 SHADOWSOCKS chain (mangle, TPROXY 路径)
	ensure_chain mangle SHADOWSOCKS
	# TPROXY 必备的 socket-match 豁免：已被本地 xray socket 接管的连接的后续包
	# 必须打 fwmark 走 table 310 → lo 走完本地协议栈，不能再被 mangle PREROUTING
	# 重新 TPROXY 重定向（否则 TCP 三次握手的 SYN-ACK 又被抓回 TPROXY，新 socket
	# 找不到对应连接 → 握手永远不完成）。
	# 老 fancyss 路径 TCP 走 NAT REDIRECT 不需要这条，所以历史代码里没有；
	# split 路径让 xray 自己 TPROXY listen TCP+UDP，缺这条 LAN TCP/UDP 全废。
	ensure_chain mangle SHADOWSOCKS_DIVERT
	append_if_not_exists mangle -A SHADOWSOCKS_DIVERT -j MARK --set-xmark 0x07/0x07
	append_if_not_exists mangle -A SHADOWSOCKS_DIVERT -j ACCEPT
	# doge.13 beta.4 P0 FIX：DNS 流量在 mangle SHADOWSOCKS 入口直接 RETURN，
	# 避免 LAN DNS 同时被 TPROXY 和 nat DNS 劫持 DNAT 处理。
	# 根因：mangle PREROUTING (NF_PRI=-150) 先于 nat PREROUTING (NF_PRI=-100) 跑，
	# LAN UDP dport=53 进 mangle SHADOWSOCKS 时 dst 仍是原 DNS server (8.8.8.8:53
	# 等外网 IP)，命中下面的 TPROXY rule → 送进 xray 13334；接着 nat PREROUTING
	# DNS 劫持把 dst 改写成 127.0.0.1:65353，xray 拿到 back addr=127.0.0.1:65353
	# 后调 FakeUDP() 在该 addr 上 IP_TRANSPARENT bind UDP socket → 跟 chinadns
	# split 抢 65353 端口；packet 走 SO_REUSEPORT round-robin 部分被 xray 截走但
	# xray 不读 (recv-Q 涨)，部分 LAN DNS 查询丢失 → 全网 DNS 解析 5s timeout。
	# 实地证据：beta.3 上 LAN 50 query 后 xray 在 65353 占 ~50 个 socket。
	# 修法：DNS 劫持开启时 (默认开)，dport 53 流量在 mangle 入口就 RETURN，不进
	# TPROXY；nat PREROUTING 的 DNS 劫持 DNAT 再把它转给本机 chinadns。
	# 注意：必须 ss_basic_dns_hijack=1 才插这条；劫持关闭时 DNS 应当跟普通流量一样
	# 走 TPROXY 代理路径 (否则 GFW 屏蔽的 DNS server 直连失败)。
	if [ "${ss_basic_dns_hijack}" = "1" ]; then
		append_if_not_exists mangle -A SHADOWSOCKS -p udp --dport 53 -j RETURN
		append_if_not_exists mangle -A SHADOWSOCKS -p tcp --dport 53 -j RETURN
	fi
	append_if_not_exists mangle -A SHADOWSOCKS -p tcp -m socket -j SHADOWSOCKS_DIVERT
	append_if_not_exists mangle -A SHADOWSOCKS -p udp -m socket -j SHADOWSOCKS_DIVERT
	# 提前 RETURN：保留 IP 段
	append_if_not_exists mangle -A SHADOWSOCKS -m set --match-set ignlist_minimal dst -j RETURN
	append_if_not_exists mangle -A SHADOWSOCKS -p udp --dport 123 -j RETURN  # NTP 例外，避免时间同步被代理

	# per-User TPROXY 分流
	local VLAN_INDEXS=$(ifconfig | grep -E "^br" | awk '{print $1}' | sed 's/^br//g')
	local default_iface="br0"

	# 遍历 acl 行：get_acl_rule_indexes 扫 ss_acl_mode_<i> 发现真实设备行。
	# FORK doge.14-beta.6 修：旧版枚举 ss_acl_num / ss_acl_enable_<i> 是从未被前端写入的
	# 死 key（全仓库只读不写）→ acl_count 恒空 → 整个 per-user 循环空跑，所有访问控制
	# 设备落到默认 Mode（访问控制功能形同虚设）。改用与旧 ACL 路径一致的
	# get_acl_rule_indexes + get_acl_source_rule4：单 IP 设备解析成 -m mac --mac-source，
	# CIDR / 解析不到 MAC 的设备回退成 -s <ip>。
	local acl_nu=$(get_acl_rule_indexes)
	local _acl_total=0
	local _acl_active=0
	local a=""
	for a in ${acl_nu}; do
		_acl_total=$((_acl_total + 1))
		local user_mode=$(dbus get ss_acl_split_mode_${a} 2>/dev/null)
		[ -z "${user_mode}" ] && user_mode=$(dbus get ss_acl_mode_${a} 2>/dev/null)
		[ -z "${user_mode}" ] && continue
		local source_rule=$(get_acl_source_rule4 "${a}")
		[ -z "${source_rule}" ] && continue
		_acl_active=$((_acl_active + 1))
		if [ "${user_mode}" = "0" ]; then
			# 不通过代理（直连）
			append_if_not_exists mangle -A SHADOWSOCKS ${source_rule} -j RETURN
		else
			local user_port=$(__split_mode_port_by_id "${user_mode}")
			local user_block_quic=$(__split_mode_block_quic_by_id "${user_mode}")
			local user_udp_proxy=$(__split_mode_udp_proxy_by_id "${user_mode}")
			# block_quic=1 时 UDP/443 不进代理直接 DROP（HTTP/3 回退 TCP）。
			# 必须放在该设备 TPROXY 规则之前——iptables 顺序敏感，先 DROP 后 TPROXY。
			# -i ${default_iface} 限定仅 DROP LAN 入站方向 QUIC，防 LAN 内媒体服务器被误伤。
			if [ "${user_block_quic}" = "1" ]; then
				append_if_not_exists mangle -A SHADOWSOCKS -i "${default_iface}" -p udp --dport 443 ${source_rule} -j DROP
			fi
			# TCP 走 TPROXY (mangle)
			append_if_not_exists mangle -A SHADOWSOCKS -p tcp ${source_rule} -j TPROXY --tproxy-mark 0x07/0x07 --on-port "${user_port}"
			# UDP TPROXY 仅在 udp_proxy=1 时加；否则该设备 UDP 走原生路由（直连）。
			if [ "${user_udp_proxy}" = "1" ]; then
				append_if_not_exists mangle -A SHADOWSOCKS -p udp ${source_rule} -j TPROXY --tproxy-mark 0x07/0x07 --on-port "${user_port}"
			fi
		fi
	done
	# per-user TPROXY 装配后报告激活 ACL 行数,便于诊断"为什么某个设备没走 per-Mode 端口"
	echo_date "    已激活 ACL 行: ${_acl_active}/${_acl_total} 个设备绑定到 per-Mode 端口"

	# 默认（未在 acl 表中列出的设备）走默认 Mode
	local default_block_quic=$(__split_mode_block_quic_by_id "${default_mid}")
	local default_udp_proxy=$(__split_mode_udp_proxy_by_id "${default_mid}")
	# alpha.16: 默认 Mode 的 block_quic / udp_proxy 同样消费（fallback 设备走这条）
	# alpha.18 W3: 加 -i ${default_iface} 限定仅 DROP LAN 入站方向 QUIC（同 per-user 注释）
	if [ "${default_block_quic}" = "1" ]; then
		append_if_not_exists mangle -A SHADOWSOCKS -i "${default_iface}" -p udp --dport 443 -j DROP
	fi
	append_if_not_exists mangle -A SHADOWSOCKS -p tcp -j TPROXY --tproxy-mark 0x07/0x07 --on-port "${default_port}"
	if [ "${default_udp_proxy}" = "1" ]; then
		append_if_not_exists mangle -A SHADOWSOCKS -p udp -j TPROXY --tproxy-mark 0x07/0x07 --on-port "${default_port}"
	fi

	# 挂到 PREROUTING (mangle)
	append_if_not_exists mangle -A PREROUTING -i "${default_iface}" -j SHADOWSOCKS

	# DNS 劫持：per-MAC DNAT 到对应 mode 的 chinadns 实例端口
	if [ "${ss_basic_dns_hijack}" = "1" ]; then
		# DNAT 到 127.0.0.1 必须开 route_localnet，否则内核当 martian 丢弃 LAN 进来的包。
		# 老路径 DNAT 到 br 接口 IP（不是环回）所以不需要这条；split 直接 DNAT 到 127.0.0.1。
		echo 1 >/proc/sys/net/ipv4/conf/all/route_localnet 2>/dev/null
		for VLAN_INDEX in $VLAN_INDEXS
		do
			echo 1 >/proc/sys/net/ipv4/conf/br${VLAN_INDEX}/route_localnet 2>/dev/null
			ensure_chain nat SHADOWSOCKS_DNS_${VLAN_INDEX}
		done

		# br0：per-device DNS DNAT（与 TPROXY 循环同口径：复用 acl_nu + get_acl_source_rule4）
		for a in ${acl_nu}; do
			local user_mode=$(dbus get ss_acl_split_mode_${a} 2>/dev/null)
			[ -z "${user_mode}" ] && user_mode=$(dbus get ss_acl_mode_${a} 2>/dev/null)
			[ -z "${user_mode}" ] && continue
			[ "${user_mode}" = "0" ] && continue
			local source_rule=$(get_acl_source_rule4 "${a}")
			[ -z "${source_rule}" ] && continue
			local dns_port=$(__split_mode_dns_port_by_id "${user_mode}")
			append_if_not_exists nat -A SHADOWSOCKS_DNS_0 -i br0 -p udp --dport 53 ${source_rule} -j DNAT --to-destination 127.0.0.1:${dns_port}
			append_if_not_exists nat -A SHADOWSOCKS_DNS_0 -i br0 -p tcp --dport 53 ${source_rule} -j DNAT --to-destination 127.0.0.1:${dns_port}
		done
		# br0 fallback
		append_if_not_exists nat -A SHADOWSOCKS_DNS_0 -i br0 -p udp --dport 53 -j DNAT --to-destination 127.0.0.1:${default_dns_port}
		append_if_not_exists nat -A SHADOWSOCKS_DNS_0 -i br0 -p tcp --dport 53 -j DNAT --to-destination 127.0.0.1:${default_dns_port}

		# 其他 VLAN（br1/br2/...）：只 fallback 到默认 Mode 的 DNS 端口
		for VLAN_INDEX in $VLAN_INDEXS
		do
			if [ "${VLAN_INDEX}" != "0" ]; then
				append_if_not_exists nat -A SHADOWSOCKS_DNS_${VLAN_INDEX} -i "br${VLAN_INDEX}" -p udp --dport 53 -j DNAT --to-destination 127.0.0.1:${default_dns_port}
				append_if_not_exists nat -A SHADOWSOCKS_DNS_${VLAN_INDEX} -i "br${VLAN_INDEX}" -p tcp --dport 53 -j DNAT --to-destination 127.0.0.1:${default_dns_port}
			fi
		done

		# 挂到 PREROUTING (nat)
		for VLAN_INDEX in $VLAN_INDEXS
		do
			append_if_not_exists nat -A PREROUTING -i "br${VLAN_INDEX}" -j SHADOWSOCKS_DNS_${VLAN_INDEX}
		done
	fi

	echo_date "✅ split iptables 装配完成 (default_mode=${default_mid} default_port=${default_port} default_dns_port=${default_dns_port})"
	echo_date "---------------------------------------------------------------"
	return 0
}

ensure_chain() {
	ensure_chain_with_cmd iptables "$@"
}

ensure_chain6() {
	ensure_chain_with_cmd ip6tables "$@"
}

ensure_chain_with_cmd() {
	local cmd="$1"
	local table="$2"
	local chain="$3"
	if ! ${cmd} -t "$table" -L "$chain" >/dev/null 2>&1; then
		${cmd} -t "$table" -N "$chain" >/dev/null 2>&1 || return 1
	fi
}

append_if_not_exists() {
	append_if_not_exists_with_cmd iptables "$@"
}

append_if_not_exists6() {
	append_if_not_exists_with_cmd ip6tables "$@"
}

append_if_not_exists_with_cmd() {
	local cmd="$1"
	local table="$2"
	shift 2
	set -- "$@"
	if [ "$1" = "-A" ]; then
		local chain="$2"
		shift 2
		if ! ${cmd} -t "$table" -C "$chain" "$@" >/dev/null 2>&1; then
			${cmd} -t "$table" -A "$chain" "$@" >/dev/null 2>&1 || return 1
		fi
	else
		echo "append_if_not_exists 需要以 -A 开头的参数" >&2
		return 1
	fi
}

insert_if_not_exists() {
	table="$1"
	shift
	# 剩余参数为完整规则，例如：-A CHAIN ... -j ...
	# 先构造对应的 -C 检查：把 -A 改为 -C
	# 注意：iptables -C 格式为：iptables -t table -C chain rule-spec
	# 因此需要拆出链名和去掉 -A
	set -- "$@"
	if [ "$1" = "-I" ]; then
		chain="$2"
		# 去掉前两个参数 "-A chain"
		shift 2
		if ! iptables -t "$table" -C "$chain" "$@" >/dev/null 2>&1; then
		  iptables -t "$table" -I "$chain" "$@"
		fi
	else
		echo "append_if_not_exists 需要以 -I 开头的参数" >&2
		return 1
	fi
}

get_shunt_ingress_mode() {
	local mode="${ss_basic_shunt_ingress_mode:-2}"
	case "${mode}" in
	5)
		echo "5"
		;;
	*)
		echo "2"
		;;
	esac
}

init_shunt_chain_v4() {
	local ingress_mode="$(get_shunt_ingress_mode)"

	ensure_chain nat SHADOWSOCKS_SHU
	ensure_chain mangle SHADOWSOCKS_SHU
	ensure_chain filter SHADOWSOCKS_SHU
	if [ "${ingress_mode}" = "5" ]; then
		append_if_not_exists nat -A SHADOWSOCKS_SHU -p tcp -m set --match-set white_list dst -j RETURN
		append_if_not_exists nat -A SHADOWSOCKS_SHU -p tcp -j REDIRECT --to-ports 3333
		append_if_not_exists mangle -A SHADOWSOCKS_SHU -p udp -m set --match-set white_list dst -j RETURN
		append_if_not_exists mangle -A SHADOWSOCKS_SHU -p udp -j TPROXY --on-port 3333 --tproxy-mark 0x07
		append_if_not_exists filter -A SHADOWSOCKS_SHU -p udp -m set --match-set white_list dst -j RETURN
		append_if_not_exists filter -A SHADOWSOCKS_SHU -p udp -j REJECT --reject-with icmp-port-unreachable
	else
		append_if_not_exists nat -A SHADOWSOCKS_SHU -p tcp -m set --match-set black_list dst -j REDIRECT --to-ports 3333
		append_if_not_exists nat -A SHADOWSOCKS_SHU -p tcp -m set --match-set chnlist dst -j RETURN
		append_if_not_exists nat -A SHADOWSOCKS_SHU -p tcp -m set --match-set chnroute dst -j RETURN
		append_if_not_exists nat -A SHADOWSOCKS_SHU -p tcp -m set --match-set white_list dst -j RETURN
		append_if_not_exists nat -A SHADOWSOCKS_SHU -p tcp -j REDIRECT --to-ports 3333
		append_if_not_exists mangle -A SHADOWSOCKS_SHU -p udp -m set --match-set black_list dst -j TPROXY --on-port 3333 --tproxy-mark 0x07
		append_if_not_exists mangle -A SHADOWSOCKS_SHU -p udp -m set --match-set chnlist dst -j RETURN
		append_if_not_exists mangle -A SHADOWSOCKS_SHU -p udp -m set --match-set chnroute dst -j RETURN
		append_if_not_exists mangle -A SHADOWSOCKS_SHU -p udp -m set --match-set white_list dst -j RETURN
		append_if_not_exists mangle -A SHADOWSOCKS_SHU -p udp -j TPROXY --on-port 3333 --tproxy-mark 0x07
		append_if_not_exists filter -A SHADOWSOCKS_SHU -p udp -m set --match-set black_list dst -j REJECT --reject-with icmp-port-unreachable
		append_if_not_exists filter -A SHADOWSOCKS_SHU -p udp -m set --match-set chnlist dst -j RETURN
		append_if_not_exists filter -A SHADOWSOCKS_SHU -p udp -m set --match-set chnroute dst -j RETURN
		append_if_not_exists filter -A SHADOWSOCKS_SHU -p udp -m set --match-set white_list dst -j RETURN
		append_if_not_exists filter -A SHADOWSOCKS_SHU -p udp -j REJECT --reject-with icmp-port-unreachable
	fi
}

init_shunt_chain_v6() {
	local ingress_mode="$(get_shunt_ingress_mode)"
	local tproxy_port6="$(get_tproxy_port6)"

	ensure_chain6 nat SHADOWSOCKS6_SHU || return 1
	ensure_chain6 mangle SHADOWSOCKS6_SHU || return 1
	ensure_chain6 filter SHADOWSOCKS6_SHU || return 1
	if [ "${ingress_mode}" = "5" ]; then
		append_if_not_exists6 nat -A SHADOWSOCKS6_SHU -p tcp -m set --match-set white_list6 dst -j RETURN || return 1
		append_if_not_exists6 nat -A SHADOWSOCKS6_SHU -p tcp -j REDIRECT --to-ports ${tproxy_port6} || return 1
		append_if_not_exists6 mangle -A SHADOWSOCKS6_SHU -p udp -m set --match-set white_list6 dst -j RETURN || return 1
		append_if_not_exists6 mangle -A SHADOWSOCKS6_SHU -p udp -j TPROXY --on-port ${tproxy_port6} --tproxy-mark 0x07 || return 1
		append_if_not_exists6 filter -A SHADOWSOCKS6_SHU -p udp -m set --match-set white_list6 dst -j RETURN || return 1
		append_if_not_exists6 filter -A SHADOWSOCKS6_SHU -p udp -j REJECT --reject-with icmp6-port-unreachable || return 1
	else
		append_if_not_exists6 nat -A SHADOWSOCKS6_SHU -p tcp -m set --match-set black_list6 dst -j REDIRECT --to-ports ${tproxy_port6} || return 1
		append_if_not_exists6 nat -A SHADOWSOCKS6_SHU -p tcp -m set --match-set chnlist6 dst -j RETURN || return 1
		append_if_not_exists6 nat -A SHADOWSOCKS6_SHU -p tcp -m set --match-set chnroute6 dst -j RETURN || return 1
		append_if_not_exists6 nat -A SHADOWSOCKS6_SHU -p tcp -m set --match-set white_list6 dst -j RETURN || return 1
		append_if_not_exists6 nat -A SHADOWSOCKS6_SHU -p tcp -j REDIRECT --to-ports ${tproxy_port6} || return 1
		append_if_not_exists6 mangle -A SHADOWSOCKS6_SHU -p udp -m set --match-set black_list6 dst -j TPROXY --on-port ${tproxy_port6} --tproxy-mark 0x07 || return 1
		append_if_not_exists6 mangle -A SHADOWSOCKS6_SHU -p udp -m set --match-set chnlist6 dst -j RETURN || return 1
		append_if_not_exists6 mangle -A SHADOWSOCKS6_SHU -p udp -m set --match-set chnroute6 dst -j RETURN || return 1
		append_if_not_exists6 mangle -A SHADOWSOCKS6_SHU -p udp -m set --match-set white_list6 dst -j RETURN || return 1
		append_if_not_exists6 mangle -A SHADOWSOCKS6_SHU -p udp -j TPROXY --on-port ${tproxy_port6} --tproxy-mark 0x07 || return 1
		append_if_not_exists6 filter -A SHADOWSOCKS6_SHU -p udp -m set --match-set black_list6 dst -j REJECT --reject-with icmp6-port-unreachable || return 1
		append_if_not_exists6 filter -A SHADOWSOCKS6_SHU -p udp -m set --match-set chnlist6 dst -j RETURN || return 1
		append_if_not_exists6 filter -A SHADOWSOCKS6_SHU -p udp -m set --match-set chnroute6 dst -j RETURN || return 1
		append_if_not_exists6 filter -A SHADOWSOCKS6_SHU -p udp -m set --match-set white_list6 dst -j RETURN || return 1
		append_if_not_exists6 filter -A SHADOWSOCKS6_SHU -p udp -j REJECT --reject-with icmp6-port-unreachable || return 1
	fi
}

_start_iptables() {
	#----------------------BASIC RULES---------------------
	echo_date "写入iptables规则到nat表中..."
	local VLAN_INDEXS=$(ifconfig | grep -E "^br" | awk '{print $1}' | sed 's/^br//g')

	# 创建SHADOWSOCKS nat rule
	ensure_chain nat SHADOWSOCKS 

	if [ "$ss_basic_dns_hijack" == "1" ]; then
		for VLAN_INDEX in $VLAN_INDEXS
		do
			# iptables -t nat -N SHADOWSOCKS_DNS_${VLAN_INDEX}
			ensure_chain nat SHADOWSOCKS_DNS_${VLAN_INDEX} 
		done
	fi
	
	# 扩展
	ensure_chain nat SHADOWSOCKS_EXT 
	
	# IP/cidr/白域名 白名单控制（不go proxy）
	append_if_not_exists nat -A SHADOWSOCKS -p tcp -m set --match-set ignlist dst -j RETURN
	append_if_not_exists nat -A SHADOWSOCKS_EXT -p tcp -m set --match-set ignlist dst -j RETURN
	
	#-----------------------FOR GLOABLE---------------------
	# 创建全局模式 nat rule
	ensure_chain nat SHADOWSOCKS_GLO 
	# {white_list} 直连
	append_if_not_exists nat -A SHADOWSOCKS_GLO -p tcp -m set --match-set white_list dst -j RETURN
	# {剩余流量} 代理
	append_if_not_exists nat -A SHADOWSOCKS_GLO -p tcp -j REDIRECT --to-ports 3333
	
	#-----------------------FOR GFWLIST---------------------
	# 创建gfwlist模式 nat rule
	ensure_chain nat SHADOWSOCKS_GFW 
	# {white_list} 直连
	append_if_not_exists nat -A SHADOWSOCKS_GFW -p tcp -m set --match-set white_list dst -j RETURN	
	# {black_list} 代理
	append_if_not_exists nat -A SHADOWSOCKS_GFW -p tcp -m set --match-set black_list dst -j REDIRECT --to-ports 3333
	# {gfwlist} 代理
	append_if_not_exists nat -A SHADOWSOCKS_GFW -p tcp -m set --match-set gfwlist dst -j REDIRECT --to-ports 3333
	# {rotlist} 代理
	append_if_not_exists nat -A SHADOWSOCKS_GFW -p tcp -m set --match-set router dst -j REDIRECT --to-ports 3333
	
	#-----------------------FOR CHNMODE---------------------
	# 创建大陆白名单模式nat rule
	ensure_chain nat SHADOWSOCKS_CHN 
	# {black_list} 代理
	append_if_not_exists nat -A SHADOWSOCKS_CHN -p tcp -m set --match-set black_list dst -j REDIRECT --to-ports 3333
	# {chnlist} 直连
	append_if_not_exists nat -A SHADOWSOCKS_CHN -p tcp -m set --match-set chnlist dst -j RETURN
	# {chnroute} 直连
	append_if_not_exists nat -A SHADOWSOCKS_CHN -p tcp -m set --match-set chnroute dst -j RETURN
	# {white_list} 直连
	append_if_not_exists nat -A SHADOWSOCKS_CHN -p tcp -m set --match-set white_list dst -j RETURN
	# {剩余流量} 代理
	append_if_not_exists nat -A SHADOWSOCKS_CHN -p tcp -j REDIRECT --to-ports 3333
	
	#-----------------------FOR GAMEMODE---------------------
	# 创建游戏模式nat rule
	ensure_chain nat SHADOWSOCKS_GAM 
	# {black_list} 代理
	append_if_not_exists nat -A SHADOWSOCKS_GAM -p tcp -m set --match-set black_list dst -j REDIRECT --to-ports 3333
	# {chnlist} 直连
	append_if_not_exists nat -A SHADOWSOCKS_GAM -p tcp -m set --match-set chnlist dst -j RETURN
	# {chnroute} 直连
	append_if_not_exists nat -A SHADOWSOCKS_GAM -p tcp -m set --match-set chnroute dst -j RETURN
	# {white_list} 直连
	append_if_not_exists nat -A SHADOWSOCKS_GAM -p tcp -m set --match-set white_list dst -j RETURN
	# {剩余流量} 代理
	append_if_not_exists nat -A SHADOWSOCKS_GAM -p tcp -j REDIRECT --to-ports 3333
	
	#-----------------------FOR HOMEMODE---------------------
	# 创建回国模式nat rule
	ensure_chain nat SHADOWSOCKS_HOM 
	# {black_list} 代理
	append_if_not_exists nat -A SHADOWSOCKS_HOM -p tcp -m set --match-set black_list dst -j REDIRECT --to-ports 3333
	# {gfwlist} 直连
	append_if_not_exists nat -A SHADOWSOCKS_HOM -p tcp -m set --match-set gfwlist dst -j RETURN
	# {white_list} 直连
	append_if_not_exists nat -A SHADOWSOCKS_HOM -p tcp -m set --match-set white_list dst -j RETURN

	#-----------------------FOR TPROXY---------------------
	load_tproxy
	if [ -z "$(ip rule show table 310 2>/dev/null)" ];then
		ip rule add fwmark 0x07 table 310
	fi
	
	if [ -z "$(ip route show table 310 2>/dev/null)" ];then
		ip route add local 0.0.0.0/0 dev lo table 310
	fi

	# 创建游戏模式udp rule
	ensure_chain mangle SHADOWSOCKS

	# doge.13 beta.4 P0 FIX (老路径同步)：DNS 流量在 mangle SHADOWSOCKS 入口直接 RETURN。
	# 根因同 load_iptables_split 的 D16 修订 (详见 doc/implementation/split-routing-implementation.md)：
	# mangle PREROUTING (NF_PRI=-150) 先于 nat PREROUTING (-100) 跑，LAN UDP dport=53 进
	# SHADOWSOCKS_GFW / SHADOWSOCKS_CHN 等 sub-chain 时 dst 仍是原 DNS server (8.8.8.8:53
	# 等)，命中 TPROXY 3333 送 xray；接着 nat PREROUTING DNS 劫持 DNAT 把 dst 改写成
	# 127.0.0.1:65353，xray 拿到 back addr 后 FakeUDP() IP_TRANSPARENT bind 65353 → 跟
	# 老路径单实例 chinadns-ng 抢端口，LAN DNS 包通过 SO_REUSEPORT round-robin 部分丢失。
	# DNS 劫持开启时（默认开），dport 53 流量在 mangle 入口就 RETURN，nat DNS 劫持
	# DNAT 仍正常把它转给本机 chinadns；劫持关闭时不插（让 DNS 走代理）。
	if [ "${ss_basic_dns_hijack}" = "1" ]; then
		append_if_not_exists mangle -A SHADOWSOCKS -p udp --dport 53 -j RETURN
		append_if_not_exists mangle -A SHADOWSOCKS -p tcp --dport 53 -j RETURN
	fi

	# IP/cidr/白域名 白名单控制（不go proxy）
	append_if_not_exists mangle -A SHADOWSOCKS -p udp -m set --match-set ignlist dst -j RETURN

	# 创建gfw模式udp rule
	ensure_chain mangle SHADOWSOCKS_GFW
	# {white_list} 直连
	append_if_not_exists mangle -A SHADOWSOCKS_GFW -p udp -m set --match-set white_list dst -j RETURN
	# {black_list} 代理
	append_if_not_exists mangle -A SHADOWSOCKS_GFW -p udp -m set --match-set black_list dst -j TPROXY --on-port 3333 --tproxy-mark 0x07
	# {gfwlist} 代理
	append_if_not_exists mangle -A SHADOWSOCKS_GFW -p udp -m set --match-set gfwlist dst -j TPROXY --on-port 3333 --tproxy-mark 0x07
	# {rotlist} 代理
	append_if_not_exists mangle -A SHADOWSOCKS_GFW -p udp -m set --match-set router dst -j TPROXY --on-port 3333 --tproxy-mark 0x07

	# 创建白名单模式udp rule
	ensure_chain mangle SHADOWSOCKS_CHN
	# {black_list} 代理
	append_if_not_exists mangle -A SHADOWSOCKS_CHN -p udp -m set --match-set black_list dst -j TPROXY --on-port 3333 --tproxy-mark 0x07
	# {chnlist} 直连
	append_if_not_exists mangle -A SHADOWSOCKS_CHN -p udp -m set --match-set chnlist dst -j RETURN
	# {chnroute} 直连
	append_if_not_exists mangle -A SHADOWSOCKS_CHN -p udp -m set --match-set chnroute dst -j RETURN
	# {white_list} 直连
	append_if_not_exists mangle -A SHADOWSOCKS_CHN -p udp -m set --match-set white_list dst -j RETURN
	# {剩余流量} 代理
	append_if_not_exists mangle -A SHADOWSOCKS_CHN -p udp -j TPROXY --on-port 3333 --tproxy-mark 0x07

	# 创建游戏模式udp rule
	ensure_chain mangle SHADOWSOCKS_GAM
	# {black_list} 代理
	append_if_not_exists mangle -A SHADOWSOCKS_GAM -p udp -m set --match-set black_list dst -j TPROXY --on-port 3333 --tproxy-mark 0x07
	# {chnlist} 直连
	append_if_not_exists mangle -A SHADOWSOCKS_GAM -p udp -m set --match-set chnlist dst -j RETURN
	# {chnroute} 直连
	append_if_not_exists mangle -A SHADOWSOCKS_GAM -p udp -m set --match-set chnroute dst -j RETURN
	# {white_list} 直连
	append_if_not_exists mangle -A SHADOWSOCKS_GAM -p udp -m set --match-set white_list dst -j RETURN
	# {剩余流量} 代理
	append_if_not_exists mangle -A SHADOWSOCKS_GAM -p udp -j TPROXY --on-port 3333 --tproxy-mark 0x07

	# 创建glo模式udp rule
	ensure_chain mangle SHADOWSOCKS_GLO
	# {white_list} 直连
	append_if_not_exists mangle -A SHADOWSOCKS_GLO -p udp -m set --match-set white_list dst -j RETURN
	# {剩余流量} 代理
	append_if_not_exists mangle -A SHADOWSOCKS_GLO -p udp -j TPROXY --on-port 3333 --tproxy-mark 0x07

	echo_date "创建xray分流模式专用链，入口策略：$( [ "$(get_shunt_ingress_mode)" = "5" ] && echo 全量引流 || echo 大陆白名单引流 )"
	init_shunt_chain_v4

	# 创建回国模式udp rule
	ensure_chain mangle SHADOWSOCKS_HOM
	# {black_list} 代理
	append_if_not_exists mangle -A SHADOWSOCKS_HOM -p udp -m set --match-set black_list dst -j TPROXY --on-port 3333 --tproxy-mark 0x07
	# {gfwlist} 直连
	append_if_not_exists mangle -A SHADOWSOCKS_HOM -p udp -m set --match-set gfwlist dst -j RETURN
	# {white_list} 直连
	append_if_not_exists mangle -A SHADOWSOCKS_HOM -p udp -m set --match-set white_list dst -j RETURN
	# {剩余流量} 代理
	append_if_not_exists mangle -A SHADOWSOCKS_HOM -p udp -j TPROXY --on-port 3333 --tproxy-mark 0x07
	
	#-----------------------FOR FILTER UDP443---------------------
	# 创建过滤 udp rule
	ensure_chain filter SHADOWSOCKS

	# {ignlist}不过滤udp 443
	append_if_not_exists filter -A SHADOWSOCKS -p udp -m set --match-set ignlist dst -j RETURN

	# 创建gfw模式udp filter rule
	ensure_chain filter SHADOWSOCKS_GFW
	# {white_list} 不过滤udp 443
	append_if_not_exists filter -A SHADOWSOCKS_GFW -p udp -m set --match-set white_list dst -j RETURN
	# {black_list} 过滤udp 443
	append_if_not_exists filter -A SHADOWSOCKS_GFW -p udp -m set --match-set black_list dst -j REJECT --reject-with icmp-port-unreachable
	# {gfwlist} 过滤udp 443
	append_if_not_exists filter -A SHADOWSOCKS_GFW -p udp -m set --match-set gfwlist dst -j REJECT --reject-with icmp-port-unreachable
	# {rotlist} 过滤udp 443
	append_if_not_exists filter -A SHADOWSOCKS_GFW -p udp -m set --match-set router dst -j REJECT --reject-with icmp-port-unreachable

	# 创建白名单模式udp filter rule
	ensure_chain filter SHADOWSOCKS_CHN
	# {black_list} 过滤udp 443
	append_if_not_exists filter -A SHADOWSOCKS_CHN -p udp -m set --match-set black_list dst -j REJECT --reject-with icmp-port-unreachable
	# {chnlist} 不过滤udp 443
	append_if_not_exists filter -A SHADOWSOCKS_CHN -p udp -m set --match-set chnlist dst -j RETURN
	# {chnroute} 不过滤udp 443
	append_if_not_exists filter -A SHADOWSOCKS_CHN -p udp -m set --match-set chnroute dst -j RETURN
	# {white_list} 不过滤udp 443
	append_if_not_exists filter -A SHADOWSOCKS_CHN -p udp -m set --match-set white_list dst -j RETURN
	# {剩余流量} 过滤udp 443
	append_if_not_exists filter -A SHADOWSOCKS_CHN -p udp -j REJECT --reject-with icmp-port-unreachable

	# 创建游戏模式udp rule
	ensure_chain filter SHADOWSOCKS_GAM 
	# 游戏模式默认不过滤，创建一个空的就行

	# 创建glo模式udp rule
	ensure_chain filter SHADOWSOCKS_GLO
	# {white_list} 不过滤udp 443
	append_if_not_exists filter -A SHADOWSOCKS_GLO -p udp -m set --match-set white_list dst -j RETURN
	# {剩余流量} 过滤udp 443
	append_if_not_exists filter -A SHADOWSOCKS_GLO -p udp -j REJECT --reject-with icmp-port-unreachable

	# 创建回国模式udp filter rule
	ensure_chain filter SHADOWSOCKS_HOM
	# {black_list} 过滤udp 443
	append_if_not_exists filter -A SHADOWSOCKS_HOM -p udp -m set --match-set black_list dst -j REJECT --reject-with icmp-port-unreachable
	# {gfwlist} 不过滤udp 443
	append_if_not_exists filter -A SHADOWSOCKS_HOM -p udp -m set --match-set gfwlist dst -j RETURN
	# {white_list} 不过滤udp 443
	append_if_not_exists filter -A SHADOWSOCKS_HOM -p udp -m set --match-set white_list dst -j RETURN
	# {剩余流量} 过滤udp 443
	append_if_not_exists filter -A SHADOWSOCKS_HOM -p udp -j REJECT --reject-with icmp-port-unreachable
	
	#-------------------------------------------------------
	# 局域网黑名单（不go proxy）/局域网黑名单（go proxy）
	lan_access_control $1

	# Block QUIC(UDP/443) to non-China destinations (HTTP/3) so clients fallback to TCP.
	apply_quic_block
	
	# DNS 劫持
	dns_hijack_control 4
	#-----------------------FOR ROUTER---------------------
	# router itself
	if [ "${ss_basic_mode}" != "6" ];then
		append_if_not_exists nat -A OUTPUT -p tcp -m set --match-set router dst -j REDIRECT --to-ports 3333

		# make sure these match go proxy inside router
		# append_if_not_exists mangle -A OUTPUT -p udp -m set --match-set router dst -j MARK --set-mark 0x07
		append_if_not_exists mangle -A OUTPUT -p udp -m set --match-set router dst -m udp --dport 53 -j MARK --set-mark 0x7/0xffffffff
	fi
	append_if_not_exists nat -A OUTPUT -p tcp -m mark --mark "$ip_prefix_hex" -j SHADOWSOCKS_EXT

	# 把最后剩余流量重定向到相应模式的nat表中对应的主模式的链
	local acl_default_mode_runtime="$(resolve_acl_default_mode "$(if [ -n "${acl_nu}" ];then echo 1; else echo 0; fi)")"
	local acl_default_ports_runtime="$(resolve_acl_ports "$(resolve_acl_default_ports_raw)" "${acl_default_mode_runtime}")"
	local acl_default_ports_match="${acl_default_ports_runtime}"
	[ "${acl_default_ports_match}" = "all" ] && acl_default_ports_match=""
	append_if_not_exists nat -A SHADOWSOCKS -p tcp $(factor ${acl_default_ports_match} "-m multiport --dport") -j $(get_action_chain ${acl_default_mode_runtime})
	
	append_if_not_exists nat -A SHADOWSOCKS_EXT -p tcp $(factor ${acl_default_ports_match} "-m multiport --dport") -j $(get_action_chain ${acl_default_mode_runtime})

	local default_udp_flag=$(get_acl_udp_flag "" "${acl_default_mode_runtime}")
	local default_quic_flag=$(get_acl_quic_flag "" "${acl_default_mode_runtime}" "${default_udp_flag}")
	apply_acl_udp_rule "${acl_default_label}" "" "${acl_default_ports_match}" "${acl_default_mode_runtime}" "${default_udp_flag}" "${default_quic_flag}"
	
	# 重定所有流量到 SHADOWSOCKS
	KP_NU=$(iptables -nvL PREROUTING -t nat | sed 1,2d | sed -n '/KOOLPROXY/=' | head -n1)
	[ -z "${KP_NU}" ] && KP_NU=0
	INSET_NU=$(expr "${KP_NU}" + 1)
	iptables -t nat -I PREROUTING "${INSET_NU}" -p tcp -j SHADOWSOCKS
	
	[ "${mangle}" != "0" ] && append_if_not_exists mangle -A PREROUTING -p udp -j SHADOWSOCKS

	# FOR FILTER
	insert_if_not_exists filter -I FORWARD 1 -p udp --dport 443 -j SHADOWSOCKS

	if [ "$ss_basic_dns_hijack" == "1" ]; then
		echo_date "开启DNS劫持功能功能，防止DNS污染..."
		#INSET_NU_DNS=$(expr "${INSET_NU}" + 1)
		local INSET_NU_DNS=$((${INSET_NU} + 1))
		#append_if_not_exists nat -I PREROUTING "$INSET_NU_DNS" -p udp ! -s ${lan_ipaddr} --dport 53 -j SHADOWSOCKS_DNS
		for VLAN_INDEX in ${VLAN_INDEXS}
		do
			iptables -t nat -I PREROUTING "${INSET_NU_DNS}" -i br${VLAN_INDEX} -p udp -m udp --dport 53 -j SHADOWSOCKS_DNS_${VLAN_INDEX}
			let INSET_NU_DNS+=1
		done
	else
		echo_date "DNS劫持功能未开启，建议开启！"
	fi

	# QOS开启的情况下
	QOSO=$(iptables -t mangle -S | grep -o QOSO | wc -l)
	RRULE=$(iptables -t mangle -S | grep "A QOSO" | head -n1 | grep RETURN)
	if [ "$QOSO" -gt "1" -a -z "$RRULE" ]; then
		iptables -t mangle -I QOSO0 -m mark --mark "$ip_prefix_hex" -j RETURN
	fi

	if ipv6_proxy_enabled; then
		if ! _start_ipv6_iptables; then
			fallback_ipv6_proxy_to_ipv4 || return 1
		fi
	fi
}

_start_ipv6_iptables() {
	echo_date "写入ip6tables规则到ipv6 nat/mangle/filter表中..."

	resolve_ipv6_default_acl

	local ipv6_ports="${IPV6_ACL_DEFAULT_PORTS}"
	if [ "${ipv6_ports}" == "all" ];then
		ipv6_ports=""
		echo_date "加载IPv6默认ACL规则：【${IPV6_ACL_DEFAULT_LABEL}】【全部端口】模式为：$(get_mode_name ${IPV6_ACL_DEFAULT_MODE})"
	else
		echo_date "加载IPv6默认ACL规则：【${IPV6_ACL_DEFAULT_LABEL}】【${ipv6_ports}】模式为：$(get_mode_name ${IPV6_ACL_DEFAULT_MODE})"
	fi
	if [ -n "${IPV6_ACL_SKIP_CIDR}" ];then
		echo_date "IPv6 ACL提示：以下CIDR规则继续仅用于IPv4：${IPV6_ACL_SKIP_CIDR}"
	fi
	if [ -n "${IPV6_ACL_SKIP_NOMAC}" ];then
		echo_date "IPv6 ACL提示：以下主机未获取到MAC，继续仅用于IPv4：${IPV6_ACL_SKIP_NOMAC}"
	fi
	if [ "${IPV6_ACL_HAS_CUSTOM}" == "1" -a "${IPV6_ACL_ACTIVE_COUNT}" == "0" ];then
		echo_date "IPv6 ACL提示：当前没有可直接用于IPv6的自定义主机规则，全部IPv6流量将按默认规则处理。"
	fi

	#-----------------------FOR NAT TCP---------------------
	ensure_chain6 nat SHADOWSOCKS6 || return 1
	append_if_not_exists6 nat -A SHADOWSOCKS6 -p tcp -m set --match-set ignlist6 dst -j RETURN || return 1
	if [ "$ss_basic_dns_hijack" == "1" ]; then
		for VLAN_INDEX in ${VLAN_INDEXS}
		do
			ensure_chain6 nat SHADOWSOCKS6_DNS_${VLAN_INDEX} || return 1
		done
	fi

	ensure_chain6 nat SHADOWSOCKS6_GLO || return 1
	append_if_not_exists6 nat -A SHADOWSOCKS6_GLO -p tcp -m set --match-set white_list6 dst -j RETURN || return 1
	append_if_not_exists6 nat -A SHADOWSOCKS6_GLO -p tcp -j REDIRECT --to-ports $(get_tproxy_port6) || return 1

	ensure_chain6 nat SHADOWSOCKS6_GFW || return 1
	append_if_not_exists6 nat -A SHADOWSOCKS6_GFW -p tcp -m set --match-set white_list6 dst -j RETURN || return 1
	append_if_not_exists6 nat -A SHADOWSOCKS6_GFW -p tcp -m set --match-set black_list6 dst -j REDIRECT --to-ports $(get_tproxy_port6) || return 1
	append_if_not_exists6 nat -A SHADOWSOCKS6_GFW -p tcp -m set --match-set gfwlist6 dst -j REDIRECT --to-ports $(get_tproxy_port6) || return 1
	append_if_not_exists6 nat -A SHADOWSOCKS6_GFW -p tcp -m set --match-set router6 dst -j REDIRECT --to-ports $(get_tproxy_port6) || return 1

	ensure_chain6 nat SHADOWSOCKS6_CHN || return 1
	append_if_not_exists6 nat -A SHADOWSOCKS6_CHN -p tcp -m set --match-set black_list6 dst -j REDIRECT --to-ports $(get_tproxy_port6) || return 1
	append_if_not_exists6 nat -A SHADOWSOCKS6_CHN -p tcp -m set --match-set chnlist6 dst -j RETURN || return 1
	append_if_not_exists6 nat -A SHADOWSOCKS6_CHN -p tcp -m set --match-set chnroute6 dst -j RETURN || return 1
	append_if_not_exists6 nat -A SHADOWSOCKS6_CHN -p tcp -m set --match-set white_list6 dst -j RETURN || return 1
	append_if_not_exists6 nat -A SHADOWSOCKS6_CHN -p tcp -j REDIRECT --to-ports $(get_tproxy_port6) || return 1

	ensure_chain6 nat SHADOWSOCKS6_GAM || return 1
	append_if_not_exists6 nat -A SHADOWSOCKS6_GAM -p tcp -m set --match-set black_list6 dst -j REDIRECT --to-ports $(get_tproxy_port6) || return 1
	append_if_not_exists6 nat -A SHADOWSOCKS6_GAM -p tcp -m set --match-set chnlist6 dst -j RETURN || return 1
	append_if_not_exists6 nat -A SHADOWSOCKS6_GAM -p tcp -m set --match-set chnroute6 dst -j RETURN || return 1
	append_if_not_exists6 nat -A SHADOWSOCKS6_GAM -p tcp -m set --match-set white_list6 dst -j RETURN || return 1
	append_if_not_exists6 nat -A SHADOWSOCKS6_GAM -p tcp -j REDIRECT --to-ports $(get_tproxy_port6) || return 1

	ensure_chain6 nat SHADOWSOCKS6_HOM || return 1
	append_if_not_exists6 nat -A SHADOWSOCKS6_HOM -p tcp -m set --match-set black_list6 dst -j REDIRECT --to-ports $(get_tproxy_port6) || return 1
	append_if_not_exists6 nat -A SHADOWSOCKS6_HOM -p tcp -m set --match-set gfwlist6 dst -j RETURN || return 1
	append_if_not_exists6 nat -A SHADOWSOCKS6_HOM -p tcp -m set --match-set white_list6 dst -j RETURN || return 1

	#-----------------------FOR TPROXY UDP---------------------
	load_tproxy
	if [ -z "$(ip -6 rule show table 310 2>/dev/null | grep "fwmark 0x7")" ];then
		ip -6 rule add fwmark 0x07 table 310 >/dev/null 2>&1 || return 1
	fi
	if [ -z "$(ip -6 route show table 310 2>/dev/null | grep "^local ::/0 dev lo")" ];then
		ip -6 route add local ::/0 dev lo table 310 >/dev/null 2>&1 || return 1
	fi

	ensure_chain6 mangle SHADOWSOCKS6 || return 1
	append_if_not_exists6 mangle -A SHADOWSOCKS6 -p udp -m set --match-set ignlist6 dst -j RETURN || return 1

	ensure_chain6 mangle SHADOWSOCKS6_GFW || return 1
	append_if_not_exists6 mangle -A SHADOWSOCKS6_GFW -p udp -m set --match-set white_list6 dst -j RETURN || return 1
	append_if_not_exists6 mangle -A SHADOWSOCKS6_GFW -p udp -m set --match-set black_list6 dst -j TPROXY --on-port $(get_tproxy_port6) --tproxy-mark 0x07 || return 1
	append_if_not_exists6 mangle -A SHADOWSOCKS6_GFW -p udp -m set --match-set gfwlist6 dst -j TPROXY --on-port $(get_tproxy_port6) --tproxy-mark 0x07 || return 1
	append_if_not_exists6 mangle -A SHADOWSOCKS6_GFW -p udp -m set --match-set router6 dst -j TPROXY --on-port $(get_tproxy_port6) --tproxy-mark 0x07 || return 1

	ensure_chain6 mangle SHADOWSOCKS6_CHN || return 1
	append_if_not_exists6 mangle -A SHADOWSOCKS6_CHN -p udp -m set --match-set black_list6 dst -j TPROXY --on-port $(get_tproxy_port6) --tproxy-mark 0x07 || return 1
	append_if_not_exists6 mangle -A SHADOWSOCKS6_CHN -p udp -m set --match-set chnlist6 dst -j RETURN || return 1
	append_if_not_exists6 mangle -A SHADOWSOCKS6_CHN -p udp -m set --match-set chnroute6 dst -j RETURN || return 1
	append_if_not_exists6 mangle -A SHADOWSOCKS6_CHN -p udp -m set --match-set white_list6 dst -j RETURN || return 1
	append_if_not_exists6 mangle -A SHADOWSOCKS6_CHN -p udp -j TPROXY --on-port $(get_tproxy_port6) --tproxy-mark 0x07 || return 1

	ensure_chain6 mangle SHADOWSOCKS6_GAM || return 1
	append_if_not_exists6 mangle -A SHADOWSOCKS6_GAM -p udp -m set --match-set black_list6 dst -j TPROXY --on-port $(get_tproxy_port6) --tproxy-mark 0x07 || return 1
	append_if_not_exists6 mangle -A SHADOWSOCKS6_GAM -p udp -m set --match-set chnlist6 dst -j RETURN || return 1
	append_if_not_exists6 mangle -A SHADOWSOCKS6_GAM -p udp -m set --match-set chnroute6 dst -j RETURN || return 1
	append_if_not_exists6 mangle -A SHADOWSOCKS6_GAM -p udp -m set --match-set white_list6 dst -j RETURN || return 1
	append_if_not_exists6 mangle -A SHADOWSOCKS6_GAM -p udp -j TPROXY --on-port $(get_tproxy_port6) --tproxy-mark 0x07 || return 1

	ensure_chain6 mangle SHADOWSOCKS6_GLO || return 1
	append_if_not_exists6 mangle -A SHADOWSOCKS6_GLO -p udp -m set --match-set white_list6 dst -j RETURN || return 1
	append_if_not_exists6 mangle -A SHADOWSOCKS6_GLO -p udp -j TPROXY --on-port $(get_tproxy_port6) --tproxy-mark 0x07 || return 1

	ensure_chain6 mangle SHADOWSOCKS6_HOM || return 1
	append_if_not_exists6 mangle -A SHADOWSOCKS6_HOM -p udp -m set --match-set black_list6 dst -j TPROXY --on-port $(get_tproxy_port6) --tproxy-mark 0x07 || return 1
	append_if_not_exists6 mangle -A SHADOWSOCKS6_HOM -p udp -m set --match-set gfwlist6 dst -j RETURN || return 1
	append_if_not_exists6 mangle -A SHADOWSOCKS6_HOM -p udp -m set --match-set white_list6 dst -j RETURN || return 1
	append_if_not_exists6 mangle -A SHADOWSOCKS6_HOM -p udp -j TPROXY --on-port $(get_tproxy_port6) --tproxy-mark 0x07 || return 1

	#-----------------------FOR FILTER UDP443---------------------
	ensure_chain6 filter SHADOWSOCKS6 || return 1
	append_if_not_exists6 filter -A SHADOWSOCKS6 -p udp -m set --match-set ignlist6 dst -j RETURN || return 1

	ensure_chain6 filter SHADOWSOCKS6_GFW || return 1
	append_if_not_exists6 filter -A SHADOWSOCKS6_GFW -p udp -m set --match-set white_list6 dst -j RETURN || return 1
	append_if_not_exists6 filter -A SHADOWSOCKS6_GFW -p udp -m set --match-set black_list6 dst -j REJECT --reject-with icmp6-port-unreachable || return 1
	append_if_not_exists6 filter -A SHADOWSOCKS6_GFW -p udp -m set --match-set gfwlist6 dst -j REJECT --reject-with icmp6-port-unreachable || return 1
	append_if_not_exists6 filter -A SHADOWSOCKS6_GFW -p udp -m set --match-set router6 dst -j REJECT --reject-with icmp6-port-unreachable || return 1

	ensure_chain6 filter SHADOWSOCKS6_CHN || return 1
	append_if_not_exists6 filter -A SHADOWSOCKS6_CHN -p udp -m set --match-set black_list6 dst -j REJECT --reject-with icmp6-port-unreachable || return 1
	append_if_not_exists6 filter -A SHADOWSOCKS6_CHN -p udp -m set --match-set chnlist6 dst -j RETURN || return 1
	append_if_not_exists6 filter -A SHADOWSOCKS6_CHN -p udp -m set --match-set chnroute6 dst -j RETURN || return 1
	append_if_not_exists6 filter -A SHADOWSOCKS6_CHN -p udp -m set --match-set white_list6 dst -j RETURN || return 1
	append_if_not_exists6 filter -A SHADOWSOCKS6_CHN -p udp -j REJECT --reject-with icmp6-port-unreachable || return 1

	ensure_chain6 filter SHADOWSOCKS6_GAM || return 1

	ensure_chain6 filter SHADOWSOCKS6_GLO || return 1
	append_if_not_exists6 filter -A SHADOWSOCKS6_GLO -p udp -m set --match-set white_list6 dst -j RETURN || return 1
	append_if_not_exists6 filter -A SHADOWSOCKS6_GLO -p udp -j REJECT --reject-with icmp6-port-unreachable || return 1

	echo_date "创建IPv6 xray分流模式专用链，入口策略：$( [ "$(get_shunt_ingress_mode)" = "5" ] && echo 全量引流 || echo 大陆白名单引流 )"
	init_shunt_chain_v6 || return 1

	ensure_chain6 filter SHADOWSOCKS6_HOM || return 1
	append_if_not_exists6 filter -A SHADOWSOCKS6_HOM -p udp -m set --match-set black_list6 dst -j REJECT --reject-with icmp6-port-unreachable || return 1
	append_if_not_exists6 filter -A SHADOWSOCKS6_HOM -p udp -m set --match-set gfwlist6 dst -j RETURN || return 1
	append_if_not_exists6 filter -A SHADOWSOCKS6_HOM -p udp -m set --match-set white_list6 dst -j RETURN || return 1
	append_if_not_exists6 filter -A SHADOWSOCKS6_HOM -p udp -j REJECT --reject-with icmp6-port-unreachable || return 1

	local acl_nu="${IPV6_ACL_RULES}"
	if [ -n "${acl_nu}" ];then
		for acl in ${acl_nu}
		do
			ipaddr=$(eval echo \$ss_acl_ip_${acl})
			source_rule6=$(get_acl_source_rule6 ${acl})
			if [ -z "${source_rule6}" ];then
				continue
			fi

			proxy_mode=$(eval echo \$ss_acl_mode_${acl})
			ports=$(resolve_acl_ports "$(eval echo \$ss_acl_port_${acl})" "${proxy_mode}")
			udp_flag=$(get_acl_udp_flag ${acl} ${proxy_mode})
			quic_flag=$(get_acl_quic_flag ${acl} ${proxy_mode} "${udp_flag}")
			if [ "${ports}" == "all" ]; then
				ports=""
				echo_date "加载IPv6 ACL规则：【${ipaddr}】【全部端口】模式为：$(get_mode_name ${proxy_mode})"
			else
				echo_date "加载IPv6 ACL规则：【${ipaddr}】【${ports}】模式为：$(get_mode_name ${proxy_mode})"
			fi

			append_if_not_exists6 nat -A SHADOWSOCKS6 ${source_rule6} -p tcp $(factor ${ports} "-m multiport --dport") -$(get_jump_mode ${proxy_mode}) $(get_action_chain6 ${proxy_mode}) || return 1
			apply_acl_udp_rule6 "${ipaddr}" "${source_rule6}" "${ports}" "${proxy_mode}" "${udp_flag}" "${quic_flag}" || return 1
			apply_acl_quic_filter_rule6 "${ipaddr}" "${source_rule6}" "${proxy_mode}" "${quic_flag}" || return 1
		done
	fi

	local default_udp_flag=$(get_acl_udp_flag "" "${IPV6_ACL_DEFAULT_MODE}")
	local default_quic_flag=$(get_acl_quic_flag "" "${IPV6_ACL_DEFAULT_MODE}" "${default_udp_flag}")
	append_if_not_exists6 nat -A SHADOWSOCKS6 -p tcp $(factor ${ipv6_ports} "-m multiport --dport") -j $(get_action_chain6 ${IPV6_ACL_DEFAULT_MODE}) || return 1
	apply_acl_udp_rule6 "${IPV6_ACL_DEFAULT_LABEL}" "" "${ipv6_ports}" "${IPV6_ACL_DEFAULT_MODE}" "${default_udp_flag}" "${default_quic_flag}" || return 1
	apply_acl_quic_filter_rule6 "${IPV6_ACL_DEFAULT_LABEL}" "" "${IPV6_ACL_DEFAULT_MODE}" "${default_quic_flag}" || return 1

	if ! ip6tables -t nat -C PREROUTING -p tcp -j SHADOWSOCKS6 >/dev/null 2>&1; then
		ip6tables -t nat -I PREROUTING 1 -p tcp -j SHADOWSOCKS6 >/dev/null 2>&1 || return 1
	fi

	if [ "$ss_basic_dns_hijack" == "1" ]; then
		echo_date "开启IPv6 DNS劫持功能，防止IPv6 DNS污染..."
		dns_hijack_control 6 || return 1
		local INSET_NU_DNS6=1
		for VLAN_INDEX in ${VLAN_INDEXS}
		do
			local br_ipv6=$(ip -6 addr show dev br${VLAN_INDEX} scope global 2>/dev/null | awk '/inet6/ {print $2}' | head -n1)
			[ -z "${br_ipv6}" ] && continue
			ip6tables -t nat -I PREROUTING "${INSET_NU_DNS6}" -i br${VLAN_INDEX} -p udp -m udp --dport 53 -j SHADOWSOCKS6_DNS_${VLAN_INDEX} >/dev/null 2>&1 || return 1
			let INSET_NU_DNS6+=1
		done
	else
		echo_date "IPv6 DNS劫持功能未开启，建议开启！"
	fi

	if [ "${ss_basic_mode}" != "6" ];then
		append_if_not_exists6 nat -A OUTPUT -p tcp -m set --match-set router6 dst -j REDIRECT --to-ports $(get_tproxy_port6) || return 1
		append_if_not_exists6 mangle -A OUTPUT -p udp -m set --match-set router6 dst -m udp --dport 53 -j MARK --set-mark 0x7/0xffffffff || return 1
	fi

	if [ "${mangle}" != "0" ];then
		if ! ip6tables -t mangle -C PREROUTING -p udp -j SHADOWSOCKS6 >/dev/null 2>&1; then
			ip6tables -t mangle -A PREROUTING -p udp -j SHADOWSOCKS6 >/dev/null 2>&1 || return 1
		fi
	fi

	if ! ip6tables -t filter -C FORWARD -p udp --dport 443 -j SHADOWSOCKS6 >/dev/null 2>&1; then
		ip6tables -t filter -I FORWARD 1 -p udp --dport 443 -j SHADOWSOCKS6 >/dev/null 2>&1 || return 1
	fi

	return 0
}

restart_dnsmasq() {
	# 如果是梅林固件，需要将 【Tool - Other Settings  - Advanced Tweaks and Hacks - Wan: Use local caching DNS server as system resolver (default: No)】此处设置为【是】
	# 这将确保固件自身的DNS解析使用127.0.0.1，而不是上游的DNS。否则插件的状态检测将无法解析谷歌，导致状态检测失败。
	local DLC=$(nvram get dns_local_cache)
	if [ "$DLC" == "0" ]; then
		nvram set dns_local_cache=1
		nvram commit
	fi
	# 从梅林刷到官改固件，如果不重置固件，则dns_local_cache将会保留，会导致误判，所以需要改写一次以确保OK
	local LOCAL_DNS=$(cat /etc/resolv.conf|grep "127.0.0.1")
	if [ -z "$LOCAL_DNS" ]; then
		cat >/etc/resolv.conf <<-EOF
			nameserver 127.0.0.1
		EOF
	fi
	# Restart dnsmasq
	echo_date "重启dnsmasq服务..."
	service restart_dnsmasq >/dev/null 2>&1 &
	detect_running_status dnsmasq
}

load_module() {
	xt=$(lsmod | grep xt_set)
	OS=$(uname -r)
	if [ -f /lib/modules/${OS}/kernel/net/netfilter/xt_set.ko -a -z "$xt" ]; then
		echo_date "加载xt_set.ko内核模块！"
		insmod /lib/modules/${OS}/kernel/net/netfilter/xt_set.ko
	fi
}

# write number into nvram with no commit
read_rules_runtime_numbers_tsv() {
	[ -f "/koolshare/ss/rules/rules.json.js" ] || return 1
	run /koolshare/bin/jq -r '
		def text($v):
			if $v == null then
				""
			elif ($v | type) == "string" then
				$v
			else
				($v | tostring)
			end;
		[
			text(.gfwlist.date),
			text(.chnlist.date),
			text(.chnroute.date),
			text(.gfwlist.count),
			text(.chnroute.count),
			text(.chnroute.count_ip),
			text(.chnlist.count)
		] | join("\u001f")
	' /koolshare/ss/rules/rules.json.js 2>/dev/null
}

write_numbers() {
	IFS="$(printf '\037')" read -r rule_gfw_date rule_chnlist_date rule_chnroute_date rule_gfw_count rule_chnroute_count rule_chnroute_ip_count rule_chnlist_count <<-EOF
	$(read_rules_runtime_numbers_tsv)
	EOF
	nvram set update_gfwlist="${rule_gfw_date}"
	nvram set update_chnlist="${rule_chnlist_date}"
	nvram set update_chnroute="${rule_chnroute_date}"
	nvram set gfwlist_numbers="${rule_gfw_count}"
	nvram set chnroute_numbers="${rule_chnroute_count}"
	nvram set chnroute_ips="${rule_chnroute_ip_count}"
	nvram set chnlist_numbers="${rule_chnlist_count}"
}

remove_ss_reboot_job() {
	if [ -n "$(cru l | grep ss_reboot)" ]; then
		echo_date "【科学上网】：删除插件自动重启定时任务..."
		sed -i '/ss_reboot/d' /var/spool/cron/crontabs/* >/dev/null 2>&1
	fi
}

set_ss_reboot_job() {
	if [[ "${ss_reboot_check}" == "0" ]]; then
		remove_ss_reboot_job
	elif [[ "${ss_reboot_check}" == "1" ]]; then
		echo_date "【科学上网】：设置每天${ss_basic_time_hour}时${ss_basic_time_min}分重启插件..."
		cru a ss_reboot ${ss_basic_time_min} ${ss_basic_time_hour}" * * * /bin/sh /koolshare/ss/ssconfig.sh restart"
	elif [[ "${ss_reboot_check}" == "2" ]]; then
		echo_date "【科学上网】：设置每周${ss_basic_week}的${ss_basic_time_hour}时${ss_basic_time_min}分重启插件..."
		cru a ss_reboot ${ss_basic_time_min} ${ss_basic_time_hour}" * * "${ss_basic_week}" /bin/sh /koolshare/ss/ssconfig.sh restart"
	elif [[ "${ss_reboot_check}" == "3" ]]; then
		echo_date "【科学上网】：设置每月${ss_basic_day}日${ss_basic_time_hour}时${ss_basic_time_min}分重启插件..."
		cru a ss_reboot ${ss_basic_time_min} ${ss_basic_time_hour} ${ss_basic_day}" * * /bin/sh /koolshare/ss/ssconfig.sh restart"
	elif [[ "${ss_reboot_check}" == "4" ]]; then
		if [[ "${ss_basic_inter_pre}" == "1" ]]; then
			echo_date "【科学上网】：设置每隔${ss_basic_inter_min}分钟重启插件..."
			cru a ss_reboot "*/"${ss_basic_inter_min}" * * * * /bin/sh /koolshare/ss/ssconfig.sh restart"
		elif [[ "${ss_basic_inter_pre}" == "2" ]]; then
			echo_date "【科学上网】：设置每隔${ss_basic_inter_hour}小时重启插件..."
			cru a ss_reboot "0 */"${ss_basic_inter_hour}" * * * /bin/sh /koolshare/ss/ssconfig.sh restart"
		elif [[ "${ss_basic_inter_pre}" == "3" ]]; then
			echo_date "【科学上网】：设置每隔${ss_basic_inter_day}天${ss_basic_inter_hour}小时${ss_basic_time_min}分钟重启插件..."
			cru a ss_reboot ${ss_basic_time_min} ${ss_basic_time_hour}" */"${ss_basic_inter_day} " * * /bin/sh /koolshare/ss/ssconfig.sh restart"
		fi
	elif [[ "${ss_reboot_check}" == "5" ]]; then
		check_custom_time=$(echo ss_basic_custom | base64_decode)
		echo_date "【科学上网】：设置每天${check_custom_time}时的${ss_basic_time_min}分重启插件..."
		cru a ss_reboot ${ss_basic_time_min} ${check_custom_time}" * * * /bin/sh /koolshare/ss/ssconfig.sh restart"
	fi
}

remove_ss_trigger_job() {
	if [ -n "$(cru l | grep ss_tri_check)" ]; then
		sed -i '/ss_tri_check/d' /var/spool/cron/crontabs/* >/dev/null 2>&1
	fi
}

ss_post_start() {
	# 在SS插件启动成功后触发脚本
	local i
	mkdir -p /koolshare/ss/postscripts && cd /koolshare/ss/postscripts
	for i in $(find ./ -name 'P*' | sort); do
		trap "" INT QUIT TSTP EXIT
		echo_date ------------- 【科学上网】 启动后触发脚本: $i -------------
		if [ -r "$i" ]; then
			$i start
		fi
		echo_date ----------------- 触发脚本: $i 运行完毕 -----------------
	done
}

ss_pre_stop() {
	# 在SS插件关闭前触发脚本
	local i
	mkdir -p /koolshare/ss/postscripts && cd /koolshare/ss/postscripts
	for i in $(find ./ -name 'P*' | sort -r); do
		trap "" INT QUIT TSTP EXIT
		echo_date ------------- 【科学上网】 关闭前触发脚本: $i ------------
		if [ -r "$i" ]; then
			$i stop
		fi
		echo_date ----------------- 触发脚本: $i 运行完毕 -----------------
	done
}

stop_status_kill_pid_list() {
	local label="$1"
	local pids_raw="$2"
	local signal="${3:--9}"
	local pids=""
	pids="$(printf '%s\n' "${pids_raw}" | tr ' ' '\n' | sed '/^$/d' | awk '!seen[$0]++')" || pids=""
	[ -n "${pids}" ] || return 1
	echo_date "关闭${label}..."
	printf '%s\n' "${pids}" | while IFS= read -r pid
	do
		[ -n "${pid}" ] || continue
		kill "${signal}" "${pid}" >/dev/null 2>&1
	done
	return 0
}

stop_status_kill_pidfile() {
	local label="$1"
	local pidfile="$2"
	[ -f "${pidfile}" ] || return 1
	local pid=""
	pid="$(cat "${pidfile}" 2>/dev/null)"
	[ -n "${pid}" ] || return 1
	kill -0 "${pid}" >/dev/null 2>&1 || return 1
	echo_date "关闭${label}..."
	start-stop-daemon -K -q -p "${pidfile}" >/dev/null 2>&1
	return 0
}

stop_status() {
	local status_tool_bin="/koolshare/bin/status-tool"
	local status_daemon_pidfile="/var/run/status-tool.pid"
	local status_serve_pidfile="/var/run/status-tool-serve.pid"
	local status_daemon_state="/tmp/upload/ss_status_daemon.json"
	local status_daemon_legacy="/tmp/upload/ss_status_front.txt"
	local status_serve_socket="/tmp/status-tool.sock"
	local status_serve_args_file="/tmp/status-tool-serve.args"
	local status_ws_lock_dir="/tmp/fancyss_status_ws.lock"
	local status_http_lock_dir="/tmp/fancyss_status_http.lock"
	local pids=""

	pids="$(pidof ss_status.sh 2>/dev/null)"
	stop_status_kill_pid_list "状态检测前端脚本" "${pids}" "-9" || {
		pids="$(ps w | grep -F "sh /koolshare/scripts/ss_status.sh" | grep -v grep | awk '{print $1}')"
		stop_status_kill_pid_list "状态检测前端脚本" "${pids}" "-9" || true
	}

	if pidof curl-status >/dev/null 2>&1; then
		echo_date "关闭curl-status进程..."
		killall curl-status >/dev/null 2>&1
	fi

	if pidof statusctl >/dev/null 2>&1; then
		echo_date "关闭statusctl进程..."
		killall statusctl >/dev/null 2>&1
	fi

	stop_status_kill_pidfile "status-tool daemon进程" "${status_daemon_pidfile}" || true
	stop_status_kill_pidfile "status-tool serve进程" "${status_serve_pidfile}" || true

	pids="$(ps w | grep -E '(^| )(/koolshare/bin/status-tool|/tmp/status-tool-serve) (daemon|serve|fancyss)( |$)' | grep -v grep | awk '{print $1}')"
	stop_status_kill_pid_list "status-tool残留进程" "${pids}" "-15" || true

	rm -f "${status_daemon_pidfile}" "${status_serve_pidfile}" "${status_daemon_state}" "${status_daemon_legacy}" "${status_serve_socket}" "${status_serve_args_file}" >/dev/null 2>&1
	rm -rf "${status_ws_lock_dir}" >/dev/null 2>&1
	rm -rf "${status_http_lock_dir}" >/dev/null 2>&1
	rm -rf /tmp/upload/ss_status.txt
}

detect_ip(){
	local SUBJECT=$1
	local TIMEOUT=$2
	local METHOD=$3
	local CURL_IP_FLAG="-4"
	[ -z "${TIMEOUT}" ] && TIMEOUT="3"

	if [ "${METHOD}" == "1" ] && ipv6_proxy_enabled; then
		CURL_IP_FLAG=""
	fi

	if [ "${METHOD}" == "0" ];then
		# 检测国内ip
		local IP=$(run curl-fancyss ${CURL_IP_FLAG} -s -m ${TIMEOUT} ${SUBJECT} 2>&1 | grep -Eo "([0-9]{1,3}[\.]){3}[0-9]{1,3}" | grep -v "Terminated")
	elif [ "${METHOD}" == "1" ];then
		# 检测代理ip
		local SOCKS5_OPEN=$(netstat -nlpt 2>/dev/null|grep -w "23456"|grep -Eo "v2ray|xray|naive|tuic|anytls-zig")
		if [ -n "${SOCKS5_OPEN}" ];then
			local IP=$(run curl-fancyss ${CURL_IP_FLAG} -s -x socks5h://127.0.0.1:23456 -m ${TIMEOUT} ${SUBJECT} 2>&1 | grep -v "Terminated")
		else
			local IP=$(run curl-fancyss ${CURL_IP_FLAG} -s -m  ${TIMEOUT} ${SUBJECT} 2>&1 | grep -v "Terminated")
		fi
	fi

	local IP=$(__valid_ip $IP)
	echo ${IP}
}

check_frn_public_ip(){
	echo_date "开始代理出口ip检测..."

	local SOCKS5_OPEN=$(netstat -nlp 2>/dev/null | grep -w "23456" | grep -Eo "v2ray|xray|naive|tuic|anytls-zig" | head -n1)
	if [ -n "${SOCKS5_OPEN}" ];then
		echo_date "检测方式1：socks5"
	else
		echo_date "检测方式2：透明代理"
	fi
	
	if [ -z "${REMOTE_IP_FRN}" ];then
		REMOTE_IP_FRN_SRC="http://ip.sb"
		REMOTE_IP_FRN=$(detect_ip "${REMOTE_IP_FRN_SRC}" 5 1)
	fi
	
	if [ -z "${REMOTE_IP_FRN}" ];then
		REMOTE_IP_FRN_SRC="https://icanhazip.com/"
		REMOTE_IP_FRN=$(detect_ip "${REMOTE_IP_FRN_SRC}" 3 1)
	fi
	
	if [ -z "${REMOTE_IP_FRN}" ];then
		REMOTE_IP_FRN_SRC="https://ipecho.net/plain"
		REMOTE_IP_FRN=$(detect_ip "${REMOTE_IP_FRN_SRC}" 4 1)
	fi

	if [ -n "${REMOTE_IP_FRN}" ];then
		__valid_ip46 ${REMOTE_IP_FRN}
		if [ "$?" == "0" ]; then
			# ipv4
			ipset test chnroute ${REMOTE_IP_FRN} >/dev/null 2>&1
			if [ "$?" != "0" ]; then
				# 国外ip
				echo_date "代理服务器出口地址：${REMOTE_IP_FRN}，属地：海外，来源：${REMOTE_IP_FRN_SRC}"
			else
				# 国内ip
				echo_date "代理服务器出口地址：${REMOTE_IP_FRN}，属地：大陆，来源：${REMOTE_IP_FRN_SRC}"
			fi
		elif [ "$?" == "1" ]; then
			# ipv6
			echo_date "代理服务器出口地址：${REMOTE_IP_FRN}，来源：${REMOTE_IP_FRN_SRC}"
		fi
	else
		echo_date "代理服务器出口地址检测失败！可能是以下原因："
		echo_date "---------------------------------------------------------"
		echo_date "1. 节点失效，请尝试更新订阅、更换节点"
		echo_date "2. 节点延迟较高，请尝试更换低延迟节点"
		if [ "${FDNS_OK_FLAG}" != "1" ];then
			echo_date "3. DNS解析失效，请尝试更换DNS方案"
		fi
		echo_date "插件将会继续运行，但是不保证代理工作正常！"
		echo_date "---------------------------------------------------------"
		# close_in_five flag
	fi


	# 检测节点解析结果
	if [ -z "${CURRENT_NODE_SERVER_RESOLVED_IP}" ] && [ -n "${ss_basic_server_orig}" ] && [ -n "$(is_domain "${ss_basic_server_orig}")" ]; then
		refresh_current_node_server_ip_runtime >/dev/null 2>&1 || true
	fi
	if [ -n "${CURRENT_NODE_SERVER_RESOLVED_IP}" ]; then
		__valid_ip46 "${CURRENT_NODE_SERVER_RESOLVED_IP}"
		if [ "$?" == "0" ]; then
			# ipv4
			ipset test chnroute ${CURRENT_NODE_SERVER_RESOLVED_IP} >/dev/null 2>&1
			if [ "$?" != "0" ]; then
				# 国外ip
				ss_real_server_ip="${CURRENT_NODE_SERVER_RESOLVED_IP}"
				echo_date "节点服务器解析地址：${CURRENT_NODE_SERVER_RESOLVED_IP}，属地：海外，来源：${ss_basic_server_orig}"
			else
				# 国内ip
				ss_real_server_ip=""
				echo_date "节点服务器解析地址：${CURRENT_NODE_SERVER_RESOLVED_IP}，属地：大陆，来源：${ss_basic_server_orig}"
			fi
		elif [ "$?" == "1" ]; then
			# ipv6
			ipset test chnroute6 ${CURRENT_NODE_SERVER_RESOLVED_IP} >/dev/null 2>&1
			if [ "$?" != "0" ]; then
				# 国外ip
				ss_real_server_ip="${CURRENT_NODE_SERVER_RESOLVED_IP}"
				echo_date "节点服务器解析地址：${CURRENT_NODE_SERVER_RESOLVED_IP}，属地：海外，来源：${ss_basic_server_orig}"
			else
				# 国内ip
				ss_real_server_ip=""
				echo_date "节点服务器解析地址：${CURRENT_NODE_SERVER_RESOLVED_IP}，属地：大陆，来源：${ss_basic_server_orig}"
			fi
		fi
	fi
}

finish_start(){
	# get foreign ip
	if [ "${ss_basic_nofrnipcheck}" != "1" ];then
		echo_date "---------------------------------------------------------"
		echo_date "所有服务和规则加载完毕，运行一些检测..."
		check_frn_public_ip
	fi
}

check_status() {
	dbus remove ss_basic_wait
	sh /koolshare/scripts/ss_status_daemon.sh restart >/dev/null 2>&1

	(
		# 对一些域名进行预解析，如果本地有解析缓存，解析没有走路由器，则ipset没有写入导致无法走代理，所以一些域名可以预解析一次
		run_bg dnsclient -46 -t 5 -i 2 @127.0.0.1 openai.com
		run_bg dnsclient -46 -t 5 -i 2 @127.0.0.1 chat.openai.com
		run_bg dnsclient -46 -t 5 -i 2 @127.0.0.1 stun.syncthing.net
	)&

}

disable_ss() {
	echo_date ======================= 梅林固件 - 【科学上网】 ========================
	echo_date
	echo_date ------------------------- 关闭【科学上网】 -----------------------------
	ss_pre_stop
	set_skin
	dbus remove ss_basic_server_ip
	stop_status
	stop_ws
	kill_process
	remove_ss_trigger_job
	remove_ss_reboot_job
	restore_conf
	restart_dnsmasq
	flush_iptables
	flush_ipset
	kill_cron_job
	rm -rf /tmp/upload/fancyss_node_name.txt
	dbus remove ss_basic_tri_reboot_time
	dbus remove ss_basic_server_resolv
	dbus remove ss_basic_server_resolv_user
	dbus remove ss_basic_lastru
	dbus set ss_basic_status="0"
	echo_date ------------------------ 【科学上网】已关闭 ----------------------------
}

apply_ss() {
	echo_date ======================= 梅林固件 - 【科学上网】 ========================
	echo_date
	# alpha.17 P1-1: 启动时打印运行参数总览（用户最高优先级运维体验改进）
	echo_date "运行参数: enable=${ss_basic_enable} mode=${ss_basic_mode}(type=${ss_basic_type}) node=${ssconf_basic_node} front=${ssconf_basic_node_front:-(无)}"
	if [ "${ss_basic_status}" == "1" ];then
		echo_date ------------------------- 关闭【科学上网】 -----------------------------
		ss_pre_stop
		stop_status
		kill_process
		remove_ss_trigger_job
		remove_ss_reboot_job
		restore_conf
		restart_dnsmasq
		flush_iptables
		flush_ipset
		kill_cron_job
	fi
	# pre-start
	echo_date ------------------------- 启动【科学上网】 -----------------------------
	# start
	FSS_SKIP_XRAY_PORT_CLEANUP=""
	prepare_system
	resolv_server_ip
	load_module
	# doge.14: 分流唯一路径；不再创建旧版 ipset 大全（chnlist/chnroute/...），
	# load_iptables_split 自己创建 ignlist_minimal。
	create_dnsmasq_conf
	# FORK doge.12 alpha: split 路径下白/黑名单数据由 generate_xray_json_split 内联消费，
	# 不再写入 ipset；但 add_white_black 还会做一些 /tmp 文件准备工作（chinadns 用），
	# 在 ss_basic_dns_serverx=1 时被分流 DNS 实例间接依赖，保留调用。
	add_white_black
	# 生成代理主程序配置
	[ "${ss_basic_type}" == "0" ] && creat_xray_ss_json
	# FORK: cut in doge.10, see doc/design/protocol-roadmap.md §2 (SSR type=1)
	# [ "${ss_basic_type}" == "1" ] && creat_ssr_json
	[ "${ss_basic_type}" == "3" ] && creat_vmess_json
	[ "${ss_basic_type}" == "4" ] && creat_vless_json
	[ "${ss_basic_type}" == "5" ] && creat_trojan_json
	[ "${ss_basic_type}" == "8" ] && creat_hy2_json

	local bootstrap_dns_first="0"
	if should_bootstrap_dns_before_proxy; then
		bootstrap_dns_first="1"
		restart_dnsmasq
		start_dns_x
		if ! refresh_current_node_server_ip_runtime; then
			echo_date "节点服务器域名运行时解析失败，将继续启动代理主程序，并等待客户端后续自行解析。"
		fi
	fi

	# 开启代理主程序
	[ "${ss_basic_type}" == "0" ] && start_xray
	# FORK: cut in doge.10, see doc/design/protocol-roadmap.md §2 (SSR type=1 / Naive type=6 / Tuic type=7)
	# [ "${ss_basic_type}" == "1" ] && start_ssr_redir
	[ "${ss_basic_type}" == "3" ] && start_xray
	[ "${ss_basic_type}" == "4" ] && start_xray
	[ "${ss_basic_type}" == "5" ] && start_trojan
	# [ "${ss_basic_type}" == "6" ] && start_naive
	# [ "${ss_basic_type}" == "7" ] && start_tuic
	[ "${ss_basic_type}" == "8" ] && start_hy2
	[ "${ss_basic_type}" == "9" ] && start_anytls

	if [ "${bootstrap_dns_first}" != "1" ]; then
		restart_dnsmasq
		start_dns_x
	fi

	get_proxy_server_ip
	load_iptables
	#restart_dnsmasq
	auto_start
	write_cron_job
	set_ss_reboot_job
	write_numbers
	finish_start
	ss_post_start
	check_status
	# 分流路径诊断：xray inbound TPROXY 端口是否真在 listen，
	# 方便实机定位 "iptables TPROXY 计数有但客户端不通"。
	sleep 1
	local _split_listen=$(netstat -lntup 2>/dev/null | grep -E "[: ](13333|13334|13335|13336|23456)\b" | head -10)
	if [ -n "${_split_listen}" ]; then
		echo_date "🔎 split 诊断: xray 监听端口 ↓"
		echo "${_split_listen}" | while IFS= read -r _line; do echo_date "    ${_line}"; done
	else
		echo_date "⚠️ split 诊断: 未探测到 xray 在 13333~13336/23456 上 listen，xray 可能 inbound 启动失败"
		if [ -f /tmp/upload/xray.log ]; then
			echo_date "    /tmp/upload/xray.log 尾部 ↓"
			tail -8 /tmp/upload/xray.log 2>/dev/null | while IFS= read -r _line; do echo_date "    ${_line}"; done
		fi
	fi
	# store current status
	dbus set ss_basic_status="1"
	# alpha.17 P1-6: 启动尾部摘要关键状态，给用户一眼可见的"启动后是否正常"信号
	echo_date "📋 启动状态摘要: status=1 mode=${ss_basic_mode} dns_plan=${ss_basic_dns_plan:-1} chain_status=$(dbus get ss_chain_status 2>/dev/null || echo disabled) split_xray_warn=$(dbus get fss_split_xray_warn 2>/dev/null || echo OK)"
	echo_date ------------------------ 【科学上网】 启动完毕 ------------------------
	FSS_SKIP_XRAY_PORT_CLEANUP=""
}

# for debug
get_status() {
	echo_date
	echo_date =========================================================
	echo_date "PID of this script: $$"
	echo_date "PPID of this script: $PPID"
	echo_date ========== 本脚本的PID ==========
	ps | grep $$ | grep -v grep
	echo_date ========== 本脚本的PPID ==========
	ps | grep $PPID | grep -v grep
	echo_date ========== 所有运行中的shell ==========
	ps | grep "\.sh" | grep -v grep
	echo_date ------------------------------------

	WAN_ACTION=$(ps | grep /jffs/scripts/wan-start | grep -v grep)
	NAT_ACTION=$(ps | grep /jffs/scripts/nat-start | grep -v grep)
	WEB_ACTION=$(ps | grep "ss_config.sh" | grep -v grep)
	[ -n "${WAN_ACTION}" ] && echo_date "路由器开机触发fancyss重启！"
	[ -n "${NAT_ACTION}" ] && echo_date "路由器防火墙触发fancyss重启！"
	[ -n "${WEB_ACTION}" ] && echo_date "WEB提交操作触发fancyss重启！"

	iptables -nvL PREROUTING -t nat
	iptables -nvL OUTPUT -t nat
	iptables -nvL SHADOWSOCKS -t nat
	iptables -nvL SHADOWSOCKS_EXT -t nat
	iptables -nvL SHADOWSOCKS_GFW -t nat
	iptables -nvL SHADOWSOCKS_CHN -t nat
	iptables -nvL SHADOWSOCKS_GAM -t nat
	iptables -nvL SHADOWSOCKS_GLO -t nat
	iptables -nvL SHADOWSOCKS_SHU -t nat 2>/dev/null
}

apply_ss_by_nat() {
	# 1. 开机的时候会触发，此时其它组件都没有准备，需要开启
	# 2. 防火墙重启，重新拨号等会触发，此时其它组件都是ok的，只需要重启iptables
	echo_date ======================= 梅林固件 - 【科学上网】 ========================
	echo_date
	echo_date "restart by nat!"
	flush_iptables
	load_iptables
	echo_date
	echo_date ------------------------ 【科学上网】 启动完毕 ------------------------
}

pick_start_stop_daemon(){
	for candidate in /sbin/start-stop-daemon /usr/sbin/start-stop-daemon /bin/start-stop-daemon /usr/bin/start-stop-daemon
	do
		[ -x "${candidate}" ] && {
			echo "${candidate}"
			return 0
		}
	done
	return 1
}

force_kill_pid(){
	local pid="$1"
	[ -n "${pid}" ] || return 0
	kill "${pid}" >/dev/null 2>&1
	sleep 1
	kill -9 "${pid}" >/dev/null 2>&1
}

get_ws_master_pid(){
	local pid=""
	if [ -f "${WS_PIDFILE}" ];then
		pid=$(cat "${WS_PIDFILE}" 2>/dev/null)
		if [ -n "${pid}" ] && kill -0 "${pid}" >/dev/null 2>&1; then
			echo "${pid}"
			return 0
		fi
	fi
	pid=$(ps w | grep -F "/koolshare/bin/websocketd --port=803 /koolshare/ss/websocket" | grep -v grep | awk 'NR==1{print $1}')
	[ -n "${pid}" ] && echo "${pid}"
}

cleanup_ws_shells_once(){
	local active_ws_pid="$1"
	local pid=""
	local ppid=""
	[ -n "${active_ws_pid}" ] || active_ws_pid="$(get_ws_master_pid)"
	ps w | grep -E '(/bin/sh|[[:space:]]sh)[[:space:]]+/koolshare/ss/websocket([[:space:]]|$)' | grep -v grep | awk '{print $1}' | while read -r pid
	do
		[ -n "${pid}" ] || continue
		ppid="$(sed -n 's/^PPid:[[:space:]]*//p' "/proc/${pid}/status" 2>/dev/null | sed -n '1p')"
		if [ -n "${active_ws_pid}" ] && [ "${ppid}" = "${active_ws_pid}" ]; then
			continue
		fi
		force_kill_pid "${pid}"
	done
}

sync_ws_pidfile(){
	local active_ws_pid="$1"
	[ -n "${active_ws_pid}" ] || active_ws_pid="$(get_ws_master_pid)"
	if [ -n "${active_ws_pid}" ]; then
		echo "${active_ws_pid}" > "${WS_PIDFILE}" 2>/dev/null || true
	else
		rm -f "${WS_PIDFILE}" >/dev/null 2>&1 || true
	fi
}

start_ws(){
	local ssd=""
	local active_ws_pid=""
	active_ws_pid="$(get_ws_master_pid)"
	if [ -z "${active_ws_pid}" ] && [ -x "/koolshare/bin/websocketd" -a -f "/koolshare/ss/websocket" ];then
		ssd="$(pick_start_stop_daemon 2>/dev/null)"
		rm -f "${WS_PIDFILE}" >/dev/null 2>&1 || true
		if [ -n "${ssd}" ]; then
			"${ssd}" -S -q -b -m -p "${WS_PIDFILE}" -x /koolshare/bin/websocketd -- --port=803 /koolshare/ss/websocket
		else
			/koolshare/bin/websocketd --port=803 /koolshare/ss/websocket >/tmp/upload/websocketd.log 2>&1 &
			echo $! > "${WS_PIDFILE}"
		fi
	fi
	active_ws_pid="$(get_ws_master_pid)"
	sync_ws_pidfile "${active_ws_pid}"
	cleanup_ws_shells_once "${active_ws_pid}"
}

stop_ws(){
	local active_ws_pid=""
	active_ws_pid="$(get_ws_master_pid)"
	sync_ws_pidfile "${active_ws_pid}"
	cleanup_ws_shells_once "${active_ws_pid}"
}

# =========================================================================

case $ACTION in
start)
	# start on wan-start
	set_lock
	if [ "$ss_basic_enable" == "1" ]; then
		logger "[软件中心]: wan-start启动科学上网插件！"
		start_ws
		apply_ss 2>&1 | tee -a "$LOG_FILE" | tee -a "/tmp/upload/ss_wan_log.txt"
		echo XU6J03M6 | tee -a "$LOG_FILE"
	else
		logger "[软件中心]: 科学上网插件未开启，不启动！"
	fi
	unset_lock
	;;
stop)
	set_lock
	disable_ss
	echo_date
	echo_date "你已经成功关闭科学上网服务~"
	echo_date "See you again!"
	echo_date
	echo_date ======================= 梅林固件 - 【科学上网】 ========================
	unset_lock
	;;
restart)
	# start/restart by web or user
	set_lock
	start_ws
	apply_ss
	echo_date
	echo_date "Across the Great Wall we can reach every corner in the world!"
	echo_date
	echo_date ======================= 梅林固件 - 【科学上网】 ========================
	unset_lock
	;;
flush_nat)
		set_lock
		flush_iptables
		unset_lock
		;;
start_nat)
	# start on nat-start
	SOCKS5_OPEN=$(netstat -nlpt 2>/dev/null|grep -w "23456"|grep -Eo "v2ray|xray|naive|tuic|anytls-zig")
	if [ -z "${SOCKS5_OPEN}" ];then
		# 代理程序没有运行，可能是刚开机，不继续
		return 0
	fi
	set_lock
	if [ "$ss_basic_enable" == "1" ]; then
		logger "[软件中心]: nat-start触发fancyss重启！"
		true >"$LOG_FILE"
		apply_ss_by_nat 2>&1 | tee -a "$LOG_FILE" | tee -a "/tmp/upload/ss_nat_log.txt"
		echo XU6J03M6 | tee -a "$LOG_FILE"
	fi
	unset_lock
	;;
restart_chinadns_ng)
	# doge.14: 分流架构唯一路径
	stop_chinadns_ng_split
	start_chinadns_ng_split
	;;
refresh_node_direct_dns)
	set_lock
	refresh_node_direct_dns
	unset_lock
	;;
esac
