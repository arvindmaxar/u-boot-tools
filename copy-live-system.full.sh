#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
PLATFORM_INSTALL="${SCRIPT_DIR}/platform_install.sh"
BACKUP_ROOT_DEFAULT=/var/tmp/k1x-copy-live-system-backups
BOOT_AREA_START_SECTOR_DEFAULT=32768

usage()
{
	cat <<'EOF'
Usage:
  sudo ./copy-live-system.sh --force /dev/mmcblk2
    Repartition, format, and copy the current live root filesystem to the
    target device, update the target root UUID in extlinux.conf and fstab,
    then update the target boot blocks and env_k1-x.txt.

The script creates a backup of the target boot areas under
`/var/tmp/k1x-copy-live-system-backups/` before making destructive changes.

Options:
  --source-root PATH
    Copy from PATH instead of /.

  --backup-root PATH
    Store target boot-area backups under PATH instead of
    /var/tmp/k1x-copy-live-system-backups.

  --boot-start-sector N
    Start the target root partition at sector N. Default: 32768 (16 MiB),
    which leaves room for raw boot blocks.

  --env-only
    Refresh only env_k1-x.txt on the target after copying; skip raw boot blocks.

  --keep-partition-table
    Reuse the target's first partition instead of recreating a single ext4
    partition. The target filesystem will still be reformatted.

  --force
    Required. Acknowledge that the target device will be overwritten.
EOF
}

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

require_root()
{
	[[ ${EUID:-$(id -u)} -eq 0 ]] || exec sudo "$0" "$@"
}

source_platform_install()
{
	[[ -f "${PLATFORM_INSTALL}" ]] || die "Missing ${PLATFORM_INSTALL}"
	# shellcheck source=/dev/null
	source "${PLATFORM_INSTALL}"
	export DIR="${SCRIPT_DIR}"
}

bytes_used_for_path()
{
	local path="$1"
	df -B1 --output=used "${path}" 2>/dev/null | awk 'NR==2 {print $1}'
}

bytes_available_for_path()
{
	local path="$1"
	df -B1 --output=avail "${path}" 2>/dev/null | awk 'NR==2 {print $1}'
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

assert_target_is_whole_device()
{
	local device="$1"
	local devtype=""

	devtype=$(lsblk -ndo TYPE "${device}" 2>/dev/null || true)
	[[ -n "${devtype}" ]] || die "Unable to determine block-device type for ${device}"
	case "${devtype}" in
		disk|loop)
			;;
		*)
			die "Target must be a whole block device, not ${devtype}: ${device}"
			;;
	esac
}

