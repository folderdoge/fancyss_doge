#!/bin/sh

# fancyss script for asuswrt/merlin based router with software center

source /koolshare/scripts/ss_base.sh

LOGFILE_F=/tmp/upload/ssf_status.txt
LOGFILE_C=/tmp/upload/ssc_status.txt
LOGSTREAM_F=/tmp/upload/ssf_status.stream
LOGSTREAM_C=/tmp/upload/ssc_status.stream
STATUS_FRONT_CACHE=/tmp/upload/ss_status_front.txt
STATUS_BACK_CACHE=/tmp/upload/ss_status.txt
STATUS_STATE_FILE=/tmp/upload/ss_status_daemon.json
#LOGTIME1=📅$(TZ=UTC-8 date -R "+%m-%d/%H:%M:%S")
LOGTIME1=⌚$(TZ=UTC-8 date -R "+%H:%M:%S")
CURRENT=$(fss_get_current_node_id)
CHK_INTER=$(dbus get ss_basic_interval)
COUNT=1
LAST_CACHE=""
rm -rf /tmp/upload/test.txt

get_node_name_by_id() {
	fss_get_node_field_plain "$1" name
}

pick_fastest_webtest_node() {
	local current_id="$1"
	local result_file="${2:-/tmp/upload/webtest_bakcup.txt}"
	local latency=""
	local node_id=""

	[ -s "${result_file}" ] || return 1
	awk -F '>' -v current="${current_id}" '
		$1 ~ /^[0-9]+$/ && $1 != current {
			if (!seen[$1]) {
				order[++count] = $1
				seen[$1] = 1
			}
			latency[$1] = $2
		}
		END {
			for (i = 1; i <= count; i++) {
				id = order[i]
				if (latency[id] ~ /^[0-9]+$/) {
					printf "%d\t%s\n", latency[id], id
				}
			}
		}
	' "${result_file}" 2>/dev/null | sort -n -k1,1 -k2,2n | while read -r latency node_id
	do
		[ -n "${node_id}" ] || continue
		if fss_node_id_exists "${node_id}";then
			printf '%s\n' "${node_id}"
			return 0
		fi
	done
}

append_status_log_line() {
	local logfile="$1"
	local streamfile="$2"
	local line="$3"
	printf '%s\n' "${line}" >> "${logfile}"
	printf '%s\n' "${line}" >> "${streamfile}"
}

clean_f_log() {
	[ $(wc -l "$LOGFILE_F" | awk '{print $1}') -le "$LOG_MAX" ] && return
	local logdata=$(tail -n 500 "$LOGFILE_F")
	echo "$logdata" > $LOGFILE_F 2> /dev/null
	unset logdata
}

clean_c_log() {
	[ $(wc -l "$LOGFILE_C" | awk '{print $1}') -le "$LOG_MAX" ] && return
	local logdata=$(tail -n 500 "$LOGFILE_C")
	echo "$logdata" > $LOGFILE_C 2> /dev/null
	unset logdata
}

LOGM() {
	echo $1
	logger $1
}

pick_jq_bin() {
	if command -v jq >/dev/null 2>&1; then
		command -v jq
		return 0
	fi
	if [ -x "/koolshare/bin/jq" ]; then
		echo "/koolshare/bin/jq"
		return 0
	fi
	return 1
}

extract_status_ms() {
	printf '%s' "$1" | grep -Eo '[0-9]+ ms' | tail -n1 | awk '{print $1}'
}

status_line_ok() {
	printf '%s' "$1" | grep -q "✓"
}

status_cache_foreign_line() {
	printf '%s' "$1" | awk -F '@@' '{print $1}'
}

status_cache_china_line() {
	printf '%s' "$1" | awk -F '@@' '{print $NF}'
}

status_probe_host() {
	local host="$1"
	host="${host#*://}"
	host="${host%%/*}"
	host="${host%%:*}"
	host="${host#www.}"
	printf '%s' "${host}"
}

