#!/bin/sh

# fancyss script for asuswrt/merlin based router with software center

source /koolshare/scripts/base.sh
NEW_PATH=$(echo $PATH|tr ':' '\n'|sed '/opt/d;/mmc/d'|awk '!a[$0]++'|tr '\n' ':'|sed '$ s/:$//')
export PATH=${NEW_PATH}
MODEL=
FW_TYPE_NAME=
DIR=$(cd $(dirname $0); pwd)
[ -f "${DIR}/scripts/ss_node_common.sh" ] && source "${DIR}/scripts/ss_node_common.sh"
[ -f "${DIR}/scripts/ss_subscribe_profile_lib.sh" ] && source "${DIR}/scripts/ss_subscribe_profile_lib.sh"
unalias echo_date >/dev/null 2>&1
echo_date(){
	echo "【$(TZ=UTC-8 date -R "+%Y%m%d %X")】: $*"
}
module=${DIR##*/}
LINUX_VER=$(uname -r|awk -F"." '{print $1$2}')

run_bg(){
	env -i PATH=${PATH} "$@" >/dev/null 2>&1 &
}

version_ge() {
	local current="$1"
	local required="$2"
	local current_major current_minor current_patch required_major required_minor required_patch
	current="$(printf '%s' "${current}" | sed 's/^v//' | sed 's/[^0-9.].*$//')"
	required="$(printf '%s' "${required}" | sed 's/^v//' | sed 's/[^0-9.].*$//')"
	current_major="$(printf '%s' "${current}" | awk -F. '{print $1 + 0}')"
	current_minor="$(printf '%s' "${current}" | awk -F. '{print $2 + 0}')"
	current_patch="$(printf '%s' "${current}" | awk -F. '{print $3 + 0}')"
	required_major="$(printf '%s' "${required}" | awk -F. '{print $1 + 0}')"
	required_minor="$(printf '%s' "${required}" | awk -F. '{print $2 + 0}')"
	required_patch="$(printf '%s' "${required}" | awk -F. '{print $3 + 0}')"
	[ "${current_major}" -gt "${required_major}" ] && return 0
	[ "${current_major}" -lt "${required_major}" ] && return 1
	[ "${current_minor}" -gt "${required_minor}" ] && return 0
	[ "${current_minor}" -lt "${required_minor}" ] && return 1
	[ "${current_patch}" -ge "${required_patch}" ]
}

invalidate_runtime_caches_after_install() {
	rm -rf /koolshare/configs/fancyss/node_json_cache >/dev/null 2>&1
	rm -f /koolshare/configs/fancyss/node_json_cache.meta >/dev/null 2>&1
	fss_clear_node_env_cache_artifacts >/dev/null 2>&1 || true
	fss_clear_webtest_cache_all >/dev/null 2>&1 || true
	fss_clear_webtest_runtime_results >/dev/null 2>&1 || true
	rm -rf /tmp/fancyss_webtest >/dev/null 2>&1
	rm -rf /tmp/fancyss_cache_state >/dev/null 2>&1
}

refresh_runtime_caches_after_install() {
	invalidate_runtime_caches_after_install
	fss_refresh_node_json_cache >/dev/null 2>&1 || true
	fss_schedule_webtest_cache_warm >/dev/null 2>&1 || true
}

get_proc_name(){
	local pid="$1"
	[ -n "${pid}" ] || return 1
	sed -n 's/^Name:[[:space:]]*//p' "/proc/${pid}/status" 2>/dev/null | sed -n '1p'
}

get_proc_cmdline(){
	local pid="$1"
	[ -n "${pid}" ] || return 1
	tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null
}

get_proc_ppid(){
	local pid="$1"
	[ -n "${pid}" ] || return 1
	sed -n 's/^PPid:[[:space:]]*//p' "/proc/${pid}/status" 2>/dev/null | sed -n '1p'
}

install_parent_chain_contains(){
	local pattern="$1"
	local pid="$$"
	local depth=0
	local name=""
	local cmdline=""
	while [ -n "${pid}" ] && [ "${pid}" != "0" ] && [ "${depth}" -lt 12 ]
	do
		name="$(get_proc_name "${pid}")"
		cmdline="$(get_proc_cmdline "${pid}")"
		if echo "${name} ${cmdline}" | grep -q "${pattern}"; then
			return 0
		fi
		pid="$(get_proc_ppid "${pid}")"
		depth=$((depth + 1))
	done
	return 1
}

is_softcenter_offline_install(){
	local softcenter_installer_pattern="ks_tar_""install\\.sh"
	install_parent_chain_contains "${softcenter_installer_pattern}\\|start-stop-daemon"
}

is_fancyss_self_update_install(){
	[ -f "/tmp/fancyss_self_update_installing" ] && return 0
	install_parent_chain_contains "ss_update\\.sh\\|/koolshare/ss/websocket"
}

md5_file() {
	local file="$1"
	[ -f "${file}" ] || return 1
	md5sum "${file}" 2>/dev/null | awk '{print $1}'
}

prepare_websocketd_package() {
	local current="/koolshare/bin/websocketd"
	local incoming="/tmp/shadowsocks/bin/websocketd"
	local current_md5=""
	local incoming_md5=""
	rm -f /tmp/fancyss_websocketd_changed /tmp/fancyss_pending_websocketd_restart >/dev/null 2>&1 || true
	rm -rf /tmp/fancyss_deferred_websocketd >/dev/null 2>&1 || true
	[ -f "${incoming}" ] || {
		echo_date "本次安装包未包含 websocketd，跳过 websocketd 替换检查。"
		return 0
	}
	if [ -f "${current}" ]; then
		current_md5="$(md5_file "${current}")"
		incoming_md5="$(md5_file "${incoming}")"
		if [ -n "${current_md5}" ] && [ "${current_md5}" = "${incoming_md5}" ]; then
			rm -f "${incoming}" >/dev/null 2>&1 || true
			echo_date "websocketd 未变化，跳过二进制替换和进程重启。"
			return 0
		fi
		echo_date "检测到 websocketd 二进制变化，将按安装场景安全切换。"
	else
		echo_date "当前未安装 websocketd，将安装并拉起 websocketd。"
	fi
	echo 1 >/tmp/fancyss_websocketd_changed
	if is_fancyss_self_update_install; then
		defer_websocketd_binary_for_self_update
	fi
}

prepare_websocketd_for_copy() {
	local incoming="/tmp/shadowsocks/bin/websocketd"
	[ -f "/tmp/fancyss_websocketd_changed" ] || return 0
	if ! is_fancyss_self_update_install && [ -f "${incoming}" ]; then
		echo_date "准备切换 websocketd，先停止旧 websocketd 进程..."
		stop_websocketd_for_install
	fi
}

stop_websocketd_for_install() {
	local pid=""
	local WS_PIDFILE="/var/run/fancyss-websocketd.pid"
	if [ -f "${WS_PIDFILE}" ]; then
		pid="$(cat "${WS_PIDFILE}" 2>/dev/null)"
		if [ -n "${pid}" ]; then
			kill "${pid}" >/dev/null 2>&1 || true
			sleep 1
			kill -9 "${pid}" >/dev/null 2>&1 || true
		fi
	fi
	killall websocketd >/dev/null 2>&1 || true
	ps w | grep -F "/koolshare/bin/websocketd --port=803 /koolshare/ss/websocket" | grep -v grep | awk '{print $1}' | while read -r pid
	do
		[ -n "${pid}" ] || continue
		kill "${pid}" >/dev/null 2>&1 || true
		sleep 1
		kill -9 "${pid}" >/dev/null 2>&1 || true
	done
	ps w | grep -F "/koolshare/ss/websocket" | grep -v grep | awk '{print $1}' | while read -r pid
	do
		[ -n "${pid}" ] || continue
		kill "${pid}" >/dev/null 2>&1 || true
		sleep 1
		kill -9 "${pid}" >/dev/null 2>&1 || true
	done
	rm -f "${WS_PIDFILE}" >/dev/null 2>&1 || true
}

restart_websocketd_async() {
	local helper="/tmp/fancyss_restart_websocketd.sh"
	cat > "${helper}" <<-'EOF'
		#!/bin/sh
		WS_PIDFILE="/var/run/fancyss-websocketd.pid"
		SSD=""
		for candidate in /sbin/start-stop-daemon /usr/sbin/start-stop-daemon /bin/start-stop-daemon /usr/bin/start-stop-daemon
		do
			[ -x "${candidate}" ] || continue
			SSD="${candidate}"
			break
		done
		sleep 2
		if [ -f "${WS_PIDFILE}" ]; then
			if [ -n "${SSD}" ]; then
				"${SSD}" -K -q -p "${WS_PIDFILE}" >/dev/null 2>&1 || true
			fi
			pid="$(cat "${WS_PIDFILE}" 2>/dev/null)"
			if [ -n "${pid}" ]; then
				kill "${pid}" >/dev/null 2>&1 || true
				sleep 1
				kill -9 "${pid}" >/dev/null 2>&1 || true
			fi
		fi
		killall websocketd >/dev/null 2>&1 || true
		ps w | grep -F "/koolshare/ss/websocket" | grep -v grep | awk '{print $1}' | while read -r pid
		do
			[ -n "${pid}" ] || continue
			kill "${pid}" >/dev/null 2>&1 || true
			sleep 1
			kill -9 "${pid}" >/dev/null 2>&1 || true
		done
		rm -f "${WS_PIDFILE}" >/dev/null 2>&1 || true
		if [ -x "/koolshare/bin/websocketd" ] && [ -f "/koolshare/ss/websocket" ]; then
			if [ -n "${SSD}" ]; then
				"${SSD}" -S -q -b -m -p "${WS_PIDFILE}" -x /koolshare/bin/websocketd -- --port=803 /koolshare/ss/websocket >/tmp/upload/websocketd.log 2>&1
			else
				/koolshare/bin/websocketd --port=803 /koolshare/ss/websocket >/tmp/upload/websocketd.log 2>&1 &
				echo $! > "${WS_PIDFILE}"
			fi
		fi
		rm -f /tmp/fancyss_websocketd_changed >/dev/null 2>&1 || true
		rm -f "$0" >/dev/null 2>&1
	EOF
	chmod +x "${helper}" >/dev/null 2>&1
	sh "${helper}" >/dev/null 2>&1 &
}

schedule_websocketd_after_self_update() {
	local helper="/tmp/fancyss_self_update_websocketd_restart.sh"
	cat > "${helper}" <<-'EOF'
		#!/bin/sh
		WS_PIDFILE="/var/run/fancyss-websocketd.pid"
		SSD=""
		for candidate in /sbin/start-stop-daemon /usr/sbin/start-stop-daemon /bin/start-stop-daemon /usr/bin/start-stop-daemon
		do
			[ -x "${candidate}" ] || continue
			SSD="${candidate}"
			break
		done
		waited=0
		while [ "${waited}" -lt 120 ]
		do
			grep -q "XU6J03M6" /tmp/upload/ss_log.txt 2>/dev/null && break
			sleep 1
			waited=$((waited + 1))
		done
		sleep 3
		if [ -x "/tmp/fancyss_deferred_websocketd/websocketd" ]; then
			tmp_ws="/koolshare/bin/websocketd.fancyss-new.$$"
			if cp -f /tmp/fancyss_deferred_websocketd/websocketd "${tmp_ws}" >/dev/null 2>&1; then
				chmod 755 "${tmp_ws}" >/dev/null 2>&1 || true
				mv -f "${tmp_ws}" /koolshare/bin/websocketd >/dev/null 2>&1 || rm -f "${tmp_ws}" >/dev/null 2>&1 || true
			fi
			rm -rf /tmp/fancyss_deferred_websocketd >/dev/null 2>&1 || true
		fi
		if [ -f "${WS_PIDFILE}" ]; then
			if [ -n "${SSD}" ]; then
				"${SSD}" -K -q -p "${WS_PIDFILE}" >/dev/null 2>&1 || true
			fi
			pid="$(cat "${WS_PIDFILE}" 2>/dev/null)"
			if [ -n "${pid}" ]; then
				kill "${pid}" >/dev/null 2>&1 || true
				sleep 1
				kill -9 "${pid}" >/dev/null 2>&1 || true
			fi
		fi
		killall websocketd >/dev/null 2>&1 || true
		ps w | grep -F "/koolshare/ss/websocket" | grep -v grep | awk '{print $1}' | while read -r pid
		do
			[ -n "${pid}" ] || continue
			kill "${pid}" >/dev/null 2>&1 || true
			sleep 1
			kill -9 "${pid}" >/dev/null 2>&1 || true
		done
		rm -f "${WS_PIDFILE}" /tmp/fancyss_self_update_installing /tmp/fancyss_pending_websocketd_restart >/dev/null 2>&1 || true
		if [ -x "/koolshare/bin/websocketd" ] && [ -f "/koolshare/ss/websocket" ]; then
			if [ -n "${SSD}" ]; then
				"${SSD}" -S -q -b -m -p "${WS_PIDFILE}" -x /koolshare/bin/websocketd -- --port=803 /koolshare/ss/websocket >/tmp/upload/websocketd.log 2>&1
			else
				/koolshare/bin/websocketd --port=803 /koolshare/ss/websocket >/tmp/upload/websocketd.log 2>&1 &
				echo $! > "${WS_PIDFILE}"
			fi
		fi
		rm -f /tmp/fancyss_websocketd_changed >/dev/null 2>&1 || true
		rm -f "$0" >/dev/null 2>&1
	EOF
	chmod +x "${helper}" >/dev/null 2>&1
	date +%s 2>/dev/null > /tmp/fancyss_pending_websocketd_restart
	sh "${helper}" >/dev/null 2>&1 &
}

handle_websocketd_after_install() {
	if [ ! -f "/tmp/fancyss_websocketd_changed" ]; then
		return 0
	fi
	if is_fancyss_self_update_install; then
		if [ -x "/tmp/fancyss_deferred_websocketd/websocketd" ]; then
			echo_date "检测到 fancyss 自更新场景，延后静默切换 websocketd，避免中断当前 WebSocket 日志。"
			schedule_websocketd_after_self_update
		else
			echo_date "检测到 fancyss 自更新场景，本次无需切换 websocketd。"
		fi
		return 0
	fi
	if is_softcenter_offline_install; then
		echo_date "检测到软件中心离线安装场景，安装完成后拉起新的 websocketd。"
	else
		echo_date "websocketd 已变化，安装完成后拉起新的 websocketd。"
	fi
	restart_websocketd_async
}

defer_websocketd_binary_for_self_update() {
	[ -f "/tmp/shadowsocks/bin/websocketd" ] || return 0
	mkdir -p /tmp/fancyss_deferred_websocketd >/dev/null 2>&1 || return 0
	cp -f /tmp/shadowsocks/bin/websocketd /tmp/fancyss_deferred_websocketd/websocketd >/dev/null 2>&1 || return 0
	chmod 755 /tmp/fancyss_deferred_websocketd/websocketd >/dev/null 2>&1 || true
	rm -f /tmp/shadowsocks/bin/websocketd >/dev/null 2>&1 || true
	echo_date "自更新日志通道仍由当前 websocketd 承载，新 websocketd 将在日志结束后静默替换。"
}

restart_status_runtime_async() {
	local helper="/tmp/fancyss_restart_status_runtime.sh"
	cat > "${helper}" <<-'EOF'
		#!/bin/sh
		LOG_FILE="/tmp/upload/status-runtime-helper.log"
		log_status_runtime() {
			mkdir -p /tmp/upload
			printf '【%s】: %s\n' "$(TZ=UTC-8 date -R "+%Y%m%d %X")" "$*" >> "${LOG_FILE}" 2>/dev/null
		}
		start_status_serve_direct() {
			[ -x "/koolshare/bin/status-tool" ] || return 1
			chn="$(dbus get ss_basic_curl)"
			frn="$(dbus get ss_basic_furl)"
			ipv6="$(dbus get ss_basic_proxy_ipv6)"
			[ -n "${chn}" ] || chn="http://connectivitycheck.platform.hicloud.com/generate_204"
			[ -n "${frn}" ] || frn="http://www.google.com/generate_204"
			ps w | grep -E '(^| )/koolshare/bin/status-tool serve( |$)' | grep -v grep | while read -r pid rest
			do
				[ -n "${pid}" ] && kill "${pid}" >/dev/null 2>&1 || true
			done
			rm -f /tmp/status-tool.sock /var/run/status-tool-serve.pid >/dev/null 2>&1
			log_status_runtime "starting status-tool serve"
			env -i PATH="/koolshare/bin:/usr/sbin:/usr/bin:/sbin:/bin" /koolshare/bin/status-tool serve \
				--socket-path /tmp/status-tool.sock \
				--china-url "${chn}" \
				--foreign-url "${frn}" \
				--proxy-ipv6 "${ipv6:-0}" \
				--foreign-proxy "socks5://127.0.0.1:23456" \
				--state-file /tmp/upload/ss_status_daemon.json \
				--legacy-file /tmp/upload/ss_status_front.txt >/tmp/upload/status-tool-serve.log 2>&1 &
			echo "$!" >/var/run/status-tool-serve.pid
			sleep 1
			if [ -S /tmp/status-tool.sock ] && ps w | grep -E '(^| )/koolshare/bin/status-tool serve( |$)' | grep -v grep >/dev/null 2>&1; then
				log_status_runtime "status-tool serve started"
			else
				log_status_runtime "status-tool serve did not stay alive"
			fi
		}
		status_serve_alive() {
			[ -S /tmp/status-tool.sock ] && ps w | grep -E '(^| )/koolshare/bin/status-tool serve( |$)' | grep -v grep >/dev/null 2>&1
		}
		should_start_status_serve() {
			[ "$(dbus get ss_basic_enable)" = "1" ] || return 1
			[ "$(dbus get ss_failover_enable)" != "1" ] || return 1
			[ "$(dbus get ss_basic_status_mode)" = "serve" ]
		}
		wait_status_preready() {
			local waited=0
			while ps w | grep -F "/koolshare/ss/ssconfig.sh" | grep -v grep >/dev/null 2>&1
			do
				[ "${waited}" -ge 20 ] && break
				sleep 1
				waited=$((waited + 1))
			done
			waited=0
			# FORK doge.10: removed naive|tuic|rss-local from socks5 readiness regex, see doc/design/protocol-roadmap.md §2
			while ! netstat -nlp 2>/dev/null | grep -w "23456" | grep -Eq "xray|v2ray|anytls-zig"
			do
				[ "${waited}" -ge 15 ] && break
				sleep 1
				waited=$((waited + 1))
			done
		}
		sleep 2
		log_status_runtime "checking status runtime"
		should_start_status_serve && wait_status_preready && start_status_serve_direct
		sleep 3
		if should_start_status_serve && ! status_serve_alive; then
			log_status_runtime "status runtime missing, retry"
			wait_status_preready
			start_status_serve_direct
		fi
		rm -f "$0" >/dev/null 2>&1
	EOF
	chmod +x "${helper}" >/dev/null 2>&1
	sh "${helper}" >/dev/null 2>&1 &
}

report_install_migration_progress() {
	echo_date "$1"
}

# 一次性迁移：把旧版本的故障转移字段（ss_failover_s4_2/s4_3、fss_node_failover_*）
# 转换为新的备用组合列表（ss_failover_combo_*），然后清理旧字段并打迁移标记。
# 依赖：fss_node_id_exists、fss_get_node_identity_by_id（来自 ss_node_common.sh，install.sh 顶部已 source）
# 触发条件：fss_failover_migrated_v1 != "1"。幂等。
migrate_failover_v1(){
	local migrated_flag legacy_s4_3 legacy_backup legacy_identity new_count
	local target_id="" target_identity=""

	migrated_flag="$(dbus get fss_failover_migrated_v1)"
	if [ "${migrated_flag}" = "1" ]; then
		return 0
	fi

	legacy_s4_3="$(dbus get ss_failover_s4_3)"
	legacy_backup="$(dbus get fss_node_failover_backup)"
	legacy_identity="$(dbus get fss_node_failover_identity)"
	# 兼容历史 dbus key：旧 fork 版本曾用 fss_failover_combo_count，已被 v2 迁移到 ss_failover_combo_count；
	# 这里两个 key 都查一下，取较大值，防止 v1 在 v2 之前/之后跑都能正确判断"已配置过 combo"。
	new_count="$(dbus get ss_failover_combo_count)"
	case "${new_count}" in
		''|*[!0-9]*) new_count=0 ;;
	esac
	local legacy_combo_count="$(dbus get fss_failover_combo_count)"
	case "${legacy_combo_count}" in
		''|*[!0-9]*) legacy_combo_count=0 ;;
	esac
	if [ "${legacy_combo_count}" -gt "${new_count}" ] 2>/dev/null; then
		new_count="${legacy_combo_count}"
	fi

	# 已经在新版本配置过 combo → 跳过迁移内容，仅清理旧字段
	if [ "${new_count}" -ge 1 ] 2>/dev/null; then
		echo_date "故障转移：检测到已有 ${new_count} 个备用组合，跳过旧字段迁移内容，仅清理废弃 keys。"
	else
		# 选定迁移源 id：优先 fss_node_failover_backup（identity 化更稳），再退到 ss_failover_s4_3
		if [ -n "${legacy_backup}" ] && [ "${legacy_backup}" != "0" ]; then
			if fss_node_id_exists "${legacy_backup}" >/dev/null 2>&1; then
				target_id="${legacy_backup}"
				target_identity="${legacy_identity}"
			fi
		fi
		if [ -z "${target_id}" ] && [ -n "${legacy_s4_3}" ] && [ "${legacy_s4_3}" != "0" ]; then
			if fss_node_id_exists "${legacy_s4_3}" >/dev/null 2>&1; then
				target_id="${legacy_s4_3}"
			fi
		fi

		if [ -n "${target_id}" ]; then
			# identity 字段：拿不到就保持空，新版本 resolve 时会回退到 raw id
			if [ -z "${target_identity}" ]; then
				target_identity="$(fss_get_node_identity_by_id "${target_id}" 2>/dev/null)"
			fi
			# 直接写新前缀（ss_*）；不需要再过 v2 转换。
			dbus set ss_failover_combo_count="1"
			dbus set ss_failover_combo_1_front_id=""
			dbus set ss_failover_combo_1_front_identity=""
			dbus set ss_failover_combo_1_landing_id="${target_id}"
			dbus set ss_failover_combo_1_landing_identity="${target_identity}"
			dbus set ss_failover_combo_1_failed="0"
			echo_date "故障转移：已把旧备用节点（id=${target_id}）迁移为备用组合 #1（直连模式）。"
		else
			echo_date "故障转移：未发现可迁移的旧备用节点，跳过 combo 创建。"
		fi
	fi

	# 清理旧字段（无论本次是否创建 combo）
	dbus remove ss_failover_s4_2 >/dev/null 2>&1
	dbus remove ss_failover_s4_3 >/dev/null 2>&1
	dbus remove fss_node_failover_backup >/dev/null 2>&1
	dbus remove fss_node_failover_identity >/dev/null 2>&1
	dbus set fss_failover_migrated_v1="1"
	echo_date "故障转移：旧字段迁移完成（fss_failover_migrated_v1=1）。"
}

