#!/bin/sh

# fancyss airport dns lazy-loaded helpers (smartdns 已于 doge.14 物理移除)

fss_airport_runtime_current_entry_json() {
	return 1
}

fss_airport_special_current_conf_path() {
	local airport_identity=""
	local conf_path=""
	airport_identity="$(fss_get_current_node_airport_identity 2>/dev/null)" || return 1
	[ -n "${airport_identity}" ] || return 1
	conf_path="$(fss_airport_special_conf_path "${airport_identity}" 2>/dev/null)" || return 1
	[ -f "${conf_path}" ] || return 1
	printf '%s\n' "${conf_path}"
}

fss_airport_special_conf_get_value() {
	local conf_path="$1"
	local key="$2"
	[ -f "${conf_path}" ] || return 1
	[ -n "${key}" ] || return 1
	sed -n "s/^${key}=//p" "${conf_path}" | sed -n '1p'
}

fss_airport_special_conf_iter_dns_urls() {
	local conf_path="$1"
	[ -f "${conf_path}" ] || return 1
	sed '/^[[:space:]]*#/d;/^[[:space:]]*$/d;/^[A-Za-z0-9_][A-Za-z0-9_]*=/d' "${conf_path}" 2>/dev/null
}

fss_airport_special_conf_iter_identities() {
	[ -f "${FSS_AIRPORT_SPECIAL_INDEX_FILE}" ] || return 1
	sed '/^[[:space:]]*#/d;/^[[:space:]]*$/d' "${FSS_AIRPORT_SPECIAL_INDEX_FILE}" 2>/dev/null
}

fss_airport_special_runtime_domain_file() {
	local airport_identity="$1"
	[ -n "${airport_identity}" ] || return 1
	printf '/tmp/ss_node_domains_airport_%s.txt\n' "${airport_identity}"
}

fss_airport_special_runtime_dns_file() {
	local airport_identity="$1"
	[ -n "${airport_identity}" ] || return 1
	printf '/tmp/ss_node_domains_airport_dns_%s.txt\n' "${airport_identity}"
}

fss_clear_airport_special_runtime_files() {
	rm -f /tmp/ss_node_domains_airport.txt \
		/tmp/ss_node_domains_airport_dns.txt \
		/tmp/ss_node_domains_other.txt \
		/tmp/ss_node_domains_airport_*.txt \
		/tmp/ss_node_domains_airport_dns_*.txt >/dev/null 2>&1
}

fss_airport_special_conf_has_active_nodes() {
	local airport_identity="$1"
	[ -n "${airport_identity}" ] || return 1
	[ -s "${FSS_NODE_AIRPORT_DOMAIN_CACHE_FILE}" ] || return 1
	awk -F '\t' -v id="${airport_identity}" '$1 == id {found=1; exit} END {exit(found ? 0 : 1)}' "${FSS_NODE_AIRPORT_DOMAIN_CACHE_FILE}" 2>/dev/null
}

fss_airport_special_active_identities() {
	local airport_identity=""
	local conf_path=""

	fss_refresh_node_direct_cache >/dev/null 2>&1 || true
	while IFS= read -r airport_identity
	do
		[ -n "${airport_identity}" ] || continue
		conf_path="$(fss_airport_special_conf_path "${airport_identity}" 2>/dev/null)" || continue
		[ -f "${conf_path}" ] || continue
		fss_airport_special_conf_has_active_nodes "${airport_identity}" || continue
		printf '%s\n' "${airport_identity}"
	done <<-EOF
$(fss_airport_special_conf_iter_identities 2>/dev/null)
	EOF
}

fss_airport_special_active_label_by_plan() {
	local preferred_plan="${1:-smartdns}"
	local airport_identity=""
	local conf_path=""
	local conf_plan=""
	local conf_label=""

	while IFS= read -r airport_identity
	do
		[ -n "${airport_identity}" ] || continue
		conf_path="$(fss_airport_special_conf_path "${airport_identity}" 2>/dev/null)" || continue
		[ -f "${conf_path}" ] || continue
		conf_plan="$(fss_airport_special_conf_get_value "${conf_path}" "preferred_dns_plan" 2>/dev/null)"
		[ -n "${conf_plan}" ] || conf_plan="smartdns"
		[ "${conf_plan}" = "${preferred_plan}" ] || continue
		fss_airport_special_conf_has_active_nodes "${airport_identity}" || continue
		conf_label="$(fss_airport_special_conf_get_value "${conf_path}" "airport_label" 2>/dev/null)"
		[ -n "${conf_label}" ] || conf_label="${airport_identity}"
		printf '%s\n' "${conf_label}"
		return 0
	done <<-EOF
$(fss_airport_special_active_identities 2>/dev/null)
	EOF
	return 1
}