status_daemon_state_snapshot() {
	local jq_bin=""
	[ -s "${STATUS_STATE_FILE}" ] || return 1
	jq_bin="$(pick_jq_bin)" || return 1
	"${jq_bin}" -r '
		def pick($name):
			((.results // []) | map(select(.name == $name)) | .[0]) // {};
		[
			((pick("foreign4").ok // false) | tostring),
			((pick("foreign4").status_code // 0) | tostring),
			((pick("foreign4").elapsed_ms // 0) | tostring),
			((pick("china").ok // false) | tostring),
			((pick("china").status_code // 0) | tostring),
			((pick("china").elapsed_ms // 0) | tostring)
		] | @tsv
	' "${STATUS_STATE_FILE}" 2>/dev/null
}

write_status_logs_from_cache() {
	local cache_payload="$1"
	local current_name="$(get_node_name_by_id "$(fss_get_current_node_id)")"
	local foreign_line="$(status_cache_foreign_line "${cache_payload}")"
	local china_line="$(status_cache_china_line "${cache_payload}")"
	local foreign_ms="$(extract_status_ms "${foreign_line}")"
	local china_ms="$(extract_status_ms "${china_line}")"
	local foreign_url="$(dbus get ss_basic_furl)"
	local china_url="$(dbus get ss_basic_curl)"
	local foreign_host=""
	local china_host=""
	local foreign_ok=""
	local foreign_code=""
	local china_ok=""
	local china_code=""
	local snapshot=""
	local loop_count="${COUNT}"

	[ -n "${foreign_url}" ] || foreign_url="http://www.google.com/generate_204"
	[ -n "${china_url}" ] || china_url="http://connectivitycheck.platform.hicloud.com/generate_204"
	foreign_host="$(status_probe_host "${foreign_url}")"
	china_host="$(status_probe_host "${china_url}")"
	[ -n "${foreign_host}" ] || foreign_host="foreign"
	[ -n "${china_host}" ] || china_host="china"

	snapshot="$(status_daemon_state_snapshot)" || snapshot=""
	if [ -n "${snapshot}" ]; then
		IFS='	' read -r foreign_ok foreign_code foreign_ms china_ok china_code china_ms <<-EOF
		${snapshot}
		EOF
	fi

	[ -n "${foreign_ok}" ] || foreign_ok="$(status_line_ok "${foreign_line}" && echo true || echo false)"
	[ -n "${china_ok}" ] || china_ok="$(status_line_ok "${china_line}" && echo true || echo false)"
	[ -n "${foreign_code}" ] || foreign_code="$([ "${foreign_ok}" = "true" ] && echo 200 || echo 000)"
	[ -n "${china_code}" ] || china_code="$([ "${china_ok}" = "true" ] && echo 200 || echo 000)"

	LOGTIME1=⌚$(TZ=UTC-8 date -R "+%H:%M:%S")
	if [ "${foreign_ok}" = "true" ]; then
		append_status_log_line "${LOGFILE_F}" "${LOGSTREAM_F}" "${LOGTIME1} ➡️ ${foreign_host} ⏱ ${foreign_ms} ms 🌎 ${foreign_code} OK ✈️ ${current_name} 🧮${loop_count}"
	else
		append_status_log_line "${LOGFILE_F}" "${LOGSTREAM_F}" "${LOGTIME1} ➡️ ${foreign_host} ⏱ --- ms 🌎 ${foreign_code} failed ✈️ ${current_name} 🧮${loop_count}"
	fi
	if [ "${china_ok}" = "true" ]; then
		append_status_log_line "${LOGFILE_C}" "${LOGSTREAM_C}" "${LOGTIME1} ➡️ ${china_host} ⏱ ${china_ms} ms 🌎 ${china_code} OK 🧮${loop_count}"
	else
		append_status_log_line "${LOGFILE_C}" "${LOGSTREAM_C}" "${LOGTIME1} ➡️ ${china_host} ⏱ --- ms 🌎 ${china_code} failed 🧮${loop_count}"
	fi
}

refresh_status_cache_files() {
	local cache_payload=""
	cache_payload="$(cat "${STATUS_FRONT_CACHE}" 2>/dev/null)"
	[ -n "${cache_payload}" ] || return 1
	printf '%s@@%s\n' "${cache_payload}" "$(dbus get ss_heart_beat)" > "${STATUS_BACK_CACHE}"
	if [ "${cache_payload}" != "${LAST_CACHE}" ];then
		LAST_CACHE="${cache_payload}"
		write_status_logs_from_cache "${cache_payload}"
		return 0
	fi
	return 2
}

_get_interval() {
	case "$CHK_INTER" in
	1)
		echo "0-1000"
		;;
	2)
		echo "2000-5000"
		;;
	3)
		echo "6000-13000"
		;;
	4)
		echo "14000-29000"
		;;
	5)
		echo "30000-61000"
		;;
	esac
}

failover_action(){
	FLAG=$1
	PING=$2
	local current_id=$(fss_get_current_node_id)
	local current_name=$(get_node_name_by_id "${current_id}")
	if [ "$ss_failover_s4_1" == "0" ];then
		[ "$FLAG" == "1" ] && LOGM "$LOGTIME1 fancyss：检测到连续$ss_failover_s1个状态故障，关闭插件！"
		[ "$FLAG" == "2" ] && LOGM "$LOGTIME1 fancyss：检测到最近$ss_failover_s2_1个状态中，故障次数超过$ss_failover_s2_2个，关闭插件！"
		[ "$FLAG" == "3" ] && LOGM "$LOGTIME1 fancyss：检测到最近$ss_failover_s3_1个状态平均延迟:$PING超过$ss_failover_s3_2 ms，关闭插件！"
		dbus set ss_basic_enable="0"
		# 关闭
		dbus set ss_heart_beat="1"
		run start-stop-daemon -S -q -b -x /koolshare/ss/ssconfig.sh -- stop
	elif [ "$ss_failover_s4_1" == "1" ];then
		[ "$FLAG" == "1" ] && LOGM "$LOGTIME1 fancyss：检测到连续$ss_failover_s1个状态故障，重启插件！"
		[ "$FLAG" == "2" ] && LOGM "$LOGTIME1 fancyss：检测到最近$ss_failover_s2_1个状态中，故障次数超过$ss_failover_s2_2个，重启插件！"
		[ "$FLAG" == "3" ] && LOGM "$LOGTIME1 fancyss：检测到最近$ss_failover_s3_1个状态平均延迟:$PING超过$ss_failover_s3_2 ms，重启插件！"
		# alpha.17 修：标记内部 restart，防止 ssconfig.sh 入口清掉 failover combo 的 failed 标志
		dbus set fss_failover_internal_restart="2"
		# 重启
		run start-stop-daemon -S -q -b -x /koolshare/ss/ssconfig.sh -- restart
	elif [ "$ss_failover_s4_1" == "2" ];then
		# 备用组合列表模式（fork 新增，详见 doc/design/failover-combo-list-design.md §4.1）
		local cur_front=$(dbus get ssconf_basic_node_front)
		local cur_landing="${current_id}"

		# 1. 在列表里找匹配项 → 标记 failed=1（找不到说明 runtime 不在列表里，跳过）
		local match_idx=$(fss_failover_find_combo "${cur_front}" "${cur_landing}")
		if [ -n "${match_idx}" ]; then
			dbus set "ss_failover_combo_${match_idx}_failed"="1"
			[ "$FLAG" == "1" ] && LOGM "$LOGTIME1 fancyss：检测到连续$ss_failover_s1个状态故障，标记当前组合 #${match_idx} 失效..."
			[ "$FLAG" == "2" ] && LOGM "$LOGTIME1 fancyss：检测到最近$ss_failover_s2_1个状态中，故障次数超过$ss_failover_s2_2个，标记当前组合 #${match_idx} 失效..."
			[ "$FLAG" == "3" ] && LOGM "$LOGTIME1 fancyss：检测到最近$ss_failover_s3_1个状态平均延迟:$PING超过$ss_failover_s3_2 ms，标记当前组合 #${match_idx} 失效..."
		else
			[ "$FLAG" == "1" ] && LOGM "$LOGTIME1 fancyss：检测到连续$ss_failover_s1个状态故障，但当前 runtime 不在备用组合列表中..."
			[ "$FLAG" == "2" ] && LOGM "$LOGTIME1 fancyss：检测到最近$ss_failover_s2_1个状态中，故障次数超过$ss_failover_s2_2个，但当前 runtime 不在备用组合列表中..."
			[ "$FLAG" == "3" ] && LOGM "$LOGTIME1 fancyss：检测到最近$ss_failover_s3_1个状态平均延迟:$PING超过$ss_failover_s3_2 ms，但当前 runtime 不在备用组合列表中..."
		fi

		# 2. 顺序扫描，找第一个 failed=0 且与当前 runtime 不同的
		local next_idx=$(fss_failover_pick_next_available "${cur_front}" "${cur_landing}")
		if [ -z "${next_idx}" ]; then
			LOGM "$LOGTIME1 fancyss：所有备用组合已失效，保持当前状态以便用户察觉..."
			return
		fi

		# 3. 切换 runtime
		local new_front=$(dbus get "ss_failover_combo_${next_idx}_front_id")
		local new_landing=$(dbus get "ss_failover_combo_${next_idx}_landing_id")
		local new_landing_name=$(get_node_name_by_id "${new_landing}")
		local mode_label="链式"
		[ -z "${new_front}" ] && mode_label="直连"
		LOGM "$LOGTIME1 fancyss：切换到备用组合 #${next_idx}（${mode_label}）→ 落地：[${new_landing_name}]"

		fss_set_current_node_id "${new_landing}"
		if [ -n "${new_front}" ]; then
			dbus set ssconf_basic_node_front="${new_front}"
		else
			dbus remove ssconf_basic_node_front
		fi

		# 4. 写切换时间戳（用于抖动防护，§4.5）
		dbus set fss_failover_last_switch_ts="$(date +%s)"

		# 5. 标记内部 restart（避免被 ssconfig.sh 入口误清失效标志）
		dbus set fss_failover_internal_restart="1"

		# 6. 重启
		echo_date "========================================================================" >/tmp/upload/ss_log.txt
		echo_date "" >>/tmp/upload/ss_log.txt
		echo_date "故障转移：切换到备用组合 #${next_idx}，重启fancyss！" >>/tmp/upload/ss_log.txt
		echo_date "" >>/tmp/upload/ss_log.txt
		echo_date "========================================================================" >>/tmp/upload/ss_log.txt
		run start-stop-daemon -S -q -x /koolshare/ss/ssconfig.sh -- restart >>/tmp/upload/ss_log.txt

		dbus set ss_heart_beat="1"
	fi
}

# 故障转移切换冷却判定（fork 新增，详见 doc/design/failover-combo-list-design.md §4.5）
# 上次切换组合后未到冷却时长 → 返回 0（在冷却期内，应跳过本轮判定）
# 否则返回 1（可以判定）
failover_cool_down_active(){
	local last_switch_ts=$(dbus get fss_failover_last_switch_ts)
	local cool_down=$(dbus get fss_failover_cool_down_sec)
	[ -n "$cool_down" ] || cool_down=30
	if [ -n "$last_switch_ts" ] && [ "$last_switch_ts" != "0" ]; then
		local now_ts=$(date +%s)
		local elapsed=$((now_ts - last_switch_ts))
		if [ "$elapsed" -lt "$cool_down" ]; then
			return 0
		fi
	fi
	return 1
}

failover_check_1(){
	# 切换冷却期内不做判定
	failover_cool_down_active && return

	local LINES=$(($ss_failover_s1 + 3))
	local START_MARK=$(cat "$LOGFILE_F" | sed '/fancyss/d' | tail -n "$LINES" | grep "===")
	if [ -n "$START_MARK" ];then
		#echo "$LOGTIME1 fancyss：1-检测到前$LINES行刚提交，先不检测！"
		return
	fi

	local OK_MARK=$(cat "$LOGFILE_F" | sed '/fancyss/d' | tail -n "$ss_failover_s1" | grep -Ec "200 OK|204 OK")
	if [ "$OK_MARK" == "0" ];then
		failover_action 1
	fi
}

failover_check_2(){
	# 切换冷却期内不做判定
	failover_cool_down_active && return

	local LINES=$(($ss_failover_s2_1 + 3))
	local START_MARK=$(cat "$LOGFILE_F" | sed '/fancyss/d' | tail -n "$LINES" | grep "===")
	if [ -n "$START_MARK" ];then
		#echo "$LOGTIME1 fancyss：2-检测到前$LINES行刚提交，先不检测！"
		return
	fi

	local OK_MARK=$(cat "$LOGFILE_F" | sed '/fancyss/d' | tail -n "$ss_failover_s2_1" | grep -Evc "200 OK|204 OK")
	if [ "$OK_MARK" -gt "$ss_failover_s2_2" ];then
		failover_action 2
	fi
}

failover_check_3(){
	# 切换冷却期内不做判定
	failover_cool_down_active && return

	local LINES=$(($ss_failover_s3_1 + 3))
	local START_MARK=$(cat "$LOGFILE_F" | sed '/fancyss/d' | tail -n "$LINES" | grep "===")
	if [ -n "$START_MARK" ];then
		#echo "$LOGTIME1 fancyss：3-检测到前$LINES行刚提交，先不检测！"
		return
	fi

	local OK_MARK=$(cat "$LOGFILE_F" | sed '/fancyss/d' | tail -n "$ss_failover_s3_1" | grep -E "200 OK|204 OK" | grep -oe "⏱ [0-9].* ms" | sed 's/⏱ //g'| sed 's/ ms//g' | awk '{sum+=$1} END {print sum/NR}' | awk '{printf "%.0f\n",$1}')
	#echo "$LOGTIME1 fancyss：前15次状态平均延迟：$OK_MARK ！"
	if [ "$OK_MARK" -gt "$ss_failover_s3_2" ];then
		failover_action 3 "$OK_MARK"
	fi
}

heath_check(){
	#LOGTIME1=$(TZ=UTC-8 date -R "+%m-%d %H:%M:%S")
	LOGTIME1=⌚$(TZ=UTC-8 date -R "+%H:%M:%S")
	
	[ "${ss_failover_enable}" != "1" ] && return
	[ "${COUNT}" -eq "2" ] && echo "${LOGTIME1} fancyss：跳过刚提交后的2个状态，从此处开始的状态用于故障检测"
	[ "${COUNT}" -le "2" ] && return

	[ "${ss_failover_c1}" == "1" ] && failover_check_1
	[ "${ss_failover_c2}" == "1" ] && failover_check_2
	[ "${ss_failover_c3}" == "1" ] && failover_check_3
}

main(){
	while : ; do
		# sleep 2s first in case of to early detection
		usleep 2000000
	
		# refresh dbus data in every loop
		eval $(dbus export ss_failover)
		[ "${ss_failover_enable}" != "1" ] && exit
		LOG_MAX=${ss_failover_s5}
		[ -z "${LOG_MAX}" ] && LOG_MAX=2000
		
		# clean clog incase of log grow too big
		if [ -f "/tmp/upload/ssf_status.txt" ];then
			clean_f_log
			clean_c_log
		fi
		
		# exit loop when fancyss not enabled
		[ "$(dbus get ss_basic_enable)" != "1" ] && exit
		
		if ! ps | grep -E "/koolshare/bin/status-tool daemon" | grep -v grep >/dev/null 2>&1; then
			sh /koolshare/scripts/ss_status_daemon.sh restart >/dev/null 2>&1
		fi

		if [ "$(ps|grep ssconfig.sh|grep -v grep)" ];then
			# wait until ssconfig.sh finished running
			echo ${LOGTIME1} ssconfig.sh running "[$(get_node_name_by_id "$(fss_get_current_node_id)")]" >> $LOGFILE_F
			#continue
		else
			refresh_status_cache_files >/dev/null 2>&1
		fi

		# do health check after result obtain
		heath_check >> ${LOGFILE_F}

		# conter
		let COUNT++
		
		# random sleep $(_get_interval) time
		local INTER=$(shuf -i $(_get_interval) -n 1)
		INTER=$((${INTER} * 1000))
		#echo $LOGTIME1 $INTER >> /tmp/inter.txt
		usleep ${INTER}
	done
}

main