# 一次性迁移 v2：把 fork 旧版本的 fss_failover_combo_* / fss_failover_main_combo_seeded
# 重命名为 ss_failover_combo_* / ss_failover_main_combo_seeded（前缀必须 ss_*
# 才能被 koolshare /_api/ss 暴露给前端 db_ss，详见 CLAUDE.md 硬规则 #1）。
# 触发条件：ss_failover_combo_migrated_v2 != "1"。幂等。
# 顺序：在 install_now 中紧跟 migrate_failover_v1 之后调用——v1 现在直接写 ss_*，
# v2 仅处理"用户已经在旧 fork 版本上手动配过 combo"留下的 fss_* 残留。
migrate_failover_v2(){
	local migrated_flag key value newkey
	migrated_flag="$(dbus get ss_failover_combo_migrated_v2)"
	if [ "${migrated_flag}" = "1" ]; then
		return 0
	fi

	# 1. fss_failover_combo_*  →  ss_failover_combo_*
	dbus list fss_failover_combo_ 2>/dev/null | while IFS= read -r line
	do
		[ -z "${line}" ] && continue
		key="${line%%=*}"
		value="${line#*=}"
		newkey="ss_${key#fss_}"
		dbus set "${newkey}"="${value}"
		dbus remove "${key}" >/dev/null 2>&1
	done

	# 2. fss_failover_main_combo_seeded → ss_failover_main_combo_seeded
	local legacy_seeded
	legacy_seeded="$(dbus get fss_failover_main_combo_seeded)"
	if [ -n "${legacy_seeded}" ]; then
		dbus set ss_failover_main_combo_seeded="${legacy_seeded}"
		dbus remove fss_failover_main_combo_seeded >/dev/null 2>&1
	fi

	dbus set ss_failover_combo_migrated_v2="1"
	echo_date "故障转移：combo 前缀迁移 v2 完成（fss_failover_combo_* → ss_failover_combo_*）。"
}

# ============================================================================
# FORK doge.12 alpha: 分流架构（Rule + Mode + per-User + 双轨 DNS）一次性迁移。
# 详见 doc/design/split-routing-architecture.md §14 + doc/implementation/split-routing-implementation.md。
# 触发条件：fss_split_migrated_v1 != "1"。幂等。
# alpha 阶段 NOT 物理删除任何旧 key（ss_node_shunt_* / ss_basic_mode / ss_acl_mode_<i> 全保留），
# NOT 销毁旧 ipset（旧路径仍在用），仅写入新 key + 内置 Rule 文件。
# 总开关 ss_split_enabled 默认 0，路由层走旧逻辑——老用户升级零感知。
# ============================================================================

# helper: 写入单个内置 Rule（rule_<id>.txt 头注释 + dbus 元数据）
# 调用：write_builtin_rule_meta <id> <name> <source_url> <update_hours> <stat_domains> <stat_ips>
write_builtin_rule_meta(){
	local rid="$1" rname="$2" surl="$3" uhours="$4" sdom="$5" sips="$6"
	local now_ts="$(date +%s)"
	dbus set ss_split_rule_${rid}_id="${rid}"
	dbus set ss_split_rule_${rid}_name="${rname}"
	dbus set ss_split_rule_${rid}_builtin="1"
	dbus set ss_split_rule_${rid}_source_url="${surl}"
	dbus set ss_split_rule_${rid}_update_hours="${uhours}"
	dbus set ss_split_rule_${rid}_last_update="${now_ts}"
	dbus set ss_split_rule_${rid}_stat_domains="${sdom}"
	dbus set ss_split_rule_${rid}_stat_ips="${sips}"
}

# helper: 给 rule_<id>.txt 顶部加 4 行头注释（覆盖式写入）
# 调用：write_rule_header <id> <name>
write_rule_header(){
	local rid="$1" rname="$2"
	local rfile="/koolshare/ss/rules_user/rule_${rid}.txt"
	{
		echo "# fancyss-rule v1"
		echo "# id: ${rid}"
		echo "# name: ${rname}"
		echo "# updated: $(date -Iseconds 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
	} > "${rfile}"
}

# helper: 统计 rule 文件的 domain / ip 行数（跳过头注释 / 空行）
# 输出：echo "<domains> <ips>"
# fork (doge.12-alpha.3 hotfix)：原版 while-read + echo|grep 在 chnlist.gz 解压后约 7 万行的输入上
# 要 fork 14 万次子进程，AX86U 上估算 9-15 分钟，用户看到的"卡在 Rule 1: 大陆白名单_常用"
# 就是这条热循环（alpha.2 用户报）。改 awk 单次扫描，几十毫秒完事。
count_rule_entries(){
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

# helper: 创建 rules_user 目录
seed_rules_user_dir(){
	mkdir -p /koolshare/ss/rules_user 2>/dev/null
	chmod 755 /koolshare/ss/rules_user 2>/dev/null
}

# helper: 写入单个内置 Mode 元数据（不含 rules 数组，rules 由调用方逐条 set）
# 调用：write_builtin_mode_meta <id> <name> <udp_proxy> <block_quic> <dns_mode> <default_action>
write_builtin_mode_meta(){
	local mid="$1" mname="$2" mudp="$3" mquic="$4" mdns="$5" mdef="$6"
	dbus set ss_split_mode_${mid}_id="${mid}"
	dbus set ss_split_mode_${mid}_name="${mname}"
	dbus set ss_split_mode_${mid}_builtin="1"
	dbus set ss_split_mode_${mid}_udp_proxy="${mudp}"
	dbus set ss_split_mode_${mid}_block_quic="${mquic}"
	dbus set ss_split_mode_${mid}_apply_blackwhite="1"
	dbus set ss_split_mode_${mid}_dns_mode="${mdns}"
	dbus set ss_split_mode_${mid}_default_action="${mdef}"
}

# helper: 给 Mode <mid> 追加一条 rule 引用（顺序敏感）
# 调用：add_mode_rule <mid> <rule_seq> <rid> <action>
add_mode_rule(){
	local mid="$1" rseq="$2" rid="$3" raction="$4"
	dbus set ss_split_mode_${mid}_rule_${rseq}_rid="${rid}"
	dbus set ss_split_mode_${mid}_rule_${rseq}_action="${raction}"
}

migrate_split_routing_v1(){
	local migrated_flag
	migrated_flag="$(dbus get fss_split_migrated_v1)"
	if [ "${migrated_flag}" = "1" ]; then
		# alpha.12: marker=1 不保证 rule_*.txt 文件存在——某些升级路径下文件被吃掉
		# （alpha.8 仅修了目录丢失，没管文件本身）。健康检查：枚举内置 Rule 1~8 全集，
		# 缺一即触发自愈 reseed。
		# alpha.17 修：原版本只查 rule_1/rule_2，rule_3~8 缺失时假装健康——用户报告
		# Rule 4/5 等小文件被吃掉时无法自动恢复。改为枚举 1~8。
		# 详见 doc/implementation/split-routing-implementation.md §6 D7 同形漏修补丁
		__need_reseed=0
		for __r in 1 2 3 4 5 6 7 8; do
			[ ! -s "/koolshare/ss/rules_user/rule_${__r}.txt" ] && __need_reseed=1
		done
		unset __r
		if [ "${__need_reseed}" = "1" ]; then
			echo_date "⚠️ FORK doge.12 alpha: 迁移 marker=1 但内置 Rule 源文件缺失，触发自愈 reseed"
			if [ -f /koolshare/scripts/ss_split_rule_seed.sh ]; then
				. /koolshare/scripts/ss_split_rule_seed.sh
				if type fancyss_split_seed_rule_files_v1 >/dev/null 2>&1; then
					fancyss_split_seed_rule_files_v1
				else
					echo_date "❌ split-seed: helper 已 source 但 function 不存在，跳过自愈"
				fi
			else
				echo_date "❌ split-seed: /koolshare/scripts/ss_split_rule_seed.sh 不存在，跳过自愈"
			fi
		fi
		unset __need_reseed
		return 0
	fi

	echo_date "🔄 FORK doge.12 alpha: 开始迁移到分流架构 v1（仅写数据，不接管路由）..."

	# ---------- Step 0: 准备目录 ----------
	seed_rules_user_dir

	# ---------- Step 1: 写入内置 Rule (id 1~8) ----------
	# alpha.12: Step 1 的文件构建 + dbus 元数据写入抽到 helper（ss_split_rule_seed.sh），
	# 让 ssconfig.sh 也能在 generate_xray_json_split 入口做 hot reseed。
	# helper 自带"name/source_url/update_hours 缺失才写默认"的自愈保护——这里首次迁移
	# 所有 key 都不存在，所以全部写入默认值；自愈调用时则保留用户已改的元数据。
	if [ -f /koolshare/scripts/ss_split_rule_seed.sh ]; then
		. /koolshare/scripts/ss_split_rule_seed.sh
		fancyss_split_seed_rule_files_v1
	else
		echo_date "❌ split-seed: helper 缺失，无法 seed 内置 Rule"
	fi

	dbus set ss_split_rule_count="8"

	# ---------- Step 1.5: 用 proxy_main sentinel（D12+D15 doge.13 兑现）----------
	# 内置 Mode 的 default_action 与 telegram/gfwlist rule action 一律写 sentinel，
	# xray 生成器在 ss_split_action_to_tag 中解析 → out_main（基线 outbounds[0]），
	# 主节点变更自然跟随，无需 resync hook。空 ssconf_basic_node 时仍然 valid：
	# 此时 out_main 是 creat_*_json 的空兜底 outbound，xray 启动可能失败，
	# 属"用户必须先配节点"的语义，不归 install.sh 管。
	local cur_udp cur_action
	cur_udp="$(dbus get ss_basic_udp_relay)"
	[ -z "${cur_udp}" ] && cur_udp="0"
	cur_action="proxy_main"
	echo_date "  当前节点动作字符串：${cur_action}（udp_proxy=${cur_udp}）"

	# ---------- Step 2: 写入内置 Mode（id 1~99 预留） ----------
	# Mode 1 = 全局代理 (dns_mode=global, rules=[], default_action=cur_action)
	echo_date "  内置 Mode 1: 全局代理（dns_mode=global）"
	write_builtin_mode_meta 1 "全局代理" "${cur_udp}" 0 "global" "${cur_action}"
	dbus set ss_split_mode_1_rule_count="0"

	# Mode 2 = 大陆白名单 (dns_mode=split, 按合同 §2.2 顺序 7 条 rules, default_action=cur_action)
	# 顺序：Rule 3 (chndns) → direct
	#       Rule 4 (adblock) → reject
	#       Rule 6 (online_ipcheck) → direct
	#       Rule 7 (查IP) → direct
	#       Rule 5 (telegram) → cur_action
	#       Rule 2 (gfwlist) → cur_action
	#       Rule 1 (chnlist) → direct
	echo_date "  内置 Mode 2: 大陆白名单（dns_mode=split, 7 条规则）"
	write_builtin_mode_meta 2 "大陆白名单" "${cur_udp}" 0 "split" "${cur_action}"
	add_mode_rule 2 1 3 "direct"
	add_mode_rule 2 2 4 "reject"
	add_mode_rule 2 3 6 "direct"
	add_mode_rule 2 4 7 "direct"
	add_mode_rule 2 5 5 "${cur_action}"
	add_mode_rule 2 6 2 "${cur_action}"
	add_mode_rule 2 7 1 "direct"
	dbus set ss_split_mode_2_rule_count="7"

	dbus set ss_split_mode_count="2"

	# ---------- Step 3: 迁移当前 ss_basic_mode → ss_split_default_mode_id ----------
	local old_mode
	old_mode="$(dbus get ss_basic_mode)"
	case "${old_mode}" in
		5)
			dbus set ss_split_default_mode_id="1"
			echo_date "  ss_basic_mode=5 (全局) → ss_split_default_mode_id=1 (全局代理)"
			;;
		*)
			dbus set ss_split_default_mode_id="2"
			echo_date "  ss_basic_mode=${old_mode:-未设置} → ss_split_default_mode_id=2 (大陆白名单)"
			;;
	esac

	# ---------- Step 4: 迁移 acl 行 → ss_acl_split_mode_<i> ----------
	local acl_indexes acl old_acl_mode
	acl_indexes="$(dbus list ss_acl_mode_ 2>/dev/null | cut -d '=' -f 1 | cut -d '_' -f 4 | sort -n)"
	for acl in ${acl_indexes}; do
		[ -z "${acl}" ] && continue
		old_acl_mode="$(dbus get ss_acl_mode_${acl})"
		case "${old_acl_mode}" in
			0)
				dbus set ss_acl_split_mode_${acl}="0"
				;;
			5)
				dbus set ss_acl_split_mode_${acl}="1"
				;;
			*)
				dbus set ss_acl_split_mode_${acl}="2"
				;;
		esac
	done

	# ---------- Step 5: 黑白名单文本框保留 ----------
	# ss_wan_white_domain / ss_wan_black_domain 不动，两个内置 Mode 默认 apply_blackwhite=1。

	# ---------- Step 6/7: alpha 阶段 NOT 物理删除任何旧 key ----------
	# ss_node_shunt_* / ss_basic_mode / ss_acl_mode_<i> / failover-combo 全保留——旧路径仍在用。
	# 待 alpha 充分验证后由 doge.13+ 处理。

	# ---------- Step 7.5: 销毁旧 ipset（alpha 跳过） ----------
	# 跳过原因：alpha 阶段 ss_split_enabled 默认 0，路由层走旧路径，旧 ipset (chnlist/gfwlist/white_list 等)
	# 仍由 ssconfig.sh 创建并使用。本步骤待 doge.13 默认 ss_split_enabled=1 时再启用。

	# ---------- Step 9: 落幂等标志 ----------
	dbus set fss_split_migrated_v1="1"
	echo_date "✅ FORK doge.12 alpha: 分流架构迁移完成（fss_split_migrated_v1=1，ss_split_enabled 默认 0 不接管路由）"
}

