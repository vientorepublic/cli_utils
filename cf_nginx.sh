#!/usr/bin/env bash

set -Eeuo pipefail

CF_IPV4_URL="${CF_IPV4_URL:-https://www.cloudflare.com/ips-v4}"
CF_IPV6_URL="${CF_IPV6_URL:-https://www.cloudflare.com/ips-v6}"
CF_FILE_PATH="${CF_FILE_PATH:-/etc/nginx/cloudflare}"
LOCK_FILE="${LOCK_FILE:-/tmp/cf_nginx.lock}"
BACKUP_DIR="${BACKUP_DIR:-/tmp}"
INCLUDE_IPV6="${INCLUDE_IPV6:-0}"
APPLY_NGINX="${APPLY_NGINX:-0}"

BACKUP_FILE=""

C_RESET=""
C_INFO=""
C_OK=""
C_WARN=""
C_ERR=""

init_colors() {
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

cleanup() {
    rm -f "${TMP_IPV4_RAW:-}" "${TMP_IPV6_RAW:-}" "${TMP_IPV4_CIDRS:-}" "${TMP_IPV6_CIDRS:-}" "${TMP_OUTPUT:-}"
}

on_error() {
    local exit_code=$?
    local line_no=${1:-unknown}
    log ERROR "Failure detected (line=${line_no}, exit=${exit_code})"
    exit "${exit_code}"
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

fetch_ipv4() {
    TMP_IPV4_RAW="$(mktemp)"
    TMP_IPV4_CIDRS="$(mktemp)"

    log_info "Downloading Cloudflare IPv4 ranges: ${CF_IPV4_URL}"
    curl -fsSL --retry 3 --retry-delay 1 --connect-timeout 5 "${CF_IPV4_URL}" -o "${TMP_IPV4_RAW}"

    while IFS= read -r line; do
        line="${line%%#*}"
        line="${line//[$'\t\r\n ']/}"
        [[ -n "${line}" ]] || continue
        if is_valid_ipv4_cidr "${line}"; then
            printf '%s\n' "${line}" >> "${TMP_IPV4_CIDRS}"
        else
            die "Invalid IPv4 CIDR detected: ${line}"
        fi
    done < "${TMP_IPV4_RAW}"

    [[ -s "${TMP_IPV4_CIDRS}" ]] || die "No valid Cloudflare IPv4 CIDR entries found."
    LC_ALL=C sort -u -o "${TMP_IPV4_CIDRS}" "${TMP_IPV4_CIDRS}"
}

fetch_ipv6() {
    TMP_IPV6_RAW="$(mktemp)"
    TMP_IPV6_CIDRS="$(mktemp)"

    log_info "Downloading Cloudflare IPv6 ranges: ${CF_IPV6_URL}"
    curl -fsSL --retry 3 --retry-delay 1 --connect-timeout 5 "${CF_IPV6_URL}" -o "${TMP_IPV6_RAW}"

    while IFS= read -r line; do
        line="${line%%#*}"
        line="${line//[$'\t\r\n ']/}"
        [[ -n "${line}" ]] || continue
        printf '%s\n' "${line}" >> "${TMP_IPV6_CIDRS}"
    done < "${TMP_IPV6_RAW}"

    [[ -s "${TMP_IPV6_CIDRS}" ]] || die "No IPv6 entries found from Cloudflare source."
    LC_ALL=C sort -u -o "${TMP_IPV6_CIDRS}" "${TMP_IPV6_CIDRS}"
}

write_cloudflare_file() {
    TMP_OUTPUT="$(mktemp)"

    {
        echo "# Cloudflare real IP ranges (auto-generated)"
        echo "# Do not edit manually; this file is managed by cf_nginx.sh"
        echo
        echo "# IPv4"
        while IFS= read -r cidr; do
            echo "set_real_ip_from ${cidr};"
        done < "${TMP_IPV4_CIDRS}"

        if [[ "${INCLUDE_IPV6}" == "1" ]]; then
            echo
            echo "# IPv6"
            while IFS= read -r cidr; do
                echo "set_real_ip_from ${cidr};"
            done < "${TMP_IPV6_CIDRS}"
        fi

        echo
        echo "real_ip_header CF-Connecting-IP;"
        echo "real_ip_recursive on;"
    } > "${TMP_OUTPUT}"

    mkdir -p "$(dirname "${CF_FILE_PATH}")"

    if [[ -f "${CF_FILE_PATH}" ]]; then
        BACKUP_FILE="${BACKUP_DIR}/cloudflare.nginx.backup.$(date +%Y%m%d_%H%M%S).conf"
        cp -a "${CF_FILE_PATH}" "${BACKUP_FILE}"
        log_info "Saved current config backup: ${BACKUP_FILE}"
    fi

    mv -f "${TMP_OUTPUT}" "${CF_FILE_PATH}"
    log_ok "Updated file atomically: ${CF_FILE_PATH}"
}

test_and_reload_nginx() {
    if [[ "${APPLY_NGINX}" != "1" ]]; then
        log_info "Skipping nginx test/reload (set APPLY_NGINX=1 to enable)"
        return
    fi

    require_cmd nginx
    log_info "Testing nginx configuration"
    nginx -t

    if command -v systemctl >/dev/null 2>&1; then
        log_info "Reloading nginx via systemctl"
        systemctl reload nginx
    else
        log_info "Reloading nginx via nginx -s reload"
        nginx -s reload
    fi

    log_ok "nginx test and reload completed"
}

main() {
    require_cmd curl
    require_cmd flock
    require_cmd sort
    require_cmd mktemp
    require_cmd mv
    require_cmd cp
    require_cmd dirname
    init_colors

    if [[ "$(id -u)" -ne 0 ]]; then
        die "Run this script as root."
    fi

    exec 9>"${LOCK_FILE}"
    if ! flock -n 9; then
        die "Another instance is already running: ${LOCK_FILE}"
    fi

    fetch_ipv4
    if [[ "${INCLUDE_IPV6}" == "1" ]]; then
        fetch_ipv6
    fi

    write_cloudflare_file
    test_and_reload_nginx
}

main "$@"
