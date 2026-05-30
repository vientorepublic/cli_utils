#!/usr/bin/env bash

set -Eeuo pipefail

CF_IPV4_URL="${CF_IPV4_URL:-https://www.cloudflare.com/ips-v4}"
CHAIN_NAME="${CHAIN_NAME:-CF_IPV4_ALLOW}"
LOCK_FILE="${LOCK_FILE:-/tmp/cf_iptables.lock}"
BACKUP_DIR="${BACKUP_DIR:-/tmp}"
PORTS="${CF_PORTS:-80,443}"

BACKUP_FILE=""
CHANGED=0

C_RESET=""
C_INFO=""
C_OK=""
C_WARN=""
C_ERR=""

init_colors() {
	# Enable colors only for interactive terminals unless NO_COLOR is set.
	if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
		C_RESET=$'\033[0m'
		C_INFO=$'\033[36m'
		C_OK=$'\033[32m'
		C_WARN=$'\033[33m'
		C_ERR=$'\033[31m'
	fi
}

log() {
	local level="$1"
	shift
	local color="${C_RESET}"

	case "${level}" in
	INFO) color="${C_INFO}" ;;
	OK) color="${C_OK}" ;;
	WARN) color="${C_WARN}" ;;
	ERROR) color="${C_ERR}" ;;
	esac

	printf '[%s] %s[%s]%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${color}" "${level}" "${C_RESET}" "$*"
}

log_info() {
	log INFO "$*"
}

log_ok() {
	log OK "$*"
}

log_warn() {
	log WARN "$*"
}

die() {
	log ERROR "$*"
	exit 1
}

rollback() {
	if [[ -n "${BACKUP_FILE}" && -s "${BACKUP_FILE}" ]]; then
		log_warn "Rolling back iptables from backup: ${BACKUP_FILE}"
		iptables-restore < "${BACKUP_FILE}" || true
	fi
}

on_error() {
	local exit_code=$?
	local line_no=${1:-unknown}
	log ERROR "Failure detected (line=${line_no}, exit=${exit_code})"
	if [[ "${CHANGED}" -eq 1 ]]; then
		rollback
	fi
	exit "${exit_code}"
}

cleanup() {
	rm -f "${TMP_RAW:-}" "${TMP_CIDRS:-}" "${TMP_SORTED:-}" \
		"${TMP_EXISTING:-}" "${TMP_TO_ADD:-}" "${TMP_TO_DEL:-}"
}

trap 'on_error ${LINENO}' ERR
trap cleanup EXIT

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

is_valid_ipv4_cidr() {
	local cidr="$1"
	[[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[1-2][0-9]|3[0-2])$ ]] || return 1

	local ip mask
	ip="${cidr%/*}"
	mask="${cidr#*/}"

	local IFS='.'
	read -r o1 o2 o3 o4 <<< "$ip"

	for octet in "$o1" "$o2" "$o3" "$o4"; do
		[[ "$octet" =~ ^[0-9]+$ ]] || return 1
		((octet >= 0 && octet <= 255)) || return 1
	done

	[[ "$mask" =~ ^[0-9]+$ ]] || return 1
	((mask >= 0 && mask <= 32)) || return 1
}

add_rule_for_cidr() {
	local cidr="$1"

	if [[ "${PORTS}" == "all" ]]; then
		iptables -A "${CHAIN_NAME}" -s "${cidr}" -m comment --comment "cloudflare-ipv4" -j ACCEPT
		return
	fi

	local p
	IFS=',' read -r -a port_arr <<< "${PORTS}"
	for p in "${port_arr[@]}"; do
		[[ "$p" =~ ^[0-9]+$ ]] || die "Invalid port value: $p"
		((p >= 1 && p <= 65535)) || die "Port out of range: $p"
		iptables -A "${CHAIN_NAME}" -p tcp -s "${cidr}" --dport "${p}" -m comment --comment "cloudflare-ipv4" -j ACCEPT
	done
}

del_rule_for_cidr() {
	local cidr="$1"

	if [[ "${PORTS}" == "all" ]]; then
		iptables -D "${CHAIN_NAME}" -s "${cidr}" -m comment --comment "cloudflare-ipv4" -j ACCEPT 2>/dev/null || true
		return
	fi

	local p
	IFS=',' read -r -a port_arr <<< "${PORTS}"
	for p in "${port_arr[@]}"; do
		iptables -D "${CHAIN_NAME}" -p tcp -s "${cidr}" --dport "${p}" -m comment --comment "cloudflare-ipv4" -j ACCEPT 2>/dev/null || true
	done
}

# Print sorted unique CIDRs currently managed in the chain (identified by comment).
get_chain_cidrs() {
	iptables -S "${CHAIN_NAME}" 2>/dev/null \
		| awk '/--comment "cloudflare-ipv4"/{for(i=1;i<=NF;i++) if($i=="-s"){print $(i+1); break}}' \
		| sort -u
}