# FORK doge.13 beta：DNS upstream 迁移 v2（D1 兑现）
# 把老 dbus key（ss_basic_chng_china_dns_<n>_chk + ss_basic_chng_china_net_<n>_typ
# + ss_basic_chng_china_<net>_<n>_opt/_usr）拼成新 key:
#   ss_split_dns_china_upstream    多行（每行一条 china_dns 端点，base64 编码后落 dbus）
#   ss_split_dns_overseas_upstream 多行（每行一条 trust_dns  端点，base64 编码后落 dbus）
#   ss_split_dns_global_upstream   单行（取 trust_dns_1 端点，base64 编码后落 dbus）
# 简化策略：不引 get_dns 链（依赖太多），直接拼 <scheme>://<host>:
#   net=udp → 无 scheme 前缀（裸 ip[:port]）
#   net=tcp → "tcp://"
#   net=dot → "tls://"（chinadns-ng 规范名）
#   opt=99 → 取 _usr 字段；否则取 _opt 字段
# 不删老 key（alpha/老 chinadns-ng 仍在用），仅前向加新 key。
# 失败时不 fail install：标 fss_split_migrated_v2=0 等下次重试；成功路径才置 1。
migrate_split_routing_v2(){
	local migrated_flag
	migrated_flag="$(dbus get fss_split_migrated_v2)"
	if [ "${migrated_flag}" = "1" ]; then
		return 0
	fi

	echo_date "🔄 FORK doge.13 beta: 开始迁移 DNS upstream 到分流架构 v2..."

	local n typ opt usr ep raw_china raw_overseas raw_global
	raw_china=""
	raw_overseas=""
	raw_global=""

	# ---- 国内 DNS：china_dns_1/2/3 ----
	for n in 1 2 3; do
		[ "$(dbus get ss_basic_chng_china_dns_${n}_chk)" = "1" ] || continue
		typ="$(dbus get ss_basic_chng_china_net_${n}_typ)"
		[ -z "${typ}" ] && typ="udp"
		opt="$(dbus get ss_basic_chng_china_${typ}_${n}_opt)"
		usr="$(dbus get ss_basic_chng_china_${typ}_${n}_usr)"
		if [ "${opt}" = "99" ]; then
			ep="${usr}"
		else
			ep="${opt}"
		fi
		[ -z "${ep}" ] && continue
		case "${typ}" in
			tcp) ep="tcp://${ep}" ;;
			dot) ep="tls://${ep}" ;;
		esac
		raw_china="${raw_china}${ep}
"
	done

	# ---- 国外 DNS：trust_dns_1/2/3 ----
	for n in 1 2 3; do
		[ "$(dbus get ss_basic_chng_trust_dns_${n}_chk)" = "1" ] || continue
		typ="$(dbus get ss_basic_chng_trust_net_${n}_typ)"
		[ -z "${typ}" ] && typ="udp"
		opt="$(dbus get ss_basic_chng_trust_${typ}_${n}_opt)"
		usr="$(dbus get ss_basic_chng_trust_${typ}_${n}_usr)"
		if [ "${opt}" = "99" ]; then
			ep="${usr}"
		else
			ep="${opt}"
		fi
		[ -z "${ep}" ] && continue
		case "${typ}" in
			tcp) ep="tcp://${ep}" ;;
			dot) ep="tls://${ep}" ;;
		esac
		raw_overseas="${raw_overseas}${ep}
"
	done

	# ---- 全局 DNS：取 trust_dns_1 单行 ----
	typ="$(dbus get ss_basic_chng_trust_net_1_typ)"
	[ -z "${typ}" ] && typ="udp"
	opt="$(dbus get ss_basic_chng_trust_${typ}_1_opt)"
	usr="$(dbus get ss_basic_chng_trust_${typ}_1_usr)"
	if [ "${opt}" = "99" ]; then
		ep="${usr}"
	else
		ep="${opt}"
	fi
	if [ -n "${ep}" ]; then
		case "${typ}" in
			tcp) raw_global="tcp://${ep}" ;;
			dot) raw_global="tls://${ep}" ;;
			*)   raw_global="${ep}" ;;
		esac
	fi

	# ---- base64 编码并写入新 dbus key ----
	# FORK doge.13 beta.2: base64_encode 二进制周期性追加 TAB (0x09) 而非 LF——输入长度 %9 ∈ {7,8,9} 时追 TAB
	# 末尾 TAB 不被 $(...) 剥（POSIX 仅剥 trailing \n），落 dbus 后污染 /_api/ss JSON（httpdb 不 escape 控制字符）
	# → 前端 JSON.parse 抛 SyntaxError → ajax error → skipd 弹窗。详见 [[reference_busybox_base64_loop]]
	# 必须用 `tr -d '\t\n\r '` 显式字符列——busybox 1.25.1 tr 不支持 POSIX 字符类 [:space:]（reviewer B 真机实证）
	local enc_china enc_overseas enc_global
	enc_china="$(printf '%s' "${raw_china}" | base64_encode 2>/dev/null | tr -d '\t\n\r ')"
	enc_overseas="$(printf '%s' "${raw_overseas}" | base64_encode 2>/dev/null | tr -d '\t\n\r ')"
	enc_global="$(printf '%s' "${raw_global}" | base64_encode 2>/dev/null | tr -d '\t\n\r ')"

	if [ -z "${enc_china}" ] && [ -z "${enc_overseas}" ] && [ -z "${enc_global}" ]; then
		echo_date "⚠️ FORK doge.13 beta: DNS upstream 迁移 v2 失败（base64_encode 不可用？），延迟到下次 install 重试"
		dbus set fss_split_migrated_v2="0"
		return 0
	fi

	dbus set ss_split_dns_china_upstream="${enc_china}"
	dbus set ss_split_dns_overseas_upstream="${enc_overseas}"
	dbus set ss_split_dns_global_upstream="${enc_global}"

	dbus set fss_split_migrated_v2="1"
	echo_date "✅ FORK doge.13 beta: DNS upstream 迁移 v2 完成（fss_split_migrated_v2=1）"
}

# FORK doge.13 beta.2: 一次性治存量——清洗 ss_split_dns_*_upstream 三个 key 末尾的 TAB/CR/空白
# beta.1 的 migrate_v2 漏 tr -d → 概率性把 TAB 写进 dbus → /_api/ss JSON 含未转义控制字符
# → 前端 JSON.parse 抛 SyntaxError → ajax error → 弹 skipd 弹窗。详见 [[reference_busybox_base64_loop]]
# 守门 fss_split_migrated_v3，幂等；仅 dbus set，不重启代理（值变化端到端自然下次启动生效）
migrate_split_routing_v3(){
	local migrated_flag
	migrated_flag="$(dbus get fss_split_migrated_v3)"
	if [ "${migrated_flag}" = "1" ]; then
		return 0
	fi

	local key val cleaned fixed_count
	fixed_count=0
	for key in ss_split_dns_china_upstream ss_split_dns_overseas_upstream ss_split_dns_global_upstream; do
		val="$(dbus get "${key}")"
		[ -n "${val}" ] || continue
		cleaned="$(printf '%s' "${val}" | tr -d '\t\n\r ')"
		if [ "${cleaned}" != "${val}" ]; then
			dbus set "${key}"="${cleaned}"
			fixed_count=$((fixed_count + 1))
		fi
	done

	dbus set fss_split_migrated_v3="1"
	if [ "${fixed_count}" -gt 0 ]; then
		echo_date "✅ FORK doge.13 beta.2: 清洗 ${fixed_count} 个 ss_split_dns_*_upstream key 中的控制字符（修 skipd 弹窗）"
	else
		echo_date "✅ FORK doge.13 beta.2: ss_split_dns_*_upstream 已干净，无需清洗（fss_split_migrated_v3=1）"
	fi
}

# FORK doge.10: 主动删除 dbus 里所有 type=1 (SSR) / type=6 (Naive) / type=7 (Tuic) 的节点 + 清理引用。
# 详见 doc/design/protocol-roadmap.md §2。后端专用迁移旗标走 fss_* 前缀（CLAUDE.md 硬规则 #1）。
# 触发条件：fss_doge10_legacy_protocols_migrated != "1"。幂等。
# 依赖：fss_b64_decode（ss_node_common.sh）+ jq。
migrate_doge10_drop_legacy_protocols(){
	local migrated_flag order csv_in id blob node_json node_type
	local ssr_count=0 naive_count=0 tuic_count=0 total_dropped=0
	local kept_ids="" dropped_ids=""
	local current_id current_dropped=0
	local front_id front_dropped=0
	local total i landing_id landing_dropped front_id_combo combo_changes=0
	local drop_combo_list=""

	migrated_flag="$(dbus get fss_doge10_legacy_protocols_migrated)"
	if [ "${migrated_flag}" = "1" ]; then
		return 0
	fi

	order="$(dbus get fss_node_order)"
	if [ -z "${order}" ]; then
		# 还没有节点数据 → 直接落旗标退出（避免下次重复扫描）
		dbus set fss_doge10_legacy_protocols_migrated="1"
		return 0
	fi

	# 1. 遍历 fss_node_order，识别 type=1/6/7 节点
	csv_in="$(printf '%s' "${order}" | tr ',' ' ')"
	for id in ${csv_in}
	do
		[ -n "${id}" ] || continue
		blob="$(dbus get "fss_node_${id}")"
		if [ -z "${blob}" ]; then
			# blob 不存在 → 保留 id（防误删；上游负责清理）
			kept_ids="${kept_ids}${kept_ids:+,}${id}"
			continue
		fi
		node_json="$(fss_b64_decode "${blob}" 2>/dev/null)"
		if [ -z "${node_json}" ]; then
			# 解码失败 → 保留 id（防误删）
			kept_ids="${kept_ids}${kept_ids:+,}${id}"
			continue
		fi
		node_type="$(printf '%s' "${node_json}" | jq -r '(.type // "") | tostring' 2>/dev/null)"
		case "${node_type}" in
			1) ssr_count=$((ssr_count + 1)); dropped_ids="${dropped_ids}${dropped_ids:+ }${id}" ;;
			6) naive_count=$((naive_count + 1)); dropped_ids="${dropped_ids}${dropped_ids:+ }${id}" ;;
			7) tuic_count=$((tuic_count + 1)); dropped_ids="${dropped_ids}${dropped_ids:+ }${id}" ;;
			*) kept_ids="${kept_ids}${kept_ids:+,}${id}" ;;
		esac
	done

	total_dropped=$((ssr_count + naive_count + tuic_count))
	if [ "${total_dropped}" = "0" ]; then
		echo_date "[doge.10 migrate] 无遗留 SSR/Naive/Tuic 节点需要删除。"
		dbus set fss_doge10_legacy_protocols_migrated="1"
		return 0
	fi

	# 2. 物理删除节点 blob
	for id in ${dropped_ids}
	do
		dbus remove "fss_node_${id}" >/dev/null 2>&1
	done

	# 3. 重写 fss_node_order（kept_ids 已按原顺序拼接）
	if [ -n "${kept_ids}" ]; then
		dbus set fss_node_order="${kept_ids}"
	else
		dbus remove fss_node_order >/dev/null 2>&1
	fi

	# 4. 清理 ssconf_basic_node（主出口节点）：指向被删 → 改成新 order 首项；新 order 空则清空
	current_id="$(dbus get ssconf_basic_node)"
	if [ -n "${current_id}" ]; then
		for id in ${dropped_ids}
		do
			if [ "${current_id}" = "${id}" ]; then
				current_dropped=1
				break
			fi
		done
	fi
	if [ "${current_dropped}" = "1" ]; then
		if [ -n "${kept_ids}" ]; then
			local new_main="${kept_ids%%,*}"
			dbus set ssconf_basic_node="${new_main}"
			echo_date "[doge.10 migrate] 主出口节点（id=${current_id}）已被删除，切换到 id=${new_main}。"
		else
			dbus remove ssconf_basic_node >/dev/null 2>&1
			echo_date "[doge.10 migrate] 主出口节点（id=${current_id}）已被删除，且无剩余节点可用。"
		fi
	fi

	# 5. 清理 ssconf_basic_node_front（前置节点）：指向被删 → 清空（前置是可选的）
	front_id="$(dbus get ssconf_basic_node_front)"
	if [ -n "${front_id}" ]; then
		for id in ${dropped_ids}
		do
			if [ "${front_id}" = "${id}" ]; then
				front_dropped=1
				break
			fi
		done
	fi
	if [ "${front_dropped}" = "1" ]; then
		dbus set ssconf_basic_node_front=""
		echo_date "[doge.10 migrate] 前置节点（id=${front_id}）已被删除，已清空前置设置。"
	fi

	# 6. 遍历 combo 列表
	#    - landing_id 指向被删 → 整个 combo 待删（收集 idx，倒序 drop 避免索引错位）
	#    - front_id 指向被删（landing 仍有效）→ 清空 front_id / front_identity
	total="$(dbus get ss_failover_combo_count)"
	case "${total}" in ''|*[!0-9]*) total=0 ;; esac
	if [ "${total}" -gt 0 ] 2>/dev/null; then
		i=1
		while [ "${i}" -le "${total}" ]
		do
			landing_id="$(dbus get "ss_failover_combo_${i}_landing_id")"
			front_id_combo="$(dbus get "ss_failover_combo_${i}_front_id")"
			landing_dropped=0
			front_dropped=0
			if [ -n "${landing_id}" ]; then
				for id in ${dropped_ids}
				do
					if [ "${landing_id}" = "${id}" ]; then
						landing_dropped=1
						break
					fi
				done
			fi
			if [ -n "${front_id_combo}" ]; then
				for id in ${dropped_ids}
				do
					if [ "${front_id_combo}" = "${id}" ]; then
						front_dropped=1
						break
					fi
				done
			fi
			if [ "${landing_dropped}" = "1" ]; then
				# 把待删 idx 倒序压栈（drop 时要从大到小）
				drop_combo_list="${i}${drop_combo_list:+ }${drop_combo_list}"
				combo_changes=$((combo_changes + 1))
			elif [ "${front_dropped}" = "1" ]; then
				dbus set "ss_failover_combo_${i}_front_id"=""
				dbus set "ss_failover_combo_${i}_front_identity"=""
				combo_changes=$((combo_changes + 1))
			fi
			i=$((i + 1))
		done
		# 倒序删 combo
		for i in ${drop_combo_list}
		do
			fss_failover_combo_drop "${i}" >/dev/null 2>&1
		done
	fi

	# 7. 汇总日志
	echo_date "[doge.10 migrate] 已删除 SSR 节点 ${ssr_count} 个、Naive ${naive_count} 个、Tuic ${tuic_count} 个。"
	if [ "${combo_changes}" -gt 0 ] 2>/dev/null; then
		echo_date "[doge.10 migrate] 已清理 ${combo_changes} 个故障转移备用组合（landing 被删则整组删除；front 被删则清空前置）。"
	fi

	dbus set fss_doge10_legacy_protocols_migrated="1"
}

get_model(){
	local ODMPID=$(nvram get odmpid)
	local PRODUCTID=$(nvram get productid)
	if [ -n "${ODMPID}" ];then
		MODEL="${ODMPID}"
	else
		MODEL="${PRODUCTID}"
	fi
}