fss_airport_special_active_labels_by_plan() {
	local preferred_plan="${1:-smartdns}"
	local airport_identity=""
	local conf_path=""
	local conf_plan=""
	local conf_label=""
	local labels=""

	while IFS= read -r airport_identity
	do
		[ -n "${airport_identity}" ] || continue
		conf_path="$(fss_airport_special_conf_path "${airport_identity}" 2>/dev/null)" || continue
		[ -f "${conf_path}" ] || continue
		conf_plan="$(fss_airport_special_conf_get_value "${conf_path}" "preferred_dns_plan" 2>/dev/null)"
		[ -n "${conf_plan}" ] || conf_plan="smartdns"
		[ "${conf_plan}" = "${preferred_plan}" ] || continue
		fss_airport_special_conf_has_active_nodes "${airport_identity}" || continue
		conf_label="$(fss_airport_special_conf_get_value "${conf_path}" "airport_label" 2>/dev/null)"
		[ -n "${conf_label}" ] || conf_label="${airport_identity}"
		if [ -n "${labels}" ]; then
			labels="${labels}、${conf_label}"
		else
			labels="${conf_label}"
		fi
	done <<-EOF
$(fss_airport_special_active_identities 2>/dev/null)
	EOF

	[ -n "${labels}" ] || return 1
	printf '%s\n' "${labels}"
}

fss_airport_special_iter_active_tsv() {
	local airport_identity=""
	local conf_path=""
	local conf_label=""
	local conf_plan=""
	local sep="$(printf '\037')"

	while IFS= read -r airport_identity
	do
		[ -n "${airport_identity}" ] || continue
		conf_path="$(fss_airport_special_conf_path "${airport_identity}" 2>/dev/null)" || continue
		[ -f "${conf_path}" ] || continue
		conf_label="$(fss_airport_special_conf_get_value "${conf_path}" "airport_label" 2>/dev/null)"
		[ -n "${conf_label}" ] || conf_label="${airport_identity}"
		conf_plan="$(fss_airport_special_conf_get_value "${conf_path}" "preferred_dns_plan" 2>/dev/null)"
		[ -n "${conf_plan}" ] || conf_plan="smartdns"
		printf '%s%s%s%s%s\n' "${airport_identity}" "${sep}" "${conf_label}" "${sep}" "${conf_plan}"
	done <<-EOF
$(fss_airport_special_active_identities 2>/dev/null)
	EOF
}

