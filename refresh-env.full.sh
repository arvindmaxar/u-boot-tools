#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
PLATFORM_INSTALL="${SCRIPT_DIR}/platform_install.sh"

log()
{
	printf '%s\n' "$*"
}

warn()
{
	printf 'Warning: %s\n' "$*" >&2
}

die()
{
	printf 'Error: %s\n' "$*" >&2
	exit 1
}

need_cmd()
{
	command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

usage()
{
	cat <<'EOF'
Usage:
  sudo ./refresh-env.sh
    Refresh env_k1-x.txt on the running root device plus known boot targets.

  sudo ./refresh-env.sh /dev/mmcblk2 /dev/sda
    Refresh env_k1-x.txt on the listed block devices.

Options:
  --allow-empty
    Exit successfully even if no target could be refreshed.
EOF
}

require_root()
{
	[[ ${EUID} -eq 0 ]] || exec sudo "$0" "$@"
}

source_platform_install()
{
	[[ -f "${PLATFORM_INSTALL}" ]] || die "Missing ${PLATFORM_INSTALL}"
	# shellcheck source=/dev/null
	source "${PLATFORM_INSTALL}"
	export DIR="${SCRIPT_DIR}"
}

device_base_for_partition()
{
	local path="$1"
	local pkname

	if [[ -b "${path}" ]]; then
		pkname=$(lsblk -ndo PKNAME "${path}" 2>/dev/null || true)
		if [[ -n "${pkname}" ]]; then
			printf '/dev/%s\n' "${pkname}"
			return 0
		fi
	fi

	printf '%s\n' "${path}"
}

append_unique_device()
{
	local device="$1"
	local existing

	[[ -n "${device}" ]] || return 0
	[[ -b "${device}" ]] || return 0

	for existing in "${DEVICES[@]:-}"; do
		[[ "${existing}" == "${device}" ]] && return 0
	done

	DEVICES+=("${device}")
}

refresh_targets()
{
	local allow_empty="$1"
	local updated=0
	local device

	for device in "${DEVICES[@]:-}"; do
		if spacemit_refresh_existing_bootfs "${DIR}" "${device}"; then
			log "Refreshed env_k1-x.txt on ${device}"
			updated=1
		else
			warn "Skipped ${device}"
		fi
	done

	if [[ "${updated}" -eq 0 && "${allow_empty}" -eq 0 ]]; then
		die "No target boot filesystem was updated"
	fi
}

main()
{
	local allow_empty=0
	local current_root=""
	local -a original_args=("$@")
	DEVICES=()

	need_cmd findmnt
	need_cmd lsblk

	while [[ $# -gt 0 ]]; do
		case "$1" in
			--allow-empty)
				allow_empty=1
				;;
			-h|--help)
				usage
				exit 0
				;;
			/dev/*)
				append_unique_device "$1"
				;;
			*)
				usage
				exit 1
				;;
		esac
		shift
	done

	require_root "${original_args[@]}"
	source_platform_install

	if [[ "${#DEVICES[@]}" -eq 0 ]]; then
		current_root=$(findmnt -no SOURCE / 2>/dev/null || true)
		append_unique_device "$(device_base_for_partition "${current_root}")"
		append_unique_device /dev/sda
		append_unique_device /dev/mmcblk2
	fi

	refresh_targets "${allow_empty}"
}

main "$@"