get_fw_type() {
	local KS_TAG=$(nvram get extendno|grep -E "_kool")
	if [ -d "/koolshare" ];then
		if [ -n "${KS_TAG}" ];then
			FW_TYPE_NAME="koolcenter官改固件"
		else
			FW_TYPE_NAME="koolcenter梅林改版固件"
		fi
	else
		if [ "$(uname -o|grep Merlin)" ];then
			FW_TYPE_NAME="梅林原版固件"
		else
			FW_TYPE_NAME="华硕官方固件"
		fi
	fi
}

get_pkg_field_from_file() {
	local file_path="$1"
	local field="$2"
	[ -f "${file_path}" ] || return 1
	tr -d '\r' < "${file_path}" | grep -Eo "PKG_${field}=.+" | awk -F "=" '{print $2}' | sed 's/"//g' | sed -n '1p'
}

sync_pkg_meta_runtime() {
	local pkg_file="$1"
	local pkg_name=""
	local pkg_arch=""
	local pkg_type=""
	local pkg_exta=""

	pkg_name="$(get_pkg_field_from_file "${pkg_file}" "NAME")"
	pkg_arch="$(get_pkg_field_from_file "${pkg_file}" "ARCH")"
	pkg_type="$(get_pkg_field_from_file "${pkg_file}" "TYPE")"
	pkg_exta="$(get_pkg_field_from_file "${pkg_file}" "EXTA")"

	[ -n "${pkg_name}" ] && dbus set ss_basic_pkg_name="${pkg_name}"
	[ -n "${pkg_arch}" ] && dbus set ss_basic_pkg_arch="${pkg_arch}"
	[ -n "${pkg_type}" ] && dbus set ss_basic_pkg_type="${pkg_type}"
	dbus set ss_basic_pkg_exta="${pkg_exta}"

	if [ -n "${pkg_arch}" ];then
		echo "${pkg_arch}" > /koolshare/.valid
	fi

	if [ -f "/koolshare/webs/Module_shadowsocks.asp" ];then
		[ -n "${pkg_name}" ] && sed -i "s/^var PKG_NAME=.*/var PKG_NAME=\"${pkg_name}\"/" /koolshare/webs/Module_shadowsocks.asp
		[ -n "${pkg_arch}" ] && sed -i "s/^var PKG_ARCH=.*/var PKG_ARCH=\"${pkg_arch}\"/" /koolshare/webs/Module_shadowsocks.asp
		[ -n "${pkg_type}" ] && sed -i "s/^var PKG_TYPE=.*/var PKG_TYPE=\"${pkg_type}\"/" /koolshare/webs/Module_shadowsocks.asp
		sed -i "s/^var PKG_EXTA=.*/var PKG_EXTA=\"${pkg_exta}\"/" /koolshare/webs/Module_shadowsocks.asp
	fi
}

version_to_num() {
	local version="$1"
	echo "${version}" | awk -F'[^0-9]+' '{printf("%d%03d%03d\n", $1+0, $2+0, $3+0)}'
}

version_lt() {
	local left="$1"
	local right="$2"
	[ -n "${left}" ] || return 0
	[ "$(version_to_num "${left}")" -lt "$(version_to_num "${right}")" ]
}