fss_airport_dns_raw_to_tsv() {
	local raw="$1"
	local proto="" addr="" port="" host="" host_ip="" hostport="" remain=""
	local sep="$(printf '\037')"

	raw=$(printf '%s' "${raw}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed 's/^"//;s/"$//;s/^'\''//;s/'\''$//')
	[ -n "${raw}" ] || return 1
	case "${raw}" in
	https://*)
		proto="https"
		hostport=$(printf '%s' "${raw#https://}" | sed 's#/.*$##')
		port=$(printf '%s' "${hostport}" | awk -F: 'NF>1{print $NF}')
		[ -n "${port}" ] || port="443"
		case "${hostport}" in
		\[*\]:*)
			host=$(printf '%s' "${hostport}" | sed -n 's/^\[\(.*\)\]:[0-9][0-9]*$/\1/p')
			[ -n "${host}" ] || host=$(printf '%s' "${hostport}" | sed 's/^\[//;s/\]$//')
			;;
		*)
			host=$(printf '%s' "${hostport}" | sed 's/:[0-9][0-9]*$//')
			;;
		esac
		;;
	quic://*)
		proto="quic"
		hostport=$(printf '%s' "${raw#quic://}" | sed 's#/.*$##')
		port=$(printf '%s' "${hostport}" | awk -F: 'NF>1{print $NF}')
		[ -n "${port}" ] || port="853"
		case "${hostport}" in
		\[*\]:*)
			host=$(printf '%s' "${hostport}" | sed -n 's/^\[\(.*\)\]:[0-9][0-9]*$/\1/p')
			[ -n "${host}" ] || host=$(printf '%s' "${hostport}" | sed 's/^\[//;s/\]$//')
			;;
		*)
			host=$(printf '%s' "${hostport}" | sed 's/:[0-9][0-9]*$//')
			;;
		esac
		;;
	tls://*)
		proto="tls"
		remain="${raw#tls://}"
		host="${remain%%@*}"
		[ "${remain#*@}" != "${remain}" ] && host_ip="${remain#*@}" || host_ip=""
		port="853"
		;;
	tcp://*)
		proto="tcp"
		remain="${raw#tcp://}"
		addr="${remain%%:*}"
		port="${remain##*:}"
		[ "${addr}" = "${port}" ] && port="53"
		[ -n "$(fss_is_domain_name "${addr}")" ] && host="${addr}"
		;;
	udp://*)
		proto="udp"
		remain="${raw#udp://}"
		addr="${remain%%:*}"
		port="${remain##*:}"
		[ "${addr}" = "${port}" ] && port="53"
		[ -n "$(fss_is_domain_name "${addr}")" ] && host="${addr}"
		;;
	*)
		if printf '%s' "${raw}" | grep -Eq '^([0-9]{1,3}[.]){3}[0-9]{1,3}(:[0-9]+)?$';then
			proto="udp"
			addr="${raw%%:*}"
			port="${raw##*:}"
			[ "${addr}" = "${port}" ] && port="53"
		else
			return 1
		fi
		;;
	esac
	printf '%s%s%s%s%s%s%s%s%s%s%s\n' "${proto}" "${sep}" "${raw}" "${sep}" "${addr}" "${sep}" "${port}" "${sep}" "${host}" "${sep}" "${host_ip}"
}

fss_airport_runtime_iter_current_dns_items_tsv() {
	local airport_identity=""
	local conf_path=""
	while IFS= read -r airport_identity
	do
		[ -n "${airport_identity}" ] || continue
		conf_path="$(fss_airport_special_conf_path "${airport_identity}" 2>/dev/null)" || continue
		[ -f "${conf_path}" ] || continue
		fss_airport_special_conf_iter_dns_urls "${conf_path}" 2>/dev/null | while IFS= read -r raw
		do
			[ -n "${raw}" ] || continue
			fss_airport_dns_raw_to_tsv "${raw}" 2>/dev/null || true
		done
	done <<-EOF
$(fss_airport_special_active_identities 2>/dev/null)
	EOF
}

fss_airport_runtime_iter_dns_items_tsv_by_identity() {
	local airport_identity="$1"
	local conf_path=""
	[ -n "${airport_identity}" ] || return 1
	conf_path="$(fss_airport_special_conf_path "${airport_identity}" 2>/dev/null)" || return 1
	[ -f "${conf_path}" ] || return 1
	fss_airport_special_conf_iter_dns_urls "${conf_path}" 2>/dev/null | while IFS= read -r raw
	do
		[ -n "${raw}" ] || continue
		fss_airport_dns_raw_to_tsv "${raw}" 2>/dev/null || true
	done
}