# Returns 0 if the port configuration stored in the chain differs from $PORTS, 1 if unchanged.
# An empty chain is treated as unchanged; rules will simply be added fresh.
chain_ports_changed() {
	local sample_rule
	sample_rule="$(iptables -S "${CHAIN_NAME}" 2>/dev/null | grep 'cloudflare-ipv4' | head -1)"
	[[ -z "$sample_rule" ]] && return 1

	if [[ "${PORTS}" == "all" ]]; then
		echo "$sample_rule" | grep -q -- '--dport' && return 0
	else
		echo "$sample_rule" | grep -q -- '--dport' || return 0
		local existing_ports
		existing_ports="$(iptables -S "${CHAIN_NAME}" 2>/dev/null \
			| grep 'cloudflare-ipv4' \
			| grep -oP '(?<=--dport )\d+' \
			| sort -un \
			| tr '\n' ',' \
			| sed 's/,$//')"
		[[ "$existing_ports" != "${PORTS}" ]] && return 0
	fi
	return 1
}

main() {
	require_cmd curl
	require_cmd iptables
	require_cmd iptables-save
	require_cmd iptables-restore
	require_cmd flock
	require_cmd sort
	require_cmd comm
	init_colors

	if [[ "$(id -u)" -ne 0 ]]; then
		die "Run this script as root."
	fi

	exec 9>"${LOCK_FILE}"
	if ! flock -n 9; then
		die "Another instance is already running: ${LOCK_FILE}"
	fi

	if [[ "${PORTS}" != "all" ]]; then
		PORTS="$(tr ',[:space:]' '\n' <<< "${PORTS}" | grep -v '^$' | sort -un | tr '\n' ',' | sed 's/,$//')"
		[[ -n "${PORTS}" ]] || die "PORTS is empty after normalization."
	fi

	TMP_RAW="$(mktemp)"
	TMP_CIDRS="$(mktemp)"
	TMP_SORTED="$(mktemp)"
	TMP_EXISTING="$(mktemp)"
	TMP_TO_ADD="$(mktemp)"
	TMP_TO_DEL="$(mktemp)"

	log_info "Downloading Cloudflare IPv4 ranges: ${CF_IPV4_URL}"
	curl -fsSL --retry 3 --retry-delay 1 --connect-timeout 5 "${CF_IPV4_URL}" -o "${TMP_RAW}"

	while IFS= read -r line; do
		line="${line%%#*}"
		line="${line//[$'\t\r\n ']/}"
		[[ -n "${line}" ]] || continue
		if is_valid_ipv4_cidr "${line}"; then
			printf '%s\n' "${line}" >> "${TMP_CIDRS}"
		else
			die "Invalid CIDR detected: ${line}"
		fi
	done < "${TMP_RAW}"

	[[ -s "${TMP_CIDRS}" ]] || die "No valid Cloudflare IPv4 CIDR entries found."

	sort -u "${TMP_CIDRS}" > "${TMP_SORTED}"

	BACKUP_FILE="${BACKUP_DIR}/iptables.backup.$(date +%Y%m%d_%H%M%S).rules"
	iptables-save > "${BACKUP_FILE}"
	log_info "Saved current iptables rules: ${BACKUP_FILE}"

	local needs_full_load=0

	if ! iptables -L "${CHAIN_NAME}" -n >/dev/null 2>&1; then
		iptables -N "${CHAIN_NAME}"
		CHANGED=1
		log_info "Created chain: ${CHAIN_NAME}"
		needs_full_load=1
	elif chain_ports_changed; then
		log_info "Port configuration changed → flushing chain for full rebuild"
		iptables -F "${CHAIN_NAME}"
		CHANGED=1
		needs_full_load=1
	fi

	if [[ "${needs_full_load}" -eq 1 ]]; then
		local count=0
		while IFS= read -r cidr; do
			add_rule_for_cidr "${cidr}"
			count=$((count + 1))
		done < "${TMP_SORTED}"
		log_ok "Full load: applied ${count} CIDRs"
	else
		get_chain_cidrs > "${TMP_EXISTING}"
		comm -23 "${TMP_SORTED}" "${TMP_EXISTING}" > "${TMP_TO_ADD}"
		comm -13 "${TMP_SORTED}" "${TMP_EXISTING}" > "${TMP_TO_DEL}"

		local added=0 removed=0
		while IFS= read -r cidr; do
			[[ -z "$cidr" ]] && continue
			add_rule_for_cidr "${cidr}"
			added=$((added + 1))
			CHANGED=1
		done < "${TMP_TO_ADD}"

		while IFS= read -r cidr; do
			[[ -z "$cidr" ]] && continue
			del_rule_for_cidr "${cidr}"
			removed=$((removed + 1))
			CHANGED=1
		done < "${TMP_TO_DEL}"

		if [[ "${added}" -eq 0 && "${removed}" -eq 0 ]]; then
			log_ok "Rules already up-to-date (no changes)"
		else
			log_ok "Diff update: +${added} added, -${removed} removed"
		fi
	fi

	if ! iptables -C INPUT -j "${CHAIN_NAME}" >/dev/null 2>&1; then
		iptables -I INPUT 1 -j "${CHAIN_NAME}"
		log_info "Added INPUT jump rule to: ${CHAIN_NAME}"
	else
		log_info "INPUT jump rule already exists for: ${CHAIN_NAME}"
	fi

	local total
	total="$(wc -l < "${TMP_SORTED}" | tr -d ' ')"
	if [[ "${PORTS}" == "all" ]]; then
		log_ok "Apply complete: ${total} active CIDRs (all ports)"
	else
		log_ok "Apply complete: ${total} active CIDRs (TCP ports: ${PORTS})"
	fi
}

main "$@"