schema2_secret_decode_candidate() {
	local value="$1"
	local decoded=""
	local normalized=""

	[ -n "${value}" ] || return 1
	printf '%s' "${value}" | grep -Eq '^[A-Za-z0-9+/=]+$' || return 1
	[ $(( ${#value} % 4 )) -eq 0 ] || return 1

	decoded="$(printf '%s' "${value}" | base64_decode 2>/dev/null)" || return 1
	[ -n "${decoded}" ] || return 1

	# FORK doge.13 beta.2: base64_encode 末尾可能追 TAB 致 normalize ≠ value 假阴性
	# 详见同文件 migrate_split_routing_v2 注释 / [[reference_busybox_base64_loop]]
	normalized="$(printf '%s' "${decoded}" | base64_encode 2>/dev/null | tr -d '\t\n\r ')"
	[ -n "${normalized}" ] || return 1
	[ "${normalized}" = "${value}" ] || return 1
	[ "${decoded}" != "${value}" ] || return 1

	printf '%s' "${decoded}"
}

schema2_anytls_pass_decode_candidate() {
	local value="$1"
	local decoded=""

	decoded="$(schema2_secret_decode_candidate "${value}")" || return 1
	printf '%s' "${decoded}" | grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' || return 1
	printf '%s' "${decoded}"
}

normalize_schema2_secret_fields_after_install() {
	local reason="$1"
	local force_scan="$2"
	local node_id=""
	local field=""
	local raw_value=""
	local plain_value=""
	local decoded=""
	local node_json=""
	local updated_json=""
	local updated_at=""
	local changed_nodes=0
	local changed_fields=0
	local scanned_nodes=0
	local total_nodes=0
	# FORK: cut in doge.10, see doc/design/protocol-roadmap.md §2 — removed naive_pass
	local fields="password"

	[ "$(fss_detect_storage_schema 2>/dev/null)" = "2" ] || return 0
	if [ "${force_scan}" != "1" ] && [ "$(dbus get fss_data_secret_mode 2>/dev/null)" = "raw" ];then
		return 0
	fi
	total_nodes="$(fss_list_node_ids | awk 'NF{c++} END{print c+0}')"
	[ -n "${total_nodes}" ] || total_nodes=0
	echo_date "开始校正 schema2 密码字段（${reason}），共 ${total_nodes} 个节点..."

	for node_id in $(fss_list_node_ids)
	do
		[ -n "${node_id}" ] || continue
		scanned_nodes=$((scanned_nodes + 1))
		node_json="$(fss_v2_get_node_json_by_id "${node_id}" 2>/dev/null)" || continue
		updated_json="${node_json}"
		updated_at="$(fss_now_ts_ms)"
		local node_changed=0

		for field in ${fields}
		do
			raw_value="$(printf '%s' "${updated_json}" | jq -r --arg f "${field}" '.[$f] // empty' 2>/dev/null)"
			[ -n "${raw_value}" ] || continue

			plain_value="$(fss_get_node_field_plain "${node_id}" "${field}" 2>/dev/null)"
			decoded=""

			if [ -n "${plain_value}" ] && [ "${plain_value}" != "${raw_value}" ]; then
				decoded="${plain_value}"
			else
				decoded="$(schema2_secret_decode_candidate "${raw_value}")" || decoded=""
			fi

			[ -n "${decoded}" ] || continue
			[ "${decoded}" != "${raw_value}" ] || continue

			updated_json="$(printf '%s' "${updated_json}" | jq -c \
				--arg f "${field}" \
				--arg v "${decoded}" \
				--argjson updated_at "${updated_at}" \
				'.[$f] = $v
				| ._b64_mode = "raw"
				| ._rev = (((._rev // 0) | tonumber? // 0) + 1)
				| ._updated_at = $updated_at' 2>/dev/null)" || continue
			node_changed=1
			changed_fields=$((changed_fields + 1))
			echo_date "校正 schema2 节点 ${node_id} 的 ${field} 字段：base64 -> raw（${reason}）"
		done

		if [ "${node_changed}" = "1" ]; then
			dbus set fss_node_${node_id}="$(fss_b64_encode "${updated_json}")"
			changed_nodes=$((changed_nodes + 1))
		fi
		if [ "${scanned_nodes}" = "1" ] || [ $((scanned_nodes % 20)) -eq 0 ] || [ "${scanned_nodes}" = "${total_nodes}" ]; then
			echo_date "schema2 密码字段校正进度：${scanned_nodes}/${total_nodes}"
		fi
	done

	if [ "${changed_nodes}" -gt 0 ]; then
		fss_touch_node_catalog_ts >/dev/null 2>&1 || true
		fss_touch_node_config_ts >/dev/null 2>&1 || true
		echo_date "已完成 schema2 密码字段校正：节点 ${changed_nodes} 个，字段 ${changed_fields} 项。"
	else
		echo_date "schema2 密码字段校正完成：未发现需要修正的节点。"
	fi
}

normalize_schema2_anytls_pass_after_install() {
	local reason="$1"
	local node_id=""
	local raw_value=""
	local decoded=""
	local node_json=""
	local updated_json=""
	local updated_at=""
	local changed_nodes=0
	local scanned_nodes=0
	local total_nodes=0

	[ "$(fss_detect_storage_schema 2>/dev/null)" = "2" ] || return 0
	total_nodes="$(fss_list_node_ids | awk 'NF{c++} END{print c+0}')"
	[ -n "${total_nodes}" ] || total_nodes=0

	for node_id in $(fss_list_node_ids)
	do
		[ -n "${node_id}" ] || continue
		scanned_nodes=$((scanned_nodes + 1))
		node_json="$(fss_v2_get_node_json_by_id "${node_id}" 2>/dev/null)" || continue
		[ "$(printf '%s' "${node_json}" | jq -r '.type // empty' 2>/dev/null)" = "9" ] || continue
		raw_value="$(printf '%s' "${node_json}" | jq -r '.anytls_pass // empty' 2>/dev/null)"
		[ -n "${raw_value}" ] || continue
		decoded="$(schema2_anytls_pass_decode_candidate "${raw_value}")" || decoded=""
		[ -n "${decoded}" ] || continue
		[ "${decoded}" != "${raw_value}" ] || continue

		updated_at="$(fss_now_ts_ms)"
		updated_json="$(printf '%s' "${node_json}" | jq -c \
			--arg v "${decoded}" \
			--argjson updated_at "${updated_at}" \
			'.anytls_pass = $v
			| ._b64_mode = "raw"
			| ._rev = (((._rev // 0) | tonumber? // 0) + 1)
			| ._updated_at = $updated_at' 2>/dev/null)" || continue
		dbus set fss_node_${node_id}="$(fss_b64_encode "${updated_json}")"
		changed_nodes=$((changed_nodes + 1))
		echo_date "校正 AnyTLS 节点 ${node_id} 的认证密码：旧版 base64 -> raw（${reason}）"
	done

	if [ "${changed_nodes}" -gt 0 ]; then
		fss_touch_node_catalog_ts >/dev/null 2>&1 || true
		fss_touch_node_config_ts >/dev/null 2>&1 || true
		echo_date "已完成 AnyTLS 认证密码校正：节点 ${changed_nodes} 个。"
	fi
}

cleanup_legacy_smartdns_user_configs() {
	local old_ver="$1"
	[ -n "${old_ver}" ] || return 0
	if ! version_lt "${old_ver}" "3.5.6"; then
		return 0
	fi
	if [ -n "$(find /koolshare/ss/rules -maxdepth 1 -type f -name 'smartdns_smrt_*_user.conf' 2>/dev/null)" ];then
		echo_date "检测到旧版 fancyss（${old_ver}）的自定义 smartdns 配置。"
		echo_date "3.5.6 起 smartdns 改为由 fancyss 按前端设置动态生成配置。"
		echo_date "旧版 smartdns 自定义模板将被移除，升级后请在 smartdns 的 chn / gfw DNS 选择界面重新调整上游。"
		find /koolshare/ss/rules -maxdepth 1 -type f -name 'smartdns_smrt_*_user.conf' -delete 2>/dev/null
	fi
}

platform_test(){
	# 带koolshare文件夹，有httpdb和skipdb的固件位支持固件
	if [ -d "/koolshare" -a -x "/koolshare/bin/httpdb" -a -x "/usr/bin/skipd" ];then
		echo_date "机型：${MODEL} ${FW_TYPE_NAME} 符合安装要求，开始安装插件！"
	else
		exit_install 1
	fi

	# 继续判断各个固件的内核和架构
	PKG_ARCH=$(cat ${DIR}/.valid)
	ROT_ARCH=$(uname -m)
	KEL_VERS=$(uname -r)
	PKG_NAME=$(get_pkg_field_from_file /tmp/shadowsocks/webs/Module_shadowsocks.asp "NAME")
	PKG_ARCH=$(get_pkg_field_from_file /tmp/shadowsocks/webs/Module_shadowsocks.asp "ARCH")
	PKG_TYPE=$(get_pkg_field_from_file /tmp/shadowsocks/webs/Module_shadowsocks.asp "TYPE")

	# fancyss_arm
	if [ "${PKG_ARCH}" == "arm" ]; then
		case "${LINUX_VER}" in
			"26")
				if [ "${ROT_ARCH}" == "armv7l" ]; then
					echo_date "内核：${KEL_VERS}，架构：${ROT_ARCH}，安装fancyss_${PKG_ARCH}_${PKG_TYPE}！"
				else
					echo_date "架构：${ROT_ARCH}，fancyss_${PKG_ARCH}_${PKG_TYPE}不适用于该架构！退出！"
					exit_install 1
				fi
				;;
			"41"|"419")
				if [ "${ROT_ARCH}" == "armv7l" ]; then
					echo_date "内核：${KEL_VERS}，架构：${ROT_ARCH}，fancyss_${PKG_ARCH}_${PKG_TYPE}不适用于该内核版本！"
					echo_date "建议使用fancyss_hnd_full或者fancyss_hnd_lite！"
					echo_date "下载地址：https://github.com/hq450/fancyss_history_package/tree/master/fancyss_hnd"
					exit_install 1
				elif [ "${ROT_ARCH}" == "aarch64" ]; then
					echo_date "内核：${KEL_VERS}，架构：${ROT_ARCH}，fancyss_${PKG_ARCH}_${PKG_TYPE}不适用于该内核版本！"
					echo_date "建议使用fancyss_hnd_v8_full或者fancyss_hnd_v8_lite！"
					echo_date "下载地址：https://github.com/hq450/fancyss_history_package/tree/master/fancyss_hnd"
					exit_install 1
				else
					echo_date "内核：${KEL_VERS}，架构：${ROT_ARCH}，fancyss_${PKG_ARCH}_${PKG_TYPE}不适用于该架构！退出！"
					exit_install 1
				fi
				;;
			"44")
				echo_date "内核：${KEL_VERS}，架构：${ROT_ARCH}，fancyss_${PKG_ARCH}_${PKG_TYPE}不适用于该内核版本！"
				echo_date "建议使用fancyss_qca_full或者fancyss_qca_lite！"		
				echo_date "下载地址：https://github.com/hq450/fancyss_history_package/tree/master/fancyss_qca"
				exit_install 1
				;;
			"54")
				echo_date "内核：${KEL_VERS}，架构：${ROT_ARCH}，fancyss_${PKG_ARCH}_${PKG_TYPE}不适用于该内核版本！"
				case "${MODEL}" in
					"ZenWiFi_BD4")
						echo_date "建议使用fancyss_ipq32_full或者fancyss_ipq32_lite！"		
						echo_date "下载地址：https://github.com/hq450/fancyss_history_package/tree/master/fancyss_ipq32"
						exit_install 1
						;;
					"TUF_6500")
						echo_date "建议使用fancyss_ipq64_full或者fancyss_ipq64_lite！"		
						echo_date "下载地址：https://github.com/hq450/fancyss_history_package/tree/master/fancyss_ipq64"
						exit_install 1
						;;
					"TX-AX6000"|"TUF-AX4200Q"|"RT-AX57_Go"|"GS7"|"ZenWiFi_BT8P"|"GS7_Air")
						echo_date "建议使用fancyss_mtk_full或者fancyss_mtk_lite！"		
						echo_date "下载地址：https://github.com/hq450/fancyss_history_package/tree/master/fancyss_mtk"
						exit_install 1
						;;
					*)
						echo_date "原因：暂不支持你的路由器型号：${MODEL}，请联系插件作者！"		
						exit_install 1
						;;
				esac
				;;
			*)
				echo_date "内核：${KEL_VERS}，fancyss_${PKG_ARCH}_${PKG_TYPE}不适用于该内核版本！"
				exit_install 1
				;;
		esac
	fi
	
	# fancyss_hnd
	if [ "${PKG_ARCH}" = "hnd" ]; then
		case "${LINUX_VER}" in
			"41"|"419")
				if [ "${ROT_ARCH}" = "armv7l" ]; then
					echo_date "内核：${KEL_VERS}，架构：${ROT_ARCH}，安装fancyss_${PKG_ARCH}_${PKG_TYPE}！"
				elif [ "${ROT_ARCH}" = "aarch64" ]; then
					echo_date "内核：${KEL_VERS}，架构：${ROT_ARCH}，安装fancyss_${PKG_ARCH}_${PKG_TYPE}！"
					echo_date
					echo_date "----------------------------------------------------------------------"
					echo_date "你的机型是${ROT_ARCH}架构，当前使用的是32位版本的fancyss！"
					echo_date "建议使用64位的fancyss，如fancyss_hnd_v8_full或者fancyss_hnd_v8_lite！"
					echo_date "下载地址：https://github.com/hq450/fancyss_history_package/tree/master/fancyss_hnd_v8"
					echo_date "----------------------------------------------------------------------"
					echo_date
					echo_date "继续安装32位的fancyss_${PKG_ARCH}_${PKG_TYPE}！"
				else
					echo_date "内核：${KEL_VERS}，架构：${ROT_ARCH}，fancyss_${PKG_ARCH}_${PKG_TYPE}不适用于该架构！退出！"
					exit_install 1
				fi
				;;
			"26")
				echo_date "内核：${KEL_VERS}，架构：${ROT_ARCH}，fancyss_${PKG_ARCH}_${PKG_TYPE}不适用于该内核版本！"
				echo_date "建议使用fancyss_arm_full或者fancyss_arm_lite！"
				echo_date "下载地址：https://github.com/hq450/fancyss_history_package/tree/master/fancyss_arm"
				exit_install 1
				;;
			"44")
				echo_date "内核：${KEL_VERS}，架构：${ROT_ARCH}，fancyss_${PKG_ARCH}_${PKG_TYPE}不适用于该内核版本！"
				echo_date "建议使用fancyss_qca_full或者fancyss_qca_lite！"
				echo_date "下载地址：https://github.com/hq450/fancyss_history_package/tree/master/fancyss_qca"
				exit_install 1
				;;
			"54")
				echo_date "内核：${KEL_VERS}，架构：${ROT_ARCH}，fancyss_${PKG_ARCH}_${PKG_TYPE}不适用于该内核版本！"
				case "${MODEL}" in
					"ZenWiFi_BD4")
						echo_date "建议使用fancyss_ipq32_full或者fancyss_ipq32_lite！"		
						echo_date "下载地址：https://github.com/hq450/fancyss_history_package/tree/master/fancyss_ipq32"
						exit_install 1
						;;
					"TUF_6500")
						echo_date "建议使用fancyss_ipq64_full或者fancyss_ipq64_lite！"		
						echo_date "下载地址：https://github.com/hq450/fancyss_history_package/tree/master/fancyss_ipq64"
						exit_install 1
						;;
					"TX-AX6000"|"TUF-AX4200Q"|"RT-AX57_Go"|"GS7"|"ZenWiFi_BT8P"|"GS7_Air")
						echo_date "建议使用fancyss_mtk_full或者fancyss_mtk_lite！"		
						echo_date "下载地址：https://github.com/hq450/fancyss_history_package/tree/master/fancyss_mtk"
						exit_install 1
						;;
					*)
						echo_date "原因：暂不支持你的路由器型号：${MODEL}，请联系插件作者！"		
						exit_install 1
						;;
				esac
				;;
			*)
				echo_date "内核：${KEL_VERS}，架构：${ROT_ARCH}，fancyss_${PKG_ARCH}_${PKG_TYPE}不适用于该内核版本！"
				exit_install 1
				;;
		esac
	fi

	# fancyss_hnd_v8
	if [ "${PKG_ARCH}" = "hnd_v8" ]; then
		case "${LINUX_VER}" in
			"41"|"419")
				if [ "${ROT_ARCH}" = "armv7l" ]; then
					echo_date "内核：${KEL_VERS}，架构：${ROT_ARCH}，fancyss_${PKG_ARCH}_${PKG_TYPE}不适用于该架构！"
					echo_date "原因：无法在32位的路由器上使用64位程序的fancyss_${PKG_ARCH}_${PKG_TYPE}！"
					echo_date "建议使用fancyss_hnd_full或者fancyss_hnd_lite！"
					echo_date "下载地址：https://github.com/hq450/fancyss_history_package/tree/master/fancyss_hnd"
					echo_date "退出安装！"
					exit_install 1
				elif [ "${ROT_ARCH}" = "aarch64" ]; then
					echo_date "内核：${KEL_VERS}，架构：${ROT_ARCH}，安装fancyss_${PKG_ARCH}_${PKG_TYPE}！"
				else
					echo_date "内核：${KEL_VERS}，架构：${ROT_ARCH}，fancyss_${PKG_ARCH}_${PKG_TYPE}不适用于该架构！退出！"
					exit_install 1
				fi
				;;
			"26")
				echo_date "内核：${KEL_VERS}，架构：${ROT_ARCH}，fancyss_${PKG_ARCH}_${PKG_TYPE}不适用于该内核版本！"
				echo_date "建议使用fancyss_arm_full或者fancyss_arm_lite！"
				echo_date "下载地址：https://github.com/hq450/fancyss_history_package/tree/master/fancyss_arm"
				exit_install 1
				;;
			"44")
				echo_date "内核：${KEL_VERS}，架构：${ROT_ARCH}，fancyss_${PKG_ARCH}_${PKG_TYPE}不适用于该内核版本！"
				echo_date "建议使用fancyss_qca_full或者fancyss_qca_lite！"
				echo_date "下载地址：https://github.com/hq450/fancyss_history_package/tree/master/fancyss_qca"
				exit_install 1
				;;
			"54")
				echo_date "内核：${KEL_VERS}，架构：${ROT_ARCH}，fancyss_${PKG_ARCH}_${PKG_TYPE}不适用于该内核版本！"
				case "${MODEL}" in
					"ZenWiFi_BD4")
						echo_date "建议使用fancyss_ipq32_full或者fancyss_ipq32_lite！"		
						echo_date "下载地址：https://github.com/hq450/fancyss_history_package/tree/master/fancyss_ipq32"
						exit_install 1
						;;
					"TUF_6500")
						echo_date "建议使用fancyss_ipq64_full或者fancyss_ipq64_lite！"		
						echo_date "下载地址：https://github.com/hq450/fancyss_history_package/tree/master/fancyss_ipq64"
						exit_install 1
						;;
					"TX-AX6000"|"TUF-AX4200Q"|"RT-AX57_Go"|"GS7"|"ZenWiFi_BT8P"|"GS7_Air")
						echo_date "建议使用fancyss_mtk_full或者fancyss_mtk_lite！"		
						echo_date "下载地址：https://github.com/hq450/fancyss_history_package/tree/master/fancyss_mtk"
						exit_install 1
						;;
					*)
						echo_date "原因：暂不支持你的路由器型号：${MODEL}，请联系插件作者！"		
						exit_install 1
						;;
				esac
				;;
			*)
				echo_date "内核：${KEL_VERS}，架构：${ROT_ARCH}，fancyss_${PKG_ARCH}_${PKG_TYPE}不适用于该内核版本！"
				exit_install 1
				;;
		esac
	fi

	# fancyss_qca
	if [ "${PKG_ARCH}" = "qca" ]; then
		case "${LINUX_VER}" in
			"44")
				echo_date "内核：${KEL_VERS}，架构：${ROT_ARCH}，安装fancyss_${PKG_ARCH}_${PKG_TYPE}！"
				;;
			"26")
				echo_date "内核：${KEL_VERS}，架构：${ROT_ARCH}，fancyss_${PKG_ARCH}_${PKG_TYPE}不适用于该内核版本！"
				echo_date "建议使用fancyss_arm_full或者fancyss_arm_lite！"
				echo_date "下载地址：https://github.com/hq450/fancyss_history_package/tree/master/fancyss_arm"
				exit_install 1
				;;
			"41"|"419")
				if [ "${ROT_ARCH}" = "armv7l" ]; then
					echo_date "内核：${KEL_VERS}，架构：${ROT_ARCH}，fancyss_${PKG_ARCH}_${PKG_TYPE}不适用于该内核版本！"
					echo_date "建议使用fancyss_hnd_full或者fancyss_hnd_lite！"
					echo_date "下载地址：https://github.com/hq450/fancyss_history_package/tree/master/fancyss_hnd"
					exit_install 1
				elif [ "${ROT_ARCH}" = "aarch64" ]; then
					echo_date "内核：${KEL_VERS}，架构：${ROT_ARCH}，fancyss_${PKG_ARCH}_${PKG_TYPE}不适用于该内核版本！"
					echo_date "建议使用fancyss_hnd_v8_full或者fancyss_hnd_v8_lite！"
					echo_date "下载地址：https://github.com/hq450/fancyss_history_package/tree/master/fancyss_hnd"
					exit_install 1
				else
					echo_date "内核：${KEL_VERS}，架构：${ROT_ARCH}，fancyss_${PKG_ARCH}_${PKG_TYPE}不适用于该架构！退出！"
					exit_install 1
				fi
				;;
			"54")
				echo_date "内核：${KEL_VERS}，架构：${ROT_ARCH}，fancyss_${PKG_ARCH}_${PKG_TYPE}不适用于该内核版本！"
				case "${MODEL}" in
					"ZenWiFi_BD4")
						echo_date "建议使用fancyss_ipq32_full或者fancyss_ipq32_lite！"
						echo_date "下载地址：https://github.com/hq450/fancyss_history_package/tree/master/fancyss_ipq32"
						exit_install 1
						;;
					"TUF_6500")
						echo_date "建议使用fancyss_ipq64_full或者fancyss_ipq64_lite！"
						echo_date "下载地址：https://github.com/hq450/fancyss_history_package/tree/master/fancyss_ipq64"
						exit_install 1
						;;
					"TX-AX6000"|"TUF-AX4200Q"|"RT-AX57_Go"|"GS7"|"ZenWiFi_BT8P"|"GS7_Air")
						echo_date "建议使用fancyss_mtk_full或者fancyss_mtk_lite！"		
						echo_date "下载地址：https://github.com/hq450/fancyss_history_package/tree/master/fancyss_mtk"
						exit_install 1
						;;
					*)
						echo_date "原因：暂不支持你的路由器型号：${MODEL}，请联系插件作者！"
						exit_install 1
						;;
				esac
				;;
			*)
				echo_date "内核：${KEL_VERS}，架构：${ROT_ARCH}，fancyss_${PKG_ARCH}_${PKG_TYPE}不适用于该内核版本！"
				exit_install 1
				;;
		esac
	fi

	# fancyss_mtk
	if [ "${PKG_ARCH}" == "mtk" ]; then
		case "${LINUX_VER}" in
			"54")
				case "${MODEL}" in
					"ZenWiFi_BD4")
						echo_date "建议使用fancyss_ipq32_full或者fancyss_ipq32_lite！"	
						echo_date "下载地址：https://github.com/hq450/fancyss_history_package/tree/master/fancyss_ipq32"
						exit_install 1
						;;
					"TUF_6500")
						echo_date "建议使用fancyss_ipq64_full或者fancyss_ipq64_lite！"		
						echo_date "下载地址：https://github.com/hq450/fancyss_history_package/tree/master/fancyss_ipq64"
						exit_install 1
						;;
					"TX-AX6000"|"TUF-AX4200Q"|"RT-AX57_Go"|"GS7"|"ZenWiFi_BT8P"|"GS7_Air")
						echo_date "内核：${KEL_VERS}，架构：${ROT_ARCH}，安装fancyss_${PKG_ARCH}_${PKG_TYPE}！"
						;;
					*)
						echo_date "原因：暂不支持你的路由器型号：${MODEL}，请联系插件作者！"		
						exit_install 1
						;;
				esac
				;;
			"26")
				echo_date "内核：${KEL_VERS}，架构：${ROT_ARCH}，fancyss_${PKG_ARCH}_${PKG_TYPE}不适用于该内核版本！"
				echo_date "建议使用fancyss_arm_full或者fancyss_arm_lite！"
				echo_date "下载地址：https://github.com/hq450/fancyss_history_package/tree/master/fancyss_arm"
				exit_install 1
				;;
			"41"|"419")
				if [ "${ROT_ARCH}" == "armv7l" ]; then
					echo_date "内核：${KEL_VERS}，架构：${ROT_ARCH}，fancyss_${PKG_ARCH}_${PKG_TYPE}不适用于该内核版本！"
					echo_date "建议使用fancyss_hnd_full或者fancyss_hnd_lite！"
					echo_date "下载地址：https://github.com/hq450/fancyss_history_package/tree/master/fancyss_hnd"
					exit_install 1
				elif [ "${ROT_ARCH}" == "aarch64" ]; then
					echo_date "内核：${KEL_VERS}，架构：${ROT_ARCH}，fancyss_${PKG_ARCH}_${PKG_TYPE}不适用于该内核版本！"
					echo_date "建议使用fancyss_hnd_v8_full或者fancyss_hnd_v8_lite！"
					echo_date "下载地址：https://github.com/hq450/fancyss_history_package/tree/master/fancyss_hnd"
					exit_install 1
				else
					echo_date "内核：${KEL_VERS}，架构：${ROT_ARCH}，fancyss_${PKG_ARCH}_${PKG_TYPE}不适用于该架构！退出！"
					exit_install 1
				fi
				;;
			"44")
				echo_date "内核：${KEL_VERS}，架构：${ROT_ARCH}，fancyss_hnd_${PKG_TYPE}不适用于该内核版本！"
				echo_date "建议使用fancyss_qca_full或者fancyss_qca_lite！"
				echo_date "下载地址：https://github.com/hq450/fancyss_history_package/tree/master/fancyss_qca"
				exit_install 1
				;;
			*)
				echo_date "内核：${KEL_VERS}，架构：${ROT_ARCH}，fancyss_${PKG_ARCH}_${PKG_TYPE}不适用于该内核版本！"
				exit_install 1
				;;
		esac
	fi

	# fancyss_ipq32
	if [ "${PKG_ARCH}" = "ipq32" ]; then
		case "${LINUX_VER}" in
			"54")
				case "${MODEL}" in
					"ZenWiFi_BD4")
						echo_date "内核：${KEL_VERS}，架构：${ROT_ARCH}，安装fancyss_${PKG_ARCH}_${PKG_TYPE}！"
						;;
					"TUF_6500")
						echo_date "建议使用fancyss_ipq64_full或者fancyss_ipq64_lite！"		
						echo_date "下载地址：https://github.com/hq450/fancyss_history_package/tree/master/fancyss_ipq64"
						exit_install 1
						;;
					"TX-AX6000"|"TUF-AX4200Q"|"RT-AX57_Go"|"GS7"|"ZenWiFi_BT8P"|"GS7_Air")
						echo_date "建议使用fancyss_mtk_full或者fancyss_mtk_lite！"		
						echo_date "下载地址：https://github.com/hq450/fancyss_history_package/tree/master/fancyss_mtk"
						exit_install 1
						;;
					*)
						echo_date "原因：暂不支持你的路由器型号：${MODEL}，请联系插件作者！"		
						exit_install 1
						;;
				esac
				;;
			"26")
				echo_date "内核：${KEL_VERS}，架构：${ROT_ARCH}，fancyss_${PKG_ARCH}_${PKG_TYPE}不适用于该内核版本！"
				echo_date "建议使用fancyss_arm_full或者fancyss_arm_lite！"
				echo_date "下载地址：https://github.com/hq450/fancyss_history_package/tree/master/fancyss_arm"
				exit_install 1
				;;
			"41"|"419")
				if [ "${ROT_ARCH}" = "armv7l" ]; then
					echo_date "内核：${KEL_VERS}，架构：${ROT_ARCH}，fancyss_${PKG_ARCH}_${PKG_TYPE}不适用于该内核版本！"
					echo_date "建议使用fancyss_hnd_full或者fancyss_hnd_lite！"
					echo_date "下载地址：https://github.com/hq450/fancyss_history_package/tree/master/fancyss_hnd"
					exit_install 1
				elif [ "${ROT_ARCH}" = "aarch64" ]; then
					echo_date "内核：${KEL_VERS}，架构：${ROT_ARCH}，fancyss_${PKG_ARCH}_${PKG_TYPE}不适用于该内核版本！"
					echo_date "建议使用fancyss_hnd_v8_full或者fancyss_hnd_v8_lite！"
					echo_date "下载地址：https://github.com/hq450/fancyss_history_package/tree/master/fancyss_hnd"
					exit_install 1
				else
					echo_date "内核：${KEL_VERS}，架构：${ROT_ARCH}，fancyss_${PKG_ARCH}_${PKG_TYPE}不适用于该架构！退出！"
					exit_install 1
				fi
				;;
			"44")
				echo_date "内核：${KEL_VERS}，架构：${ROT_ARCH}，fancyss_hnd_${PKG_TYPE}不适用于该内核版本！"
				echo_date "建议使用fancyss_qca_full或者fancyss_qca_lite！"
				echo_date "下载地址：https://github.com/hq450/fancyss_history_package/tree/master/fancyss_qca"
				exit_install 1
				;;
			*)
				echo_date "内核：${KEL_VERS}，架构：${ROT_ARCH}，fancyss_${PKG_ARCH}_${PKG_TYPE}不适用于该内核版本！"
				exit_install 1
				;;
		esac
	fi

	# fancyss_ipq64
	if [ "${PKG_ARCH}" = "ipq64" ]; then
		case "${LINUX_VER}" in
			"54")
				case "${MODEL}" in
					"ZenWiFi_BD4")
						echo_date "建议使用fancyss_ipq32_full或者fancyss_ipq32_lite！"		
						echo_date "下载地址：https://github.com/hq450/fancyss_history_package/tree/master/fancyss_ipq32"
						exit_install 1
						;;
					"TUF_6500")
						echo_date "内核：${KEL_VERS}，架构：${ROT_ARCH}，安装fancyss_${PKG_ARCH}_${PKG_TYPE}！"
						;;
					"TX-AX6000"|"TUF-AX4200Q"|"RT-AX57_Go"|"GS7"|"ZenWiFi_BT8P"|"GS7_Air")
						echo_date "建议使用fancyss_mtk_full或者fancyss_mtk_lite！"		
						echo_date "下载地址：https://github.com/hq450/fancyss_history_package/tree/master/fancyss_mtk"
						exit_install 1
						;;
					*)
						echo_date "原因：暂不支持你的路由器型号：${MODEL}，请联系插件作者！"		
						exit_install 1
						;;
				esac
				;;
			"26")
				echo_date "内核：${KEL_VERS}，架构：${ROT_ARCH}，fancyss_${PKG_ARCH}_${PKG_TYPE}不适用于该内核版本！"
				echo_date "建议使用fancyss_arm_full或者fancyss_arm_lite！"
				echo_date "下载地址：https://github.com/hq450/fancyss_history_package/tree/master/fancyss_arm"
				exit_install 1
				;;
			"41"|"419")
				if [ "${ROT_ARCH}" = "armv7l" ]; then
					echo_date "内核：${KEL_VERS}，架构：${ROT_ARCH}，fancyss_${PKG_ARCH}_${PKG_TYPE}不适用于该内核版本！"
					echo_date "建议使用fancyss_hnd_full或者fancyss_hnd_lite！"
					echo_date "下载地址：https://github.com/hq450/fancyss_history_package/tree/master/fancyss_hnd"
					exit_install 1
				elif [ "${ROT_ARCH}" = "aarch64" ]; then
					echo_date "内核：${KEL_VERS}，架构：${ROT_ARCH}，fancyss_${PKG_ARCH}_${PKG_TYPE}不适用于该内核版本！"
					echo_date "建议使用fancyss_hnd_v8_full或者fancyss_hnd_v8_lite！"
					echo_date "下载地址：https://github.com/hq450/fancyss_history_package/tree/master/fancyss_hnd"
					exit_install 1
				else
					echo_date "内核：${KEL_VERS}，架构：${ROT_ARCH}，fancyss_${PKG_ARCH}_${PKG_TYPE}不适用于该架构！退出！"
					exit_install 1
				fi
				;;
			"44")
				echo_date "内核：${KEL_VERS}，架构：${ROT_ARCH}，fancyss_hnd_${PKG_TYPE}不适用于该内核版本！"
				echo_date "建议使用fancyss_qca_full或者fancyss_qca_lite！"
				echo_date "下载地址：https://github.com/hq450/fancyss_history_package/tree/master/fancyss_qca"
				exit_install 1
				;;
			*)
				echo_date "内核：${KEL_VERS}，架构：${ROT_ARCH}，fancyss_${PKG_ARCH}_${PKG_TYPE}不适用于该内核版本！"
				exit_install 1
				;;
		esac
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