fss_refresh_airport_special_runtime_domain_files() {
	local airport_file="${FSS_NODE_DIRECT_RUNTIME_AIRPORT_FILE}"
	local other_file="${FSS_NODE_DIRECT_RUNTIME_OTHER_FILE}"
	local airport_tmp="${airport_file}.tmp.$$"
	local other_tmp="${other_file}.tmp.$$"
	local active_ids_file="${airport_file}.active.$$"
	local airport_identity=""
	local airport_identity_tmp=""
	local domain_file=""
	local domain_tmp=""

	fss_clear_airport_special_runtime_files
	rm -f "${airport_tmp}" "${other_tmp}" "${active_ids_file}"
	fss_refresh_node_direct_cache >/dev/null 2>&1 || return 1
	fss_airport_special_active_identities 2>/dev/null | sort -u > "${active_ids_file}"
	[ -s "${active_ids_file}" ] || {
		rm -f "${airport_file}" "${other_file}" "${active_ids_file}"
		return 0
	}
	awk -F '\t' -v active_ids="${active_ids_file}" -v airport_out="${airport_tmp}" -v other_out="${other_tmp}" '
		BEGIN {
			while ((getline line < active_ids) > 0) {
				active[line] = 1
			}
		}
		NF >= 2 && $2 != "" {
			if ($1 in active) {
				print $2 >> airport_out
				print $2 >> sprintf("/tmp/ss_node_domains_airport_%s.txt.tmp.__ACTIVE__", $1)
			} else {
				print $2 >> other_out
			}
		}
	' "${FSS_NODE_AIRPORT_DOMAIN_CACHE_FILE}" 2>/dev/null
	rm -f "${active_ids_file}"

	for airport_identity_tmp in /tmp/ss_node_domains_airport_*.txt.tmp.__ACTIVE__
	do
		[ -f "${airport_identity_tmp}" ] || continue
		airport_identity="${airport_identity_tmp#/tmp/ss_node_domains_airport_}"
		airport_identity="${airport_identity%.txt.tmp.__ACTIVE__}"
		domain_file="$(fss_airport_special_runtime_domain_file "${airport_identity}" 2>/dev/null)" || {
			rm -f "${airport_identity_tmp}"
			continue
		}
		domain_tmp="${domain_file}.tmp.$$"
		sort -u "${airport_identity_tmp}" -o "${airport_identity_tmp}" 2>/dev/null
		cat "${airport_identity_tmp}" > "${domain_tmp}" 2>/dev/null && mv -f "${domain_tmp}" "${domain_file}"
		rm -f "${airport_identity_tmp}" "${domain_tmp}"
	done

	if [ -s "${airport_tmp}" ];then
		sort -u "${airport_tmp}" -o "${airport_tmp}" 2>/dev/null
		mv -f "${airport_tmp}" "${airport_file}"
	else
		rm -f "${airport_tmp}" "${airport_file}"
	fi
	if [ -s "${other_tmp}" ];then
		sort -u "${other_tmp}" -o "${other_tmp}" 2>/dev/null
		mv -f "${other_tmp}" "${other_file}"
	else
		rm -f "${other_tmp}" "${other_file}"
	fi
}

fss_airport_dns_item_effective_host() {
	local proto="$1"
	local raw="$2"
	local addr="$3"
	local host="$4"
	local hostport=""
	local remain=""

	[ -n "${host}" ] || {
		case "${proto}" in
		https|quic)
			hostport=$(printf '%s' "${raw#*://}" | sed 's#/.*$##')
			case "${hostport}" in
			\[*\]:*)
				host=$(printf '%s' "${hostport}" | sed -n 's/^\[\(.*\)\]:[0-9][0-9]*$/\1/p')
				[ -n "${host}" ] || host=$(printf '%s' "${hostport}" | sed 's/^\[//;s/\]$//')
				;;
			*)
				host=$(printf '%s' "${hostport}" | sed 's/:[0-9][0-9]*$//')
				;;
			esac
			;;
		tls)
			remain="${raw#tls://}"
			host="${remain%%@*}"
			;;
		tcp|udp)
			[ -n "$(fss_is_domain_name "${addr}")" ] && host="${addr}"
			;;
		esac
	}
	[ -n "${host}" ] || return 1
	[ -n "$(fss_is_domain_name "${host}")" ] || return 1
	printf '%s' "${host}"
}