assert_source_root_ready()
{
	local source_root="$1"
	local source_target=""
	local source_dev=""

	[[ "${source_root}" == /* ]] || die "Source root must be an absolute path: ${source_root}"
	[[ -d "${source_root}" ]] || die "Missing source root: ${source_root}"
	source_target=$(findmnt -T "${source_root}" -no TARGET 2>/dev/null || true)
	source_dev=$(findmnt -T "${source_root}" -no SOURCE 2>/dev/null || true)
	[[ -n "${source_target}" ]] || die "Source root is not on a mounted filesystem: ${source_root}"
	[[ -n "${source_dev}" ]] || die "Unable to determine source device for ${source_root}"
	[[ -f "${source_root}/boot/extlinux/extlinux.conf" ]] || die "Source root is missing /boot/extlinux/extlinux.conf: ${source_root}"
	[[ -d "${source_root}/boot" ]] || die "Source root is missing /boot: ${source_root}"
}

assert_safe_target()
{
	local source_root="$1"
	local target_device="$2"
	local source_dev=""
	local source_base=""

	spacemit_assert_block_device "${target_device}" || exit 1
	assert_target_is_whole_device "${target_device}"
	source_dev=$(findmnt -no SOURCE "${source_root}" 2>/dev/null || true)
	[[ -n "${source_dev}" ]] || die "Unable to determine source device for ${source_root}"
	source_base=$(device_base_for_partition "${source_dev}")

	[[ "${source_base}" != "${target_device}" ]] || die "Refusing to overwrite the live source device ${target_device}"
	[[ -z "$(findmnt -rn -S "${target_device}" -o TARGET 2>/dev/null)" ]] || die "Target device is mounted: ${target_device}"
	[[ -z "$(findmnt -rn -S "$(spacemit_first_partition "${target_device}")" -o TARGET 2>/dev/null)" ]] || die "Target partition is mounted: $(spacemit_first_partition "${target_device}")"
}

partition_start_sector()
{
	local part="$1"

	lsblk -ndo START "${part}" 2>/dev/null | awk 'NR==1 {print $1}'
}

rsync_exclude_for_source_path()
{
	local source_root="$1"
	local path="$2"
	local rel=""

	[[ -n "${path}" ]] || return 0
	[[ "${path}" == /* ]] || return 0

	if [[ "${source_root}" == "/" ]]; then
		printf '/%s\n' "${path#/}"
		return 0
	fi

	case "${path}" in
		"${source_root}"/*)
			rel="${path#${source_root}/}"
			printf '/%s\n' "${rel}"
			;;
	esac
}

wait_for_partition()
{
	local part="$1"
	local tries=0

	while [[ ! -b "${part}" ]]; do
		tries=$((tries + 1))
		[[ "${tries}" -le 20 ]] || die "Timed out waiting for ${part}"
		sleep 1
	done
}

prepare_target_partition()
{
	local target_device="$1"
	local keep_partition_table="$2"
	local boot_start_sector="$3"
	local target_part

	if [[ "${keep_partition_table}" -eq 0 ]]; then
		need_cmd wipefs
		need_cmd sfdisk
		wipefs -af "${target_device}" >/dev/null
		printf 'label: gpt\nstart=%s, type=L\n' "${boot_start_sector}" | sfdisk --wipe always "${target_device}" >/dev/null
		command -v partprobe >/dev/null 2>&1 && partprobe "${target_device}" || true
		command -v udevadm >/dev/null 2>&1 && udevadm settle || true
	fi

	target_part=$(spacemit_first_partition "${target_device}")
	wait_for_partition "${target_part}"

	need_cmd mkfs.ext4
	mkfs.ext4 -F -L rootfs "${target_part}" >/dev/null
	sync
	command -v udevadm >/dev/null 2>&1 && udevadm settle || true
	printf '%s\n' "${target_part}"
}

assert_partition_start_safe()
{
	local target_part="$1"
	local update_boot_blocks="$2"
	local boot_start_sector="$3"
	local start_sector=""

	if [[ "${update_boot_blocks}" -eq 0 ]]; then
		return 0
	fi

	start_sector=$(partition_start_sector "${target_part}")
	[[ -n "${start_sector}" ]] || die "Unable to determine partition start sector for ${target_part}"
	if (( start_sector < boot_start_sector )); then
		die "Target partition ${target_part} starts at sector ${start_sector}, but boot-block writes require it to start at or after sector ${boot_start_sector}"
	fi
}

verify_target_filesystem_type()
{
	local target_part="$1"
	local fstype=""

	fstype=$(blkid -s TYPE -o value "${target_part}" 2>/dev/null || true)
	[[ "${fstype}" == "ext4" ]] || die "Expected ext4 on ${target_part} after format, got ${fstype:-unknown}"
}

mount_target_partition()
{
	local target_part="$1"
	local target_mount="$2"

	verify_target_filesystem_type "${target_part}"
	if ! mount -t ext4 "${target_part}" "${target_mount}"; then
		lsblk -f "${target_part}" >&2 || true
		die "Failed to mount ${target_part} as ext4 at ${target_mount}"
	fi
}

ensure_target_capacity()
{
	local source_root="$1"
	local target_mount="$2"
	local required_bytes available_bytes

	required_bytes=$(bytes_used_for_path "${source_root}")
	available_bytes=$(bytes_available_for_path "${target_mount}")
	[[ -n "${required_bytes}" && -n "${available_bytes}" ]] || die "Unable to determine source/target capacity"

	if (( available_bytes <= required_bytes )); then
		die "Target filesystem at ${target_mount} has insufficient free space: need ${required_bytes} bytes, have ${available_bytes} bytes"
	fi
}

backup_target_state()
{
	local target_device="$1"
	local backup_root="$2"
	local stamp base backup_dir target_part
	local metadata

	need_cmd dd
	need_cmd mkdir
	stamp=$(date +%Y%m%d-%H%M%S)
	base="${target_device##*/}"
	backup_dir="${backup_root}/${base}-${stamp}"
	metadata="${backup_dir}/metadata.txt"

	mkdir -p "${backup_dir}"
	printf 'target_device=%s\ncreated=%s\n' "${target_device}" "${stamp}" > "${metadata}"

	if command -v sfdisk >/dev/null 2>&1; then
		sfdisk -d "${target_device}" > "${backup_dir}/partition-table.sfdisk" 2>/dev/null || true
	fi

	dd if="${target_device}" of="${backup_dir}/first8M.bin" bs=1M count=8 status=none
	printf 'first8M=%s\n' "${backup_dir}/first8M.bin" >> "${metadata}"

	if [[ -b "${target_device}boot0" ]]; then
		if [[ -e "/sys/block/${base}boot0/force_ro" ]]; then
			printf 'boot0_force_ro_before=%s\n' "$(cat "/sys/block/${base}boot0/force_ro" 2>/dev/null || printf '1')" >> "${metadata}"
		fi
		dd if="${target_device}boot0" of="${backup_dir}/boot0.bin" bs=1M status=none
		printf 'boot0=%s\n' "${backup_dir}/boot0.bin" >> "${metadata}"
	fi

	target_part=$(spacemit_first_partition "${target_device}")
	if [[ -b "${target_part}" ]]; then
		printf 'target_part=%s\n' "${target_part}" >> "${metadata}"
		printf 'target_part_uuid_before=%s\n' "$(blkid -s UUID -o value "${target_part}" 2>/dev/null || true)" >> "${metadata}"
	fi

	printf '%s\n' "${backup_dir}"
}

update_target_fstab()
{
	local mountpoint="$1"
	local target_uuid="$2"
	local fstab="${mountpoint}/etc/fstab"
	local tmpfile

	[[ -f "${fstab}" ]] || {
		log "Skipping fstab update: ${fstab} not present"
		return 0
	}

	tmpfile=$(mktemp "${mountpoint}/etc/.fstab.XXXXXX") || return 1
	if ! awk -v uuid="${target_uuid}" '
		BEGIN { changed = 0 }
		/^[[:space:]]*#/ { print; next }
		$2 == "/" { $1 = "UUID=" uuid; changed = 1 }
		{ print }
		END { if (!changed) exit 2 }
	' "${fstab}" > "${tmpfile}"; then
		rm -f "${tmpfile}"
		die "Failed to update root UUID in ${fstab}"
	fi

	mv -f "${tmpfile}" "${fstab}"
}

update_target_extlinux()
{
	local mountpoint="$1"
	local target_uuid="$2"
	local extlinux="${mountpoint}/boot/extlinux/extlinux.conf"

	[[ -f "${extlinux}" ]] || die "Missing ${extlinux} on target copy"
	sed -E -i.bak "s#root=UUID=[^ ]+#root=UUID=${target_uuid}#g" "${extlinux}"
	rm -f "${extlinux}.bak"
}

copy_live_system()
{
	local source_root="$1"
	local target_mount="$2"
	local backup_root="$3"
	local backup_exclude=""
	local rsync_cmd=(
		rsync -aHAXx --numeric-ids --delete
		--exclude=/dev/*
		--exclude=/proc/*
		--exclude=/sys/*
		--exclude=/tmp/*
		--exclude=/run/*
		--exclude=/mnt/*
		--exclude=/media/*
		--exclude=/lost+found
		--exclude=/var/log.hdd
	)

	backup_exclude=$(rsync_exclude_for_source_path "${source_root}" "${backup_root}" || true)
	if [[ -n "${backup_exclude}" ]]; then
		rsync_cmd+=("--exclude=${backup_exclude}")
	fi

	rsync_cmd+=("${source_root}/" "${target_mount}/")

	need_cmd rsync
	"${rsync_cmd[@]}"
}

main()
{
	local source_root="/"
	local target_device=""
	local target_part=""
	local target_mount=""
	local target_uuid=""
	local backup_dir=""
	local update_boot_blocks=1
	local keep_partition_table=0
	local force=0
	local backup_root="${BACKUP_ROOT_DEFAULT}"
	local boot_start_sector="${BOOT_AREA_START_SECTOR_DEFAULT}"
	local -a original_args=("$@")

	need_cmd findmnt
	need_cmd lsblk
	need_cmd blkid
	need_cmd mount
	need_cmd umount
	need_cmd mktemp
	need_cmd mkdir
	need_cmd awk
	need_cmd sed
	need_cmd mountpoint
	need_cmd date
	need_cmd find

	while [[ $# -gt 0 ]]; do
		case "$1" in
			--source-root)
				shift
				[[ $# -gt 0 ]] || die "Missing path after --source-root"
				source_root="$1"
				;;
			--env-only)
				update_boot_blocks=0
				;;
			--keep-partition-table)
				keep_partition_table=1
				;;
			--backup-root)
				shift
				[[ $# -gt 0 ]] || die "Missing path after --backup-root"
				backup_root="$1"
				;;
			--boot-start-sector)
				shift
				[[ $# -gt 0 ]] || die "Missing value after --boot-start-sector"
				boot_start_sector="$1"
				;;
			--force)
				force=1
				;;
			-h|--help)
				usage
				exit 0
				;;
			/dev/*)
				[[ -z "${target_device}" ]] || die "Specify only one target device"
				target_device="$1"
				;;
			*)
				usage
				exit 1
				;;
		esac
		shift
	done

	[[ "${force}" -eq 1 ]] || die "Refusing destructive target copy without --force"
	[[ -n "${target_device}" ]] || die "Missing target device"
	[[ "${backup_root}" == /* ]] || die "Backup root must be an absolute path: ${backup_root}"
	[[ "${boot_start_sector}" =~ ^[0-9]+$ ]] || die "Boot start sector must be numeric: ${boot_start_sector}"

	require_root "${original_args[@]}"
	source_platform_install
	assert_source_root_ready "${source_root}"
	assert_safe_target "${source_root}" "${target_device}"
	backup_dir=$(backup_target_state "${target_device}" "${backup_root}")
	log "Saved target boot-area backup to ${backup_dir}"

	target_part=$(prepare_target_partition "${target_device}" "${keep_partition_table}" "${boot_start_sector}")
	assert_partition_start_safe "${target_part}" "${update_boot_blocks}" "${boot_start_sector}"
	target_mount=$(mktemp -d /tmp/k1x-copy-target.XXXXXX)
	if [[ "${source_root}" != "/" ]]; then
		case "${target_mount}" in
			"${source_root}"|"${source_root}/"*)
				die "Refusing to mount target under the source tree: source=${source_root}, target_mount=${target_mount}"
				;;
		esac
	fi

	cleanup()
	{
		if [[ -n "${target_mount:-}" && -d "${target_mount:-}" ]]; then
			mountpoint -q "${target_mount}" && umount "${target_mount}" || true
			rmdir "${target_mount}" || true
		fi
	}
	trap cleanup EXIT

	mount_target_partition "${target_part}" "${target_mount}"
	ensure_target_capacity "${source_root}" "${target_mount}"
	copy_live_system "${source_root}" "${target_mount}" "${backup_root}"
	mkdir -p "${target_mount}/var/log.hdd"
	target_uuid=$(blkid -s UUID -o value "${target_part}")
	[[ -n "${target_uuid}" ]] || die "Unable to read UUID for ${target_part}"
	[[ -n "$(find "${target_mount}/boot" -mindepth 1 -maxdepth 1 2>/dev/null | head -n 1)" ]] || die "Target /boot is unexpectedly empty after copy"
	update_target_extlinux "${target_mount}" "${target_uuid}"
	update_target_fstab "${target_mount}" "${target_uuid}"
	sync
	umount "${target_mount}"
	rmdir "${target_mount}"
	target_mount=""

	if [[ "${update_boot_blocks}" -eq 1 ]]; then
		write_uboot_platform_with_bootblk "${DIR}" "${target_device}"
	else
		write_uboot_platform "${DIR}" "${target_device}"
	fi

	log "Copied ${source_root} to ${target_part}"
	log "Updated root UUID in target extlinux.conf and fstab to ${target_uuid}"
	log "Target backup is stored at ${backup_dir}"
	if [[ "${update_boot_blocks}" -eq 1 ]]; then
		log "Updated target boot blocks and env_k1-x.txt on ${target_device}"
	else
		log "Updated target env_k1-x.txt on ${target_device}"
	fi
}

main "$@"