exit_install(){
	local state=$1
	local PKG_ARCH=$(cat ${DIR}/.valid)
	cleanup_install_tmp
	case $state in
		1)
			if is_fancyss_self_update_install; then
				rm -f /tmp/fancyss_self_update_installing /tmp/fancyss_pending_websocketd_restart >/dev/null 2>&1 || true
				rm -rf /tmp/fancyss_deferred_websocketd >/dev/null 2>&1 || true
			fi
			rm -f /tmp/fancyss_websocketd_changed >/dev/null 2>&1 || true
			echo_date "fancyss项目地址：https://github.com/hq450/fancyss"
			echo_date "退出安装！"
			exit 1
			;;
		0|*)
			rm -f /tmp/fancyss_websocketd_changed >/dev/null 2>&1 || true
			exit 0
			;;
	esac
}

cleanup_install_tmp(){
	# 仅清理当前安装脚本所在的 /tmp 解压目录，避免误删 /tmp 下其它文件。
	case "${DIR}" in
		/tmp/*)
			if [ "${DIR}" != "/tmp" -a "${DIR}" != "/tmp/" ];then
				rm -rf "${DIR}" >/dev/null 2>&1
			fi
			;;
	esac
}

__get_name_by_type() {
	case "$1" in
	6)
		echo "Naïve"
		;;
	7)
		echo "tuic"
		;;
	8)
		echo "hysteria2"
		;;
	9)
		echo "AnyTLS"
		;;
	esac
}

append_backup_nodes_schema2(){
	local backup_file="$1"
	local order_csv next_id max_id reserved_max imported_order="" node_json node_id stored_json node_ts
	local first_imported=""

	[ -f "${backup_file}" ] || return 1
	order_csv=$(dbus get fss_node_order)
	next_id=$(dbus get fss_node_next_id)
	[ -n "${next_id}" ] || next_id=1
	max_id=$(printf '%s' "${order_csv}" | tr ',' '\n' | sed '/^$/d' | sort -n | tail -n1)
	[ -n "${max_id}" ] || max_id=0
	reserved_max=$(jq -r '._id // empty' "${backup_file}" 2>/dev/null | sed '/^$/d' | sort -n | tail -n1)
	if [ -n "${reserved_max}" ] && [ "${reserved_max}" -gt "${max_id}" ] 2>/dev/null;then
		max_id="${reserved_max}"
	fi
	if [ "${next_id}" -le "${max_id}" ] 2>/dev/null;then
		next_id=$((max_id + 1))
	fi

	while IFS= read -r node_json
	do
		[ -z "${node_json}" ] && continue
		node_json=$(printf '%s' "${node_json}" | jq -c . 2>/dev/null)
		[ -z "${node_json}" ] && continue
		node_id=$(printf '%s' "${node_json}" | jq -r '._id // empty')
		if [ -z "${node_id}" ];then
			node_id="${next_id}"
			next_id=$((next_id + 1))
		fi
		node_ts=$(fss_now_ts_ms)
		stored_json=$(printf '%s' "${node_json}" | jq -c --arg id "${node_id}" --argjson ts "${node_ts}" '
			with_entries(select(.value != "" and .value != null))
			| del(._schema, ._rev, ._source, ._updated_at, ._migrated_from, .server_ip, .latency, .ping)
			| if ((.type // "") == "4" and ((.xray_prot // "") == "")) then .xray_prot = "vless" else . end
			| . + {
				"_schema": 2,
				"_id": $id,
				"_rev": 1,
				"_source": "lite-restore",
				"_updated_at": $ts
			}
			| ._created_at = (((._created_at // $ts) | tonumber? // $ts) | if . < 1000000000000 then (. * 1000) else . end)
		')
		fss_clear_webtest_cache_node "${node_id}"
		dbus set fss_node_${node_id}="$(fss_b64_encode "${stored_json}")"
		imported_order="${imported_order}${imported_order:+,}${node_id}"
		[ -n "${first_imported}" ] || first_imported="${node_id}"
		if [ "${node_id}" -gt "${max_id}" ] 2>/dev/null;then
			max_id="${node_id}"
		fi
	done < "${backup_file}"

	[ -z "${imported_order}" ] && return 1
	if [ -n "${order_csv}" ];then
		dbus set fss_node_order="${order_csv},${imported_order}"
	else
		dbus set fss_node_order="${imported_order}"
	fi
	dbus set fss_data_schema=2
	dbus set fss_node_next_id="$((max_id + 1))"
	if [ -z "$(fss_get_current_node_id 2>/dev/null)" ] && [ -n "${first_imported}" ];then
		fss_set_current_node_id "${first_imported}"
	fi
	fss_touch_node_catalog_ts >/dev/null 2>&1
	fss_touch_node_config_ts >/dev/null 2>&1
	return 0
}

full2lite(){
	# 当从full版本切换到lite版本的时候，需要将full-only节点进行备份后，从节点列表里删除相应节点
	# 1. 将所有不支持的节点数据储存到备份文件
	local tmp_kv="/tmp/fancyss_kv.txt"
	local backup_dir="/koolshare/configs/fanyss"
	local backup_file="${backup_dir}/fancyss_kv.json"
	if [ "$(fss_detect_storage_schema 2>/dev/null)" = "2" ];then
		local remove_flag=0
		local keep_order=""
		local max_keep=0
		local old_current="$(fss_get_current_node_id 2>/dev/null)"
		local old_failover="$(fss_get_failover_node_id 2>/dev/null)"
		local new_current=""
		local new_failover=""
		local tmp_dir=""
		local nodes_dir=""
		local meta_file=""
		local removed_ids=""
		local json_file=""
		local node_meta=""
		local TY=""
		local NAME=""
		mkdir -p "${backup_dir}"
		: > "${backup_file}"
		tmp_dir="$(fss_mktemp_dir full2lite 2>/dev/null)"
		nodes_dir="${tmp_dir}/nodes"
		meta_file="${tmp_dir}/nodes.meta.tsv"
		if [ -n "${tmp_dir}" ] && fss_dump_v2_node_json_dir "${nodes_dir}" >/dev/null 2>&1; then
			find "${nodes_dir}" -maxdepth 1 -type f -name '*.json' | sort | xargs -r jq -r '[._id, (.type // ""), (.name // "")] | @tsv' > "${meta_file}" 2>/dev/null || true
		fi
		while IFS= read -r NU
		do
			[ -n "${NU}" ] || continue
			TY=""
			NAME=""
			json_file="${nodes_dir}/${NU}.json"
			if [ -s "${meta_file}" ] && [ -f "${json_file}" ]; then
				node_meta="$(grep -m1 "^${NU}	" "${meta_file}" 2>/dev/null)"
				if [ -n "${node_meta}" ]; then
					TY="$(printf '%s' "${node_meta}" | awk -F '\t' '{print $2}')"
					NAME="$(printf '%s' "${node_meta}" | cut -f3-)"
				fi
			fi
			if [ -z "${TY}" ]; then
				TY="$(fss_get_node_field_plain "${NU}" type)"
				NAME="$(fss_get_node_field_plain "${NU}" name)"
			fi
			case "${TY}" in
			6|7|9)
				echo_date "备份并从节点列表里移除第$NU个$(__get_name_by_type ${TY})节点：【${NAME}】"
				if [ -f "${json_file}" ]; then
					jq -c '
						with_entries(select(.value != "" and .value != null))
						| del(._schema, ._rev, ._source, ._updated_at, ._migrated_from, .server_ip, .latency, .ping)
					' "${json_file}" >> "${backup_file}"
				else
					fss_v2_get_node_json_by_id "${NU}" | jq -c '
						with_entries(select(.value != "" and .value != null))
						| del(._schema, ._rev, ._source, ._updated_at, ._migrated_from, .server_ip, .latency, .ping)
					' >> "${backup_file}"
				fi
				removed_ids="${removed_ids} ${NU}"
				dbus remove fss_node_${NU}
				remove_flag=1
				;;
			*)
				keep_order="${keep_order}${keep_order:+,}${NU}"
				if [ "${NU}" -gt "${max_keep}" ] 2>/dev/null;then
					max_keep="${NU}"
				fi
				;;
			esac
		done <<-EOF
		$(fss_list_node_ids)
		EOF
		if [ "${remove_flag}" != "1" ];then
			rm -rf "${tmp_dir}"
			rm -rf "${backup_file}"
			return
		fi
		for NU in ${removed_ids}
		do
			[ -n "${NU}" ] || continue
			fss_clear_webtest_cache_node "${NU}"
		done
		[ -n "${keep_order}" ] && dbus set fss_node_order="${keep_order}" || dbus remove fss_node_order
		if [ -n "${keep_order}" ];then
			if printf '%s' "${keep_order}" | tr ',' '\n' | grep -Fxq "${old_current}" 2>/dev/null;then
				new_current="${old_current}"
			else
				new_current="$(printf '%s' "${keep_order}" | cut -d ',' -f 1)"
			fi
			if [ -n "${old_failover}" ] && printf '%s' "${keep_order}" | tr ',' '\n' | grep -Fxq "${old_failover}" 2>/dev/null;then
				new_failover="${old_failover}"
			fi
		fi
		fss_set_current_node_id "${new_current}"
		fss_set_failover_node_id "${new_failover}"
		dbus set fss_data_schema=2
		dbus set fss_node_next_id="$((max_keep + 1))"
		fss_touch_node_catalog_ts >/dev/null 2>&1
		fss_touch_node_config_ts >/dev/null 2>&1
		if [ -s "${backup_file}" ];then
			echo_date "📁lite版本不支持的节点成功备份到${backup_file}"
		else
			rm -rf "${backup_file}"
		fi
		rm -rf "${tmp_dir}"
		return
	fi
	dbus list ssconf_basic_ | grep -E "_[0-9]+=" | sed '/^ssconf_basic_.\+_[0-9]\+=$/d' | sed 's/^ssconf_basic_//' >"${tmp_kv}"
	NODES_INFO=$(sed -n 's/type_\([0-9]\+=[679]\)/\1/p' "${tmp_kv}" | sort -n)
	if [ -z "${NODES_INFO}" ];then
		rm -rf "${tmp_kv}" "${backup_file}"
		return
	fi
	if [ -n "${NODES_INFO}" ];then
		mkdir -p "${backup_dir}"
		: > "${backup_file}"
		for NODE_INFO in ${NODES_INFO}
		do
			local NU=$(echo "${NODE_INFO}" | awk -F"=" '{print $1}')
			local TY=$(echo "${NODE_INFO}" | awk -F"=" '{print $2}')
			echo_date "备份并从节点列表里移除第$NU个$(__get_name_by_type ${TY})节点：【$(dbus get ssconf_basic_name_${NU})】"
			# 备份
			grep "_${NU}=" "${tmp_kv}" | sed "s/_${NU}=/\":\"/" | sed 's/^/"/;s/$/\"/;s/$/,/g;1 s/^/{/;$ s/,$/}/' | tr -d '\n' | sed 's/$/\n/' >>"${backup_file}"
			# 删除
			dbus list ssconf_basic_|grep "_${NU}="|sed -n 's/\(ssconf_basic_\w\+\)=.*/\1/p' |  while read key
			do
				dbus remove $key
			done
		done
		
		if [ -s "${backup_file}" ];then
			echo_date "📁lite版本不支持的节点成功备份到${backup_file}"
			rm -rf "${tmp_kv}"
		else
			rm -rf "${tmp_kv}" "${backup_file}"
		fi
	fi
}

lite2full(){
	if [ ! -f "/koolshare/configs/fanyss/fancyss_kv.json" ];then
		return
	fi
	
	echo_date "检测到上次安装fancyss lite备份的不支持节点，准备恢复！"
	if [ "$(fss_detect_storage_schema 2>/dev/null)" = "2" ];then
		append_backup_nodes_schema2 "/koolshare/configs/fanyss/fancyss_kv.json"
		echo_date "节点恢复成功！"
		sync
		rm -rf /koolshare/configs/fanyss/fancyss_kv.json
		return
	fi
	local file_name=fancyss_nodes_restore
	cat > /tmp/${file_name}.sh <<-EOF
		#!/bin/sh
		source /koolshare/scripts/base.sh
		#------------------------
	EOF
	NODE_INDEX=$(dbus list ssconf_basic_name_ | sed -n 's/^.*_\([0-9]\+\)=.*/\1/p' | sort -rn | sed -n '1p')
	[ -z "${NODE_INDEX}" ] && NODE_INDEX="0"
	local count=$(($NODE_INDEX + 1))
	while read nodes; do
		echo ${nodes} | sed 's/\",\"/\"\n\"/g;s/^{//;s/}$//' | sed 's/^\"/dbus set ssconf_basic_/g' | sed "s/\":/_${count}=/g" >>/tmp/${file_name}.sh
		let count+=1
	done < /koolshare/configs/fanyss/fancyss_kv.json
	chmod +x /tmp/${file_name}.sh
	sh /tmp/${file_name}.sh
	echo_date "节点恢复成功！"
	sync
	rm -rf /tmp/${file_name}.sh
	rm -rf /tmp/${file_name}.txt
	rm -rf /koolshare/configs/fanyss/fancyss_kv.json
}

check_empty_node(){
	# 从full版本切换为lite版本后，full-only节点将会被删除，比如naive、tuic、AnyTLS节点
	# 如果安装lite版本的时候，full版本使用的是以上节点，则这些节点可能是空的，此时应该切换为下一个不为空的节点，或者关闭插件（没有可用节点的情况）
	if [ "$(fss_detect_storage_schema 2>/dev/null)" = "2" ];then
		local NODES_SEQ=$(fss_list_node_ids)
		if [ -z "${NODES_SEQ}" ];then
			dbus set ss_basic_enable="0"
			ss_basic_enable="0"
			return 0
		fi

		local CURR_NODE=$(fss_get_current_node_id)
		if [ -z "${CURR_NODE}" ];then
			dbus set ss_basic_enable="0"
			ss_basic_enable="0"
			return 0
		fi

		local NODE_FIRST=$(printf '%s\n' "${NODES_SEQ}" | sed -n '1p')
		local CURR_TYPE=$(fss_get_node_field_plain "${CURR_NODE}" type)
		if [ -z "${CURR_TYPE}" ];then
			echo_date "检测到当前节点为空，调整默认节点为节点列表内的第一个节点!"
			fss_set_current_node_id "${NODE_FIRST}"
			return 0
		fi
		return 0
	fi
	local NODES_SEQ=$(dbus list ssconf_basic_name_ | sed -n 's/^.*_\([0-9]\+\)=.*/\1/p' | sort -n)
	if [ -z "${NODES_SEQ}" ];then
		# 没有任何节点，可能是新安装插件，可能是full安装lite被删光了
		dbus set ss_basic_enable="0"
		ss_basic_enable="0"
		return 0
	fi
	
	local CURR_NODE=$(dbus get ssconf_basic_node)
	if [ -z "${CURR_NODE}" ];then
		# 有节点，但是没有没有选择节点
		dbus set ss_basic_enable="0"
		ss_basic_enable="0"
		return 0
	fi
	
	local NODE_INDEX=$(echo ${NODES_SEQ} | sed 's/.*[[:space:]]//')
	local NODE_FIRST=$(echo ${NODES_SEQ} | awk '{print $1}')
	local CURR_TYPE=$(dbus get ssconf_basic_type_${CURR_NODE})
	if [ -z "${CURR_TYPE}" ];then
		# 有节点，选择了节点，但是节点是空的，此时选择最后一个节点作为默认节点
		echo_date "检测到当前节点为空，调整默认节点为节点列表内的第一个节点!"
		dbus set ssconf_basic_node=${NODE_FIRST}
		ssconf_basic_node=${NODE_FIRST}
		sync
	fi
}