fss_refresh_airport_dns_host_runtime_file() {
	local runtime_file="${FSS_NODE_DIRECT_RUNTIME_AIRPORT_DNS_FILE}"
	local tmp_file="${runtime_file}.tmp.$$"
	local sep="$(printf '\037')"
	local proto="" raw="" addr="" port="" host="" host_ip=""
	local effective_host=""
	local airport_identity=""
	local airport_runtime_file=""
	local airport_tmp_file=""

	rm -f "${tmp_file}"
	fss_airport_runtime_iter_current_dns_items_tsv 2>/dev/null | while IFS="${sep}" read -r proto raw addr port host host_ip
	do
		effective_host="$(fss_airport_dns_item_effective_host "${proto}" "${raw}" "${addr}" "${host}" 2>/dev/null)" || continue
		printf '%s\n' "${effective_host}"
	done | sort -u > "${tmp_file}" 2>/dev/null

	if [ -s "${tmp_file}" ];then
		mv -f "${tmp_file}" "${runtime_file}"
	else
		rm -f "${tmp_file}" "${runtime_file}"
	fi

	while IFS= read -r airport_identity
	do
		[ -n "${airport_identity}" ] || continue
		airport_runtime_file="$(fss_airport_special_runtime_dns_file "${airport_identity}" 2>/dev/null)" || continue
		airport_tmp_file="${airport_runtime_file}.tmp.$$"
		rm -f "${airport_tmp_file}"
		fss_airport_runtime_iter_dns_items_tsv_by_identity "${airport_identity}" 2>/dev/null | while IFS="${sep}" read -r proto raw addr port host host_ip
		do
			effective_host="$(fss_airport_dns_item_effective_host "${proto}" "${raw}" "${addr}" "${host}" 2>/dev/null)" || continue
			printf '%s\n' "${effective_host}"
		done | sort -u > "${airport_tmp_file}" 2>/dev/null
		if [ -s "${airport_tmp_file}" ];then
			mv -f "${airport_tmp_file}" "${airport_runtime_file}"
		else
			rm -f "${airport_tmp_file}" "${airport_runtime_file}"
		fi
	done <<-EOF
$(fss_airport_special_active_identities 2>/dev/null)
	EOF
}

fss_airport_dns_override_reset() {
	AIRPORT_DNS_ACTIVE="0"
	AIRPORT_DNS_CURRENT_MATCHED="0"
	AIRPORT_DNS_AIRPORT_IDENTITY=""
	AIRPORT_DNS_AIRPORT_LABEL=""
	AIRPORT_DNS_PREFERRED_PLAN=""
	fss_clear_airport_special_runtime_files
}

fss_airport_dns_override_load() {
	local current_airport=""
	local conf_path=""
	local active_identity=""
	local active_conf_path=""
	fss_airport_dns_override_reset
	active_identity="$(fss_airport_special_active_identities 2>/dev/null | sed -n '1p')" || active_identity=""
	[ -n "${active_identity}" ] || return 0
	AIRPORT_DNS_ACTIVE="1"
	current_airport="$(fss_get_current_node_airport_identity 2>/dev/null)" || current_airport=""
	conf_path=""
	if [ -n "${current_airport}" ];then
		conf_path="$(fss_airport_special_conf_path "${current_airport}" 2>/dev/null)" || conf_path=""
	fi
	if [ -n "${conf_path}" ] && [ -f "${conf_path}" ] && fss_airport_special_conf_has_active_nodes "${current_airport}"; then
		AIRPORT_DNS_CURRENT_MATCHED="1"
		AIRPORT_DNS_AIRPORT_IDENTITY="${current_airport}"
		AIRPORT_DNS_AIRPORT_LABEL="$(fss_airport_special_conf_get_value "${conf_path}" "airport_label" 2>/dev/null)"
		AIRPORT_DNS_PREFERRED_PLAN="$(fss_airport_special_conf_get_value "${conf_path}" "preferred_dns_plan" 2>/dev/null)"
	else
		active_conf_path="$(fss_airport_special_conf_path "${active_identity}" 2>/dev/null)" || active_conf_path=""
		AIRPORT_DNS_AIRPORT_IDENTITY="${active_identity}"
		AIRPORT_DNS_AIRPORT_LABEL="$(fss_airport_special_conf_get_value "${active_conf_path}" "airport_label" 2>/dev/null)"
		AIRPORT_DNS_PREFERRED_PLAN="$(fss_airport_special_conf_get_value "${active_conf_path}" "preferred_dns_plan" 2>/dev/null)"
	fi
	[ -n "${AIRPORT_DNS_AIRPORT_LABEL}" ] || AIRPORT_DNS_AIRPORT_LABEL="${AIRPORT_DNS_AIRPORT_IDENTITY}"
	[ -n "${AIRPORT_DNS_PREFERRED_PLAN}" ] || AIRPORT_DNS_PREFERRED_PLAN="smartdns"
	fss_refresh_airport_special_runtime_domain_files >/dev/null 2>&1 || true
	fss_refresh_airport_dns_host_runtime_file >/dev/null 2>&1 || true
}