check_device(){
	if [ ! -d "/data" ];then
		return "1"
	fi
	
	mkdir -p $1/rw_test 2>/dev/null
	sync
	if [ -d "$1/rw_test" ]; then
		echo "rwTest=OK" >"$1/rw_test/rw_test.txt"
		sync
		if [ -f "$1/rw_test/rw_test.txt" ]; then
			. "$1/rw_test/rw_test.txt"
			if [ "$rwTest" = "OK" ]; then
				rm -rf "$1/rw_test"
				return "0"
			else
				#echo_date "发生错误！你选择的磁盘目录：${1}没有通过文件读取测试！"
				return "1"
			fi
		else
			#echo_date "发生错误！你选择的磁盘目录：${1}没有通过文件写入测试！"
			return "1"
		fi
	else
		#echo_date "发生错误！你选择的磁盘目录：${1}没有通过文件夹写入测试！"
		return "1"
	fi
}

cleanup_jffs_install_tmp(){
	local before=""
	local after=""
	local freed=""
	local target=""
	[ -d "/jffs" ] || return 0
	echo_date "清理JFFS根目录临时日志和旧安装包..."
	before=$(df | awk '$NF == "/jffs" {print $4; exit}')
	for target in \
		/jffs/syslog.log \
		/jffs/driver_log.log \
		/jffs/hostapd.log
	do
		[ -e "${target}" ] || continue
		[ -L "${target}" ] && {
			rm -f "${target}" >/dev/null 2>&1
			continue
		}
		[ -f "${target}" ] || continue
		: > "${target}" 2>/dev/null || rm -f "${target}" >/dev/null 2>&1
	done
	for target in \
		/jffs/uu.tar.gz \
		/jffs/uu.tar.gz.* \
		/jffs/syslog.log-[0-9]* \
		/jffs/driver_log.log-[0-9]* \
		/jffs/hostapd.log-[0-9]*
	do
		[ -e "${target}" ] || continue
		[ -f "${target}" ] || [ -L "${target}" ] || continue
		rm -f "${target}" >/dev/null 2>&1
	done
	sync
	after=$(df | awk '$NF == "/jffs" {print $4; exit}')
	if [ -n "${before}" ] && [ -n "${after}" ];then
		freed=$((after - before))
		if [ "${freed}" -gt "0" ];then
			echo_date "JFFS根目录临时文件清理完成，释放约${freed}KB空间。"
		else
			echo_date "JFFS根目录临时文件清理完成。"
		fi
	else
		echo_date "JFFS根目录临时文件清理完成。"
	fi
}

install_now(){
	# default value
	local PLVER=$(cat ${DIR}/ss/version)
	local OLD_VER="$(dbus get ss_basic_version_local)"
	local FORCE_LEGACY_CACHE_RESET=0
	local FORCE_SCHEMA2_SECRET_NORMALIZE=0
	[ -z "${OLD_VER}" -a -f "/koolshare/ss/version" ] && OLD_VER="$(cat /koolshare/ss/version 2>/dev/null)"
	[ -n "${OLD_VER}" ] && version_lt "${OLD_VER}" "3.6.0" && FORCE_LEGACY_CACHE_RESET=1
	[ -n "${OLD_VER}" ] && version_lt "${OLD_VER}" "3.5.13" && FORCE_SCHEMA2_SECRET_NORMALIZE=1

	#local PKG_ARCH_OLD=$(cat /koolshare/webs/Module_shadowsocks.asp 2>/dev/null | grep -Eo "PKG_ARCH=.+" | awk -F"=" '{print $2}' |sed 's/"//g')
	#local PKG_TYPE_OLD=$(cat /koolshare/webs/Module_shadowsocks.asp 2>/dev/null | grep -Eo "PKG_TYPE=.+" | awk -F"=" '{print $2}' |sed 's/"//g')
	local TITLE_OLD=$(dbus get softcenter_module_shadowsocks_title)
	local PKG_TYPE_OLD=""

	# print message
	local TITLE_NEW="科学上网 ${PKG_TYPE}"
	local DESCR="科学上网 ${PKG_TYPE} for AsusWRT/Merlin platform"
	echo_date "安装版本：${PKG_NAME}_${PKG_ARCH}_${PKG_TYPE}_${PLVER}"
	
	# stop first
	local ENABLE=$(dbus get ss_basic_enable)
	if [ "${ENABLE}" == "1" -a -f "/koolshare/ss/ssconfig.sh" ];then
		echo_date "安装前先关闭${TITLE_OLD}插件，保证文件更新成功！"
		sh /koolshare/ss/ssconfig.sh stop >/dev/null 2>&1
	fi

	# backup some file first
	if [ -n "$(ls /koolshare/ss/postscripts/P*.sh 2>/dev/null)" ];then
		echo_date "备份触发脚本!"
		mkdir /tmp/ss_backup
		find /koolshare/ss/postscripts -name "P*.sh" | xargs -i mv {} -f /tmp/ss_backup
	fi

	# check old version type
	if [ -f "/koolshare/webs/Module_shadowsocks.asp" ];then
		PKG_TYPE_OLD="$(get_pkg_field_from_file /koolshare/webs/Module_shadowsocks.asp "TYPE")"
		[ -z "${PKG_TYPE_OLD}" ] && PKG_TYPE_OLD="$(dbus get ss_basic_pkg_type)"
		# 已经安装，此次为升级
		if [ "${PKG_TYPE_OLD}" = "lite" ];then
			OLD_TYPE="lite"
		else
			OLD_TYPE="full"
		fi
	else
		# 没有安装，此次为全新安装
		OLD_TYPE=""
	fi

	# full → lite, backup nodes
	if [ "${PKG_TYPE}" == "lite" -a "${OLD_TYPE}" == "full" ];then
		echo_date "当前版本：full，即将安装：lite"
		full2lite
	fi
	
	# lite → full, restore nodes
	if [ "${PKG_TYPE}" == "full" -a "${OLD_TYPE}" == "lite" ];then
		# only restore backup node when upgrade fancyss from lite to full
		echo_date "当前版本：lite，即将安装：full"
		lite2full
	fi

	# check empty node
	check_empty_node
	cleanup_legacy_smartdns_user_configs "${OLD_VER}"

	# remove some file first
	echo_date "清理旧文件"
	rm -rf /koolshare/ss/*
	rm -rf /koolshare/scripts/ss_*
	rm -rf /koolshare/webs/Module_shadowsocks*
	rm -rf /koolshare/bin/rss-redir
	rm -rf /koolshare/bin/rss-tunnel
	rm -rf /koolshare/bin/rss-local
	rm -rf /koolshare/bin/obfs-local
	rm -rf /koolshare/bin/dns2socks
	rm -rf /koolshare/bin/kcptun
	rm -rf /koolshare/bin/chinadns-ng
	rm -rf /koolshare/bin/xray
	rm -rf /koolshare/bin/curl-fancyss
	rm -rf /koolshare/bin/hysteria2
	rm -rf /koolshare/bin/haveged
	rm -rf /koolshare/bin/naive
	rm -rf /koolshare/bin/anytls-zig
	rm -rf /koolshare/bin/ipt2socks
	rm -rf /koolshare/bin/dnsclient
	rm -rf /koolshare/bin/smartdns
	rm -rf /koolshare/res/icon-shadowsocks.png
	rm -rf /koolshare/res/arrow-down.gif
	rm -rf /koolshare/res/arrow-up.gif
	rm -rf /koolshare/res/ss-menu.js
	rm -rf /koolshare/res/qrcode.js
	rm -rf /koolshare/res/tablednd.js
	rm -rf /koolshare/res/shadowsocks.css
	rm -rf /koolshare/res/fancyss.css
	find /koolshare/init.d/ -name "*shadowsocks.sh" | xargs rm -rf
	find /koolshare/init.d/ -name "*socks5.sh" | xargs rm -rf
	# optional file maybe exist should be removed, but no need remove on install/upgrade


	# optional file maybe exist should be removed, remove on install
	rm -rf /koolshare/bin/dig
	rm -rf /koolshare/bin/speederv1
	rm -rf /koolshare/bin/speederv2
	rm -rf /koolshare/bin/udp2raw
	rm -rf /koolshare/bin/tuic-client

	# some file may exist in /data
	if [ -d "/data" ];then
		rm -rf /data/xray >/dev/null 2>&1
		rm -rf /data/v2ray >/dev/null 2>&1
		rm -rf /data/hysteria2 >/dev/null 2>&1
		rm -rf /data/naive >/dev/null 2>&1
		rm -rf /data/anytls-zig >/dev/null 2>&1
		rm -rf /data/sslocal >/dev/null 2>&1
		rm -rf /data/rss-local >/dev/null 2>&1
		rm -rf /data/rss-redir >/dev/null 2>&1
		# legacy since 3.3.6
		rm -rf /data/ss-local >/dev/null 2>&1
		rm -rf /data/ss-redir >/dev/null 2>&1
		rm -rf /data/ss-tunnel >/dev/null 2>&1
	fi
	
	# legacy files should be removed
	rm -rf /koolshare/bin/v2ray
	rm -rf /koolshare/bin/uredir
	rm -rf /koolshare/bin/dns-ecs-forcer
	rm -rf /koolshare/bin/dns2tcp
	rm -rf /koolshare/bin/sslocal
	rm -rf /koolshare/bin/httping
	rm -rf /koolshare/bin/v2ray-plugin
	rm -rf /koolshare/bin/trojan
	rm -rf /koolshare/bin/haproxy
	rm -rf /koolshare/bin/dohclient
	rm -rf /koolshare/bin/dohclient-cache
	rm -rf /koolshare/bin/v2ctl
	rm -rf /koolshare/bin/dnsmasq
	rm -rf /koolshare/bin/Pcap_DNSProxy
	rm -rf /koolshare/bin/client_linux_arm*
	rm -rf /koolshare/bin/cdns
	rm -rf /koolshare/bin/chinadns
	rm -rf /koolshare/bin/chinadns1
	rm -rf /koolshare/bin/https_dns_proxy
	rm -rf /koolshare/bin/pdu
	rm -rf /koolshare/bin/koolgame
	rm -rf /koolshare/bin/dnscrypt-proxy
	rm -rf /koolshare/bin/resolveip
	rm -rf /koolshare/bin/ss-redir
	rm -rf /koolshare/bin/ss-tunnel
	rm -rf /koolshare/bin/ss-local
	rm -rf /koolshare/res/all.png
	rm -rf /koolshare/res/gfw.png
	rm -rf /koolshare/res/chn.png
	rm -rf /koolshare/res/game.png

	# these file maybe used by others plugin, do not remove
	# rm -rf /koolshare/bin/sponge >/dev/null 2>&1
	# rm -rf /koolshare/bin/jq
	# rm -rf /koolshare/bin/isutf8
	
	cleanup_jffs_install_tmp

	# small jffs router should remove more existing files
	if [ "${MODEL}" == "RT-AX56U_V2" -o "${MODEL}" == "RT-AX57" ];then
		rm -rf /jffs/wglist*
		rm -rf /jffs/.sys/diag_db/*
		# make a dummy
		rm -rf /jffs/uu.tar.gz*
		touch /jffs/uu.tar.gz
	elif [ "${MODEL}" == "ZenWiFi_BD4" ];then
		rm -rf /jffs/ahs
		rm -rf /jffs/asd
		rm -rf /jffs/curllst*
		rm -rf /jffs/wglist*
		rm -rf /jffs/asd.log
		rm -rf /jffs/webs_upgrade.log*
		rm -rf /jffs/.sys/diag_db/*
		rm -rf /jffs/uu.tar.gz*
	fi
	echo 1 > /proc/sys/vm/drop_caches
	sync

	# package modify

	# curl-fancyss is not needed when curl in system support proxy (102 official mod and merlin mod have proxy enabled)
	local CURL_PROXY_FLAG=$(curl -V|grep -Eo proxy)
	if [ -n "${CURL_PROXY_FLAG}" ];then
		rm -rf /tmp/shadowsocks/bin/curl-fancyss
		ln -sf $(which curl) /koolshare/bin/curl-fancyss
	fi

	# jq is included in official 102 stock firmware higher version(RT-BE86U)
	if [ -f /usr/bin/jq ];then
		rm -rf /tmp/shadowsocks/bin/jq
		if [ ! -L /koolshare/bin/jq ];then
			ln -sf /usr/bin/jq /koolshare/bin/jq
		fi
	fi
	
	# some file in package no need to install
	if [ -n "$(which socat)" ];then
		rm -rf /tmp/shadowsocks/bin/uredir
	fi

	prepare_websocketd_package

	# 将一些较大的二进制文件安装到/data分区，以节约jffs分区空间
	# 1. 卸载的时候记得删除/data分区内的二进制
	# 2. 打包的时候应该用/data分区内的二进制
	# 3. 更新二进制的时候应该检测/koolshare/bin下的是否为软连接，是的话应该更新真实位置的二进制
	check_device "/data"
	if [ "$?" == "0" ];then
		# 检测data分区剩余空间
		echo_date "检测/data分区剩余空间..."
		local SPACE_DATA_AVAL1=$(df | grep -w "/data" | awk '{print $4}')
		echo_date "/data分区剩余空间为：${SPACE_DATA_AVAL1}KB"
		# FORK: cut in doge.10, see doc/design/protocol-roadmap.md §2 — removed naive (kept hysteria2 even though unused — out of scope)
		local _BINS="xray v2ray hysteria2 anytls-zig sslocal rss-local rss-tunnel rss-redir"
		for _BIN in ${_BINS}
		do
			if [ -f "/tmp/shadowsocks/bin/${_BIN}" ];then
				local SPACE_DATA_AVAL1=$(df | grep -w "/data" | awk '{print $4}')
				local SPACE_DATA_AVAL2=$((${SPACE_DATA_AVAL1} - 256))
				local BIN_SIZE=$(du /tmp/shadowsocks/bin/${_BIN} | awk '{print $1}')
				if [ "${BIN_SIZE}" -lt "${SPACE_DATA_AVAL2}" ];then
					echo_date "将${_BIN}安装到/data分区..."
					mv /tmp/shadowsocks/bin/${_BIN} /data/
					chmod +x /data/${_BIN} 
					ln -sf /data/${_BIN} /koolshare/bin/${_BIN}
				fi
				sync
			fi
		done
	fi

	# 检测jffs储存空间是否足够
	echo_date "检测jffs分区剩余空间..."

	SPACE_AVAL=$(df | grep -w "/jffs" | awk '{print $4}')
	JFFS_FS_TYPE=$(mount | awk '$3 == "/jffs" {print $5; exit}')
	SPACE_TREE_NEED=$(du -s /tmp/shadowsocks 2>/dev/null | awk '{print $1}')
	cd /tmp
	tar -cz -f /tmp/test_size.tar.gz shadowsocks/
	if [ -f "/tmp/test_size.tar.gz" ];then
		SPACE_PACK_NEED=$(du -s /tmp/test_size.tar.gz | awk '{print $1}')
		rm -rf /tmp/test_size.tar.gz
	else
		SPACE_PACK_NEED=""
	fi
	[ -n "${SPACE_TREE_NEED}" ] || SPACE_TREE_NEED=0
	[ -n "${SPACE_PACK_NEED}" ] || SPACE_PACK_NEED=${SPACE_TREE_NEED}
	case "${JFFS_FS_TYPE}" in
		ext2|ext3|ext4)
			SPACE_NEED=${SPACE_TREE_NEED}
			SPACE_BASIS="候选文件夹占用"
			;;
		*)
			SPACE_NEED=${SPACE_PACK_NEED}
			SPACE_BASIS="候选包大小"
			;;
	esac
	SPACE_MARGIN=$((SPACE_NEED / 10))
	[ "${SPACE_MARGIN}" -lt "2048" ] && SPACE_MARGIN=2048
	SPACE_NEED=$((SPACE_NEED + SPACE_MARGIN))
	[ -n "${JFFS_FS_TYPE}" ] || JFFS_FS_TYPE="unknown"
	echo_date "当前jffs分区(${JFFS_FS_TYPE})剩余${SPACE_AVAL}KB"
	echo_date "插件安装预计需要约${SPACE_NEED}KB（${SPACE_BASIS}+动态余量${SPACE_MARGIN}KB）"
	if [ "${SPACE_AVAL}" -gt "${SPACE_NEED}" ];then
		echo_date "空间满足，继续安装！"
	else
		echo_date "空间不足，退出安装！"
		exit_install 1
	fi

	# isntall file
	echo_date "开始复制文件！"
	cd /tmp	

	echo_date "复制相关二进制文件！此步时间可能较长！"
	prepare_websocketd_for_copy
	cp -rf /tmp/shadowsocks/bin/* /koolshare/bin/
	
	echo_date "复制相关的脚本文件！"
	cp -rf /tmp/shadowsocks/ss /koolshare/
	cp -rf /tmp/shadowsocks/scripts/* /koolshare/scripts/
	cp -rf /tmp/shadowsocks/install.sh /koolshare/scripts/ss_install.sh
	cp -rf /tmp/shadowsocks/uninstall.sh /koolshare/scripts/uninstall_shadowsocks.sh
	
	echo_date "复制相关的网页文件！"
	cp -rf /tmp/shadowsocks/webs/* /koolshare/webs/
	sync_pkg_meta_runtime /tmp/shadowsocks/webs/Module_shadowsocks.asp
	local _LAYJS_MD5=$(md5sum /koolshare/res/layer/layer.js | awk '{print $1}')
	if [ -f "/koolshare/res/layer/layer.js" -a "${_LAYJS_MD5}" == "9d72838d6f33e45f058cc1fa00b7a5c7" ];then
		mv -f /tmp/shadowsocks/res/layer.js /koolshare/res/layer/
	else
		rm /tmp/shadowsocks/res/layer.js >/dev/null 2>&1
	fi
	cp -rf /tmp/shadowsocks/res/* /koolshare/res/
	sync

	# Permissions
	echo_date "为新安装文件赋予执行权限..."
	chmod 755 /koolshare/ss/rules/* >/dev/null 2>&1
	chmod 755 /koolshare/ss/* >/dev/null 2>&1
	chmod 755 /koolshare/scripts/ss* >/dev/null 2>&1
	chmod 755 /koolshare/bin/* >/dev/null 2>&1
	
	# intall different UI
	set_skin

	# restore backup
	if [ -n "$(ls /tmp/ss_backup/P*.sh 2>/dev/null)" ];then
		echo_date "恢复触发脚本!"
		mkdir -p /koolshare/ss/postscripts
		find /tmp/ss_backup -name "P*.sh" | xargs -i mv {} -f /koolshare/ss/postscripts
	fi

	# soft links
	echo_date "创建一些二进制文件的软链接！"
	[ ! -L "/koolshare/bin/rss-tunnel" ] && ln -sf /koolshare/bin/rss-local /koolshare/bin/rss-tunnel
	[ ! -L "/koolshare/init.d/S99shadowsocks.sh" ] && ln -sf /koolshare/ss/ssconfig.sh /koolshare/init.d/S99shadowsocks.sh
	[ ! -L "/koolshare/init.d/N99shadowsocks.sh" ] && ln -sf /koolshare/ss/ssconfig.sh /koolshare/init.d/N99shadowsocks.sh

	# default values
	eval $(dbus export ss)
	local PKG_TYPE=$(cat /koolshare/webs/Module_shadowsocks.asp | tr -d '\r' | grep -Eo "PKG_TYPE=.+"|awk -F "=" '{print $2}'|sed 's/"//g')

	[ -z "${ss_basic_proxy_newb}" ] && dbus set ss_basic_proxy_newb=1
	[ -z "${ss_basic_proxy_ipv6}" ] && dbus set ss_basic_proxy_ipv6=0
	[ -z "${ss_basic_udpoff}" ] && dbus set ss_basic_udpoff=1
	[ -z "${ss_basic_udpall}" ] && dbus set ss_basic_udpall=0
	# 兼容，仅chatgpt删除掉了（3.4.13），ss_basic_udpoff和ss_basic_udpall必须有一个等于1
	if [ "${ss_basic_udpoff}" != "1" -a "${ss_basic_udpall}" != "1" ];then
		ss_basic_udpoff=1
		ss_basic_udpall=0
		dbus set ss_basic_udpoff=1
		dbus set ss_basic_udpall=0
	fi
	[ -z "${ss_basic_nonetcheck}" ] && dbus set ss_basic_nonetcheck=1
	[ -z "${ss_basic_notimecheck}" ] && dbus set ss_basic_notimecheck=1
	[ -z "${ss_basic_nocdnscheck}" ] && dbus set ss_basic_nocdnscheck=1
	[ -z "${ss_basic_nofdnscheck}" ] && dbus set ss_basic_nofdnscheck=1
	[ -z "${ss_basic_noruncheck}" ] && dbus set ss_basic_noruncheck=1
	[ -z "${ss_basic_qrcode}" ] && dbus set ss_basic_qrcode=1
	[ -z "${ss_basic_node_cards}" ] && dbus set ss_basic_node_cards=1

	[ -z "${ss_basic_chng_xact}" ] && dbus set ss_basic_chng_xact=0
	[ -z "${ss_basic_chng_xgt}" ] && dbus set ss_basic_chng_xgt=1
	[ -z "${ss_basic_chng_xmc}" ] && dbus set ss_basic_chng_xmc=0
	
	# others
	fss_cleanup_acl_default_port_keys >/dev/null 2>&1
	# 旧故障转移字段一次性迁移到新备用组合列表（幂等，详见 doc/design/failover-combo-list-design.md §3.2）
	migrate_failover_v1
	# combo 前缀重命名 v2：fss_failover_combo_* → ss_failover_combo_*（CLAUDE.md 硬规则 #1）
	migrate_failover_v2
	# FORK doge.12 alpha：分流架构（Rule + Mode + per-User + 双轨 DNS）数据迁移
	# 详见 doc/implementation/split-routing-implementation.md / doc/design/split-routing-architecture.md §14
	# 仅写数据；ss_split_enabled 默认 0，路由层走旧逻辑——老用户升级零感知。
	migrate_split_routing_v1
	# FORK doge.13 beta：DNS upstream 老 key → 新 ss_split_dns_*_upstream 一次性迁移（base64 编码、不删老 key）
	migrate_split_routing_v2
	# FORK doge.13 beta.2：清洗 ss_split_dns_*_upstream 末尾控制字符（修 skipd 弹窗根因，base64_encode 周期追 TAB 问题）
	migrate_split_routing_v3
	# FORK doge.12 alpha 总开关：=0 路由走旧路径（默认）；=1 启用新架构（实验性）。
	# 首次安装/升级时若未设置则种 0，已有值不覆盖。
	[ -z "$(dbus get ss_split_enabled)" ] && dbus set ss_split_enabled="0"
	# FORK doge.12 alpha：分流 Rule 自动更新 cron（每 30 分钟扫一次；详见 doc/design/split-routing-architecture.md §10.3）。
	# alpha 期内置 Rule 全部 update_hours=0，cron 跑等于 no-op；脚本里有守护跳过。
	# 用户自定义 Rule + 设置 update_hours>0 + 配置 source_url 才会真正下载。
	cru d fancyss_rules_update >/dev/null 2>&1
	cru a fancyss_rules_update "*/30 * * * * /bin/sh /koolshare/scripts/fss_rules_update.sh"
	# FORK doge.10：删除老的 SSR/Naive/Tuic 节点 + 清理引用（详见 doc/design/protocol-roadmap.md §2）
	migrate_doge10_drop_legacy_protocols
	# fork toggle（doge.9）：「直连 AsusGo / koolcenter 生态域名」首次安装默认开启
	# 详见 doc/implementation/asusgo-whitelist-toggle.md
	[ -z "$(dbus get ss_basic_direct_asusgo)" ] && dbus set ss_basic_direct_asusgo=1
	# fork toggle（doge.11）：「国内公共 DNS 服务器强制直连」(G1) 首次安装默认开启（向后兼容）
	# 控制 223.5.5.5/114.114.114.114 等 10 个国内 DNS IP 是否进 ignlist，详见 doc/design/protocol-roadmap.md §7 doge.11 G1
	[ -z "$(dbus get ss_basic_direct_chndns)" ] && dbus set ss_basic_direct_chndns=1
	# fork toggle（doge.11）：「启动时联网检测公网 IP/时间」(G6) 首次安装默认开启（向后兼容）
	# 控制 worldtimeapi/ddnsto/clang/akamai/myip 5 个第三方上送 IP 探测，详见 doc/design/protocol-roadmap.md §7 doge.11 G6
	[ -z "$(dbus get ss_basic_online_ipcheck)" ] && dbus set ss_basic_online_ipcheck=1
	[ -z "$(dbus get ss_acl_default_mode)" ] && dbus set ss_acl_default_mode=follow
	[ -z "$(dbus get ss_acl_default_mode_format)" ] && dbus set ss_acl_default_mode_format=2
	[ -z "$(dbus get ss_acl_default_udp)" ] && dbus set ss_acl_default_udp=0
	[ -z "$(dbus get ss_acl_default_quic)" ] && dbus set ss_acl_default_quic=1
	[ -z "$(dbus get ss_acl_default_ports)" ] && dbus set ss_acl_default_ports="22,80,443,8080,8443"
	[ -z "$(dbus get ss_basic_interval)" ] && dbus set ss_basic_interval=2
	[ -z "$(dbus list ss_basic_status_mode 2>/dev/null | sed -n '1p')" ] && dbus set ss_basic_status_mode=serve
	[ -z "$(dbus get ss_basic_furl)" ] && dbus set ss_basic_furl="http://www.google.com/generate_204"
	[ -z "$(dbus get ss_basic_curl)" ] && dbus set ss_basic_curl="http://connectivitycheck.platform.hicloud.com/generate_204"

	# 延迟测试默认开启，所有平台默认显示 web 落地延迟列
	dbus set ss_basic_latency_val="2"
	dbus set ss_basic_latency_batch="1"

	# 因版本变化导致一些值没有了，更改一下
	if [ "${ss_basic_chng_china_2_tcp}" == "5" ];then
		dbus set ss_basic_chng_china_2_tcp="6"
	fi

	# 某些版本不含ss-rust，默认由xray运行ss协议
	if [ ! -x "/koolshare/bin/sslocal" ];then
		dbus set ss_basic_score=1
		ss_basic_score=1
	else
		dbus set ss_basic_score=0
		ss_basic_score=0
	fi

	local MIGRATED_SUB_PROFILES=""
	if subprof_migrate_legacy_profiles_if_needed >/tmp/sub_profile_migrate.count 2>/dev/null; then
		MIGRATED_SUB_PROFILES="$(cat /tmp/sub_profile_migrate.count 2>/dev/null)"
		subprof_rebuild_cron_jobs >/dev/null 2>&1 || true
		rm -f /tmp/sub_profile_migrate.count >/dev/null 2>&1
	fi

	# 节点存储自动迁移：升级到支持 schema 2 的版本后，直接切换到新结构。
	export PATH=/koolshare/bin:${PATH}
	if [ -x "/koolshare/bin/node-tool" ];then
		FSS_NODE_TOOL_PICKED="/koolshare/bin/node-tool"
		FSS_NODE_TOOL_TRUST_PICKED=1
		export FSS_NODE_TOOL_PICKED FSS_NODE_TOOL_TRUST_PICKED
	elif [ -x "${DIR}/bin/node-tool" ];then
		FSS_NODE_TOOL_PICKED="${DIR}/bin/node-tool"
		FSS_NODE_TOOL_TRUST_PICKED=1
		export FSS_NODE_TOOL_PICKED FSS_NODE_TOOL_TRUST_PICKED
	else
		unset FSS_NODE_TOOL_PICKED
		unset FSS_NODE_TOOL_TRUST_PICKED
	fi
	if [ -n "${FSS_NODE_TOOL_PICKED:-}" ];then
		echo_date "节点数据升级将优先使用 node-tool：${FSS_NODE_TOOL_PICKED}"
		local NODE_TOOL_VERSION_OUTPUT=""
		local NODE_TOOL_MIN_VERSION="0.1.8"
		NODE_TOOL_VERSION_OUTPUT="$("${FSS_NODE_TOOL_PICKED}" version 2>&1)"
		local NODE_TOOL_VERSION_RC="$?"
		if [ "${NODE_TOOL_VERSION_RC}" != "0" ];then
			NODE_TOOL_VERSION_OUTPUT="$(env -i PATH="/koolshare/bin:/usr/sbin:/usr/bin:/sbin:/bin" "${FSS_NODE_TOOL_PICKED}" version 2>&1)"
			NODE_TOOL_VERSION_RC="$?"
			if [ "${NODE_TOOL_VERSION_RC}" = "0" ];then
				FSS_NODE_TOOL_CLEAN_ENV=1
				export FSS_NODE_TOOL_CLEAN_ENV
				echo_date "node-tool 版本：${NODE_TOOL_VERSION_OUTPUT}（安装环境较大，迁移时使用干净环境执行）"
			else
				echo_date "node-tool 版本探测失败（退出码 ${NODE_TOOL_VERSION_RC}），后续将自动回退 shell 迁移流程。"
				if [ -n "${NODE_TOOL_VERSION_OUTPUT}" ];then
					echo_date "node-tool 版本探测输出：${NODE_TOOL_VERSION_OUTPUT}"
				fi
				unset FSS_NODE_TOOL_PICKED
				unset FSS_NODE_TOOL_TRUST_PICKED
				unset FSS_NODE_TOOL_CLEAN_ENV
			fi
		else
			echo_date "node-tool 版本：${NODE_TOOL_VERSION_OUTPUT}"
		fi
		if [ -n "${FSS_NODE_TOOL_PICKED:-}" ] && ! version_ge "${NODE_TOOL_VERSION_OUTPUT}" "${NODE_TOOL_MIN_VERSION}";then
			echo_date "node-tool 版本低于 ${NODE_TOOL_MIN_VERSION}，旧版 schema1 迁移可能丢失默认字段，回退 shell 迁移流程。"
			unset FSS_NODE_TOOL_PICKED
			unset FSS_NODE_TOOL_TRUST_PICKED
			unset FSS_NODE_TOOL_CLEAN_ENV
		fi
	fi
	local STORAGE_SCHEMA_BEFORE="$(fss_detect_storage_schema 2>/dev/null)"
	fss_auto_migrate_if_needed 1 report_install_migration_progress
	case "$?" in
	0)
		if [ "$(dbus get fss_data_schema)" = "2" ];then
			echo_date "节点数据已经升级到 schema 2 存储。"
		fi
		;;
	2)
		if [ "$(fss_detect_storage_schema 2>/dev/null)" != "2" ];then
			fss_mark_native_schema2_storage >/dev/null 2>&1 || true
		fi
		;;
	*)
		echo_date "节点数据升级到 schema 2 失败，保留旧版节点结构。"
		;;
	esac

	if [ "$(fss_detect_storage_schema 2>/dev/null)" = "2" ];then
		if [ "${STORAGE_SCHEMA_BEFORE}" != "2" ];then
			if [ "$(dbus get fss_data_secret_mode 2>/dev/null)" = "raw" ];then
				echo_date "schema1 -> schema2 升级已使用 raw 密码字段，跳过密码字段二次校正。"
			else
				normalize_schema2_secret_fields_after_install "schema1 -> schema2 升级"
			fi
		elif [ "${FORCE_SCHEMA2_SECRET_NORMALIZE}" = "1" ]; then
			normalize_schema2_secret_fields_after_install "旧版 schema2 数据纠偏" "1"
		fi
		normalize_schema2_anytls_pass_after_install "旧版 AnyTLS 数据纠偏"
	fi

	# 链式代理前置节点健康检查（fork 新增，仅日志）
	if [ "$(fss_detect_storage_schema 2>/dev/null)" = "2" ];then
		local _front_id="$(dbus get ssconf_basic_node_front 2>/dev/null)"
		if [ -n "${_front_id}" ];then
			if fss_get_node_field_plain "${_front_id}" "type" >/dev/null 2>&1;then
				echo_date "链式代理前置节点 ID ${_front_id} 在 schema 2 节点存储中存在，前置代理配置完好。"
			else
				echo_date "⚠️ 链式代理前置节点 ID ${_front_id} 在 schema 2 节点存储中已不存在（节点可能被删除或订阅更新）。dbus 值已保留，前端会显示节点缺失提示，请重新选择前置节点。"
			fi
		fi
	fi

	if [ -n "${MIGRATED_SUB_PROFILES}" ]; then
		echo_date "旧版订阅地址已迁移为 ${MIGRATED_SUB_PROFILES} 个独立订阅配置。"
	fi

	if [ "$(fss_detect_storage_schema 2>/dev/null)" = "2" ] && [ "$(dbus get fss_data_source_meta_repaired 2>/dev/null)" != "1" ];then
		echo_date "检查旧版订阅节点来源归属..."
		local repaired_sub_nodes="$(fss_repair_legacy_subscribe_source_meta 2>/dev/null)"
		if [ "${repaired_sub_nodes:-0}" -gt 0 ] 2>/dev/null;then
			echo_date "已修复 ${repaired_sub_nodes} 个旧版订阅节点的来源归属。"
		fi
		dbus set fss_data_source_meta_repaired=1
	fi

	if [ "${FORCE_LEGACY_CACHE_RESET}" = "1" ];then
		echo_date "检测到旧版 fancyss（${OLD_VER} < 3.6.0），强制清理节点配置缓存和 webtest 缓存..."
		invalidate_runtime_caches_after_install
		echo_date "重建节点运行缓存..."
		fss_refresh_node_json_cache >/dev/null 2>&1 || true
	else
		echo_date "刷新节点运行缓存..."
		invalidate_runtime_caches_after_install
		fss_refresh_node_json_cache >/dev/null 2>&1 || true
	fi

	# dbus value
	echo_date "设置插件安装参数..."
	dbus set ss_basic_version_local="${PLVER}"
	dbus set softcenter_module_${module}_version="${PLVER}"
	dbus set softcenter_module_${module}_install="4"
	dbus set softcenter_module_${module}_name="${module}"
	dbus set softcenter_module_${module}_title="${TITLE_NEW}"
	dbus set softcenter_module_${module}_description="${DESCR}"
	
	# finish
	echo_date "${TITLE_NEW}插件安装安装成功！"

	# restart
	if [ "${ENABLE}" == "1" -a -f "/koolshare/ss/ssconfig.sh" ];then
		echo_date 重启科学上网插件！
		sh /koolshare/ss/ssconfig.sh restart
		restart_status_runtime_async
		handle_websocketd_after_install
	else
		handle_websocketd_after_install
	fi

	echo_date "更新完毕，请等待网页自动刷新！"
	exit_install
}

install(){
	get_model
	get_fw_type
	platform_test
	install_now
}

install
