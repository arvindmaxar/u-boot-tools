#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
PLATFORM_INSTALL="${SCRIPT_DIR}/platform_install.sh"
BACKUP_DIR="${SCRIPT_DIR}/backups"

log()
{
	printf '%s\n' "$*"
}

die()
{
	printf 'Error: %s\n' "$*" >&2
	exit 1
}

usage()
{
	cat <<'EOF'
Usage:
  sudo ./test-platform-install.sh
    Create a loopback ext4 filesystem, write env_k1-x.txt to it, and verify it.

  sudo ./test-platform-install.sh -bootblk
    Create a loopback image with a boot partition, write env_k1-x.txt and the
    raw boot blocks, then verify both.

  sudo ./test-platform-install.sh -emmc /dev/mmcblk2
    Back up the current env_k1-x.txt from the target partition, write a new
    USB-first env_k1-x.txt, and verify its contents.

  sudo ./test-platform-install.sh -emmc /dev/mmcblk2 -bootblk
    Back up env_k1-x.txt plus the current raw boot blocks, then write and
    verify both.

  sudo ./test-platform-install.sh -rollback /dev/mmcblk2
    Restore the previously backed up env_k1-x.txt and, if present, the raw
    boot block backups for the given device.
EOF
}

need_cmd()
{
	command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
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

assert_target_device()
{
	local device="$1"

	if declare -F spacemit_assert_block_device >/dev/null 2>&1; then
		spacemit_assert_block_device "${device}" || exit 1
	else
		[[ -b "${device}" ]] || die "Target is not a block device: ${device}"
	fi
}

partition_mountpoint()
{
	local part="$1"
	local mountpoint

	if declare -F _spacemit_select_mountpoint_for_part >/dev/null 2>&1; then
		mountpoint=$(_spacemit_select_mountpoint_for_part "${part}" || true)
	else
		mountpoint=$(findmnt -rn -S "${part}" -o TARGET 2>/dev/null | head -n 1 || true)
	fi
	printf '%s\n' "${mountpoint}"
}

mount_target_partition()
{
	local device="$1"
	local part
	local mountpoint
	local reused=0

	assert_target_device "${device}"
	part=$(spacemit_first_partition "${device}")
	[[ -b "${part}" ]] || die "No usable target partition found for ${device}"

	mountpoint=$(partition_mountpoint "${part}")
	if [[ -n "${mountpoint}" ]]; then
		reused=1
	else
		mountpoint=$(mktemp -d /tmp/k1x-env.XXXXXX)
		mount "${part}" "${mountpoint}"
	fi

	printf '%s\n%s\n%s\n' "${part}" "${mountpoint}" "${reused}"
}

unmount_target_partition_if_needed()
{
	local mountpoint="$1"
	local reused="$2"

	if [[ "${reused}" -eq 0 ]]; then
		umount "${mountpoint}"
		rmdir "${mountpoint}"
	fi
}

verify_env_file_content()
{
	local file="$1"

	if declare -F spacemit_verify_env_file_content >/dev/null 2>&1; then
		spacemit_verify_env_file_content "${file}" || exit 1
	else
		[[ -f "${file}" ]] || die "Missing env file: ${file}"
		grep -Fq 'env_source=k1x-usb-first' "${file}" || die "env_source not set as expected in ${file}"
		grep -Fq 'boot_targets=usb0 mmc2 mmc0 mmc1 nvme0 nvmena pxe dhcp' "${file}" || die "boot_targets not set as expected in ${file}"
		grep -Fq 'bootcmd_usb0=setenv devnum 0; run usb_boot' "${file}" || die "bootcmd_usb0 not set as expected in ${file}"
		grep -Fq 'bootcmd_mmc2=setenv devnum 2; run mmc_boot' "${file}" || die "bootcmd_mmc2 not set as expected in ${file}"
		grep -Fq 'bootcmd=echo "K1X USB-first env imported"; echo "K1X USB-first targets: ${boot_targets}"; echo "K1X USB-first target: usb0"; run bootcmd_usb0; echo "K1X USB-first target: mmc2"; run bootcmd_mmc2; echo "K1X USB-first target: mmc0"; run bootcmd_mmc0; echo "K1X USB-first target: mmc1"; run bootcmd_mmc1; echo "K1X USB-first fallback: run autoboot"; run autoboot; echo "run autoboot"' "${file}" || die "bootcmd not set as expected in ${file}"
	fi
	log "Verified ${file}"
}

env_backup_paths()
{
	local device="$1"
	local base="${device##*/}"

	mkdir -p "${BACKUP_DIR}"
	printf '%s\n%s\n' \
		"${BACKUP_DIR}/${base}.env_k1-x.txt.backup" \
		"${BACKUP_DIR}/${base}.env_k1-x.txt.absent"
}

bootblk_backup_paths()
{
	local device="$1"
	local base="${device##*/}"

	mkdir -p "${BACKUP_DIR}"
	printf '%s\n%s\n' \
		"${BACKUP_DIR}/${base}.boot0.backup.bin" \
		"${BACKUP_DIR}/${base}.first8M.backup.bin"
}

backup_env_file()
{
	local device="$1"
	local part mountpoint reused
	local backup_file absent_marker current_file
	local rc=0
	local -a paths
	local -a mount_info

	assert_target_device "${device}"
	mapfile -t paths < <(env_backup_paths "${device}")
	backup_file="${paths[0]}"
	absent_marker="${paths[1]}"

	mapfile -t mount_info < <(mount_target_partition "${device}")
	part="${mount_info[0]}"
	mountpoint="${mount_info[1]}"
	reused="${mount_info[2]}"
	current_file="${mountpoint}/env_k1-x.txt"

	rm -f "${backup_file}" "${absent_marker}"
	if [[ -f "${current_file}" ]]; then
		cp "${current_file}" "${backup_file}" || rc=1
		[[ "${rc}" -eq 0 ]] && log "Backed up ${current_file} to ${backup_file}"
	else
		: > "${absent_marker}" || rc=1
		[[ "${rc}" -eq 0 ]] && log "Recorded absence of ${current_file}"
	fi

	unmount_target_partition_if_needed "${mountpoint}" "${reused}" || rc=1
	return "${rc}"
}

backup_boot_blocks()
{
	local device="$1"
	local boot0="${device}boot0"
	local boot0_backup main_backup
	local -a paths

	assert_target_device "${device}"
	mapfile -t paths < <(bootblk_backup_paths "${device}")
	boot0_backup="${paths[0]}"
	main_backup="${paths[1]}"

	rm -f "${boot0_backup}" "${main_backup}"
	if [[ -b "${boot0}" ]]; then
		dd if="${boot0}" of="${boot0_backup}" bs=1M status=none
		log "Backed up ${boot0} to ${boot0_backup}"
	fi

	dd if="${device}" of="${main_backup}" bs=1M count=8 status=none
	log "Backed up first 8 MiB of ${device} to ${main_backup}"
}

write_env_to_device()
{
	local device="$1"
	local part mountpoint reused env_file
	local rc=0
	local -a mount_info

	assert_target_device "${device}"
	mapfile -t mount_info < <(mount_target_partition "${device}")
	part="${mount_info[0]}"
	mountpoint="${mount_info[1]}"
	reused="${mount_info[2]}"

	write_k1x_usb_first_env_file "${mountpoint}" || rc=1
	env_file="${mountpoint}/env_k1-x.txt"
	verify_env_file_content "${env_file}" || rc=1
	[[ "${rc}" -eq 0 ]] && log "Wrote env_k1-x.txt to ${part}"

	unmount_target_partition_if_needed "${mountpoint}" "${reused}" || rc=1
	return "${rc}"
}

write_boot_blocks_to_device()
{
	local device="$1"

	assert_target_device "${device}"
	spacemit_write_boot_blocks "${DIR}" "${device}"
	spacemit_verify_boot_block_hashes "${DIR}" "${device}"
	log "Wrote and verified raw boot blocks on ${device}"
}

rollback_env_file()
{
	local device="$1"
	local part mountpoint reused
	local backup_file absent_marker target_file
	local rc=0
	local -a paths
	local -a mount_info

	assert_target_device "${device}"
	mapfile -t paths < <(env_backup_paths "${device}")
	backup_file="${paths[0]}"
	absent_marker="${paths[1]}"

	[[ -f "${backup_file}" || -f "${absent_marker}" ]] || die "No env_k1-x.txt backup recorded for ${device}"

	mapfile -t mount_info < <(mount_target_partition "${device}")
	part="${mount_info[0]}"
	mountpoint="${mount_info[1]}"
	reused="${mount_info[2]}"
	target_file="${mountpoint}/env_k1-x.txt"

	if [[ -f "${backup_file}" ]]; then
		cp "${backup_file}" "${target_file}" || rc=1
		[[ "${rc}" -eq 0 ]] && log "Restored ${target_file} from ${backup_file}"
	else
		rm -f "${target_file}" || rc=1
		[[ "${rc}" -eq 0 ]] && log "Removed ${target_file} because it was absent before the test"
	fi
	sync || rc=1

	unmount_target_partition_if_needed "${mountpoint}" "${reused}" || rc=1
	return "${rc}"
}

rollback_boot_blocks()
{
	local device="$1"
	local boot0="${device}boot0"
	local boot0_backup main_backup
	local force_ro="/sys/block/${device##*/}boot0/force_ro"
	local original_force_ro=""
	local boot0_force_ro_changed=0
	local restored=0
	local -a paths

	assert_target_device "${device}"
	mapfile -t paths < <(bootblk_backup_paths "${device}")
	boot0_backup="${paths[0]}"
	main_backup="${paths[1]}"

	if [[ -f "${main_backup}" ]]; then
		dd if="${main_backup}" of="${device}" bs=1M conv=fsync status=none
		log "Restored first 8 MiB of ${device} from ${main_backup}"
		restored=1
	fi

	if [[ -f "${boot0_backup}" && -b "${boot0}" ]]; then
		if [[ -e "${force_ro}" ]]; then
			original_force_ro=$(cat "${force_ro}" 2>/dev/null || printf '1')
			printf '0\n' > "${force_ro}" || die "Failed to make ${boot0} writable"
			boot0_force_ro_changed=1
		fi
		if ! dd if="${boot0_backup}" of="${boot0}" bs=1M conv=fsync status=none; then
			if [[ "${boot0_force_ro_changed}" -eq 1 ]]; then
				printf '%s\n' "${original_force_ro:-1}" > "${force_ro}" || true
			fi
			die "Failed to restore ${boot0} from ${boot0_backup}"
		fi
		if [[ "${boot0_force_ro_changed}" -eq 1 ]]; then
			printf '%s\n' "${original_force_ro:-1}" > "${force_ro}" || die "Failed to restore ${force_ro}"
		fi
		log "Restored ${boot0} from ${boot0_backup}"
		restored=1
	fi

	if [[ "${restored}" -eq 0 ]]; then
		log "No raw boot block backups recorded for ${device}"
	fi
}

loopback_test()
{
	local bootblk="$1"
	local image=""
	local loopdev=""
	local partloop=""
	local mountpoint=""
	local bootfs_offset=$((16 * 1024 * 1024))

	need_cmd losetup
	need_cmd truncate
	need_cmd mkfs.ext4
	need_cmd mountpoint
	source_platform_install

	cleanup()
	{
		[[ -n "${mountpoint:-}" ]] && mountpoint -q "${mountpoint}" && umount "${mountpoint}" || true
		[[ -n "${mountpoint:-}" && -d "${mountpoint:-}" ]] && rmdir "${mountpoint}" || true
		[[ -n "${partloop:-}" ]] && losetup -d "${partloop}" >/dev/null 2>&1 || true
		[[ -n "${loopdev:-}" ]] && losetup -d "${loopdev}" >/dev/null 2>&1 || true
		[[ -n "${image:-}" ]] && rm -f "${image}"
	}
	trap cleanup EXIT

	image=$(mktemp /tmp/k1x-env-loop.XXXXXX.img)
	if [[ "${bootblk}" -eq 1 ]]; then
		truncate -s 128M "${image}"
		loopdev=$(losetup --show -f "${image}")
		partloop=$(losetup --show -f -o "${bootfs_offset}" "${image}")
		mkfs.ext4 -qF -L bootfs "${partloop}"
		mountpoint=$(mktemp -d /tmp/k1x-env-mnt.XXXXXX)
		mount "${partloop}" "${mountpoint}"
		spacemit_write_boot_blocks "${DIR}" "${loopdev}"
		spacemit_verify_boot_block_hashes "${DIR}" "${loopdev}"
	else
		truncate -s 64M "${image}"
		loopdev=$(losetup --show -f "${image}")
		mkfs.ext4 -qF -L bootfs "${loopdev}"
		mountpoint=$(mktemp -d /tmp/k1x-env-mnt.XXXXXX)
		mount "${loopdev}" "${mountpoint}"
	fi

	write_k1x_usb_first_env_file "${mountpoint}"
	verify_env_file_content "${mountpoint}/env_k1-x.txt"

	if [[ "${bootblk}" -eq 1 ]]; then
		log "Loopback env_k1-x.txt plus boot block test passed"
	else
		log "Loopback env_k1-x.txt test passed"
	fi
}

write_emmc()
{
	local device="$1"
	local bootblk="$2"

	source_platform_install
	backup_env_file "${device}"
	if [[ "${bootblk}" -eq 1 ]]; then
		backup_boot_blocks "${device}"
		write_boot_blocks_to_device "${device}"
	fi
	write_env_to_device "${device}"
	log "Target update passed for ${device}"
}

rollback_device()
{
	local device="$1"

	source_platform_install
	rollback_boot_blocks "${device}"
	rollback_env_file "${device}"
	log "Rollback completed for ${device}"
}

main()
{
	local mode="loop"
	local device=""
	local bootblk=0
	local -a original_args=("$@")

	need_cmd dd
	need_cmd awk
	need_cmd grep
	need_cmd findmnt
	need_cmd lsblk
	need_cmd mount
	need_cmd umount
	need_cmd mktemp
	need_cmd cp
	need_cmd sha256sum

	while [[ $# -gt 0 ]]; do
		case "$1" in
			-bootblk)
				bootblk=1
				;;
			-emmc)
				[[ "${mode}" == "loop" ]] || die "Specify only one of -emmc or -rollback"
				mode="emmc"
				shift
				[[ $# -gt 0 ]] || die "Missing device after -emmc"
				device="$1"
				;;
			-rollback)
				[[ "${mode}" == "loop" ]] || die "Specify only one of -emmc or -rollback"
				mode="rollback"
				shift
				[[ $# -gt 0 ]] || die "Missing device after -rollback"
				device="$1"
				;;
			-h|--help)
				usage
				exit 0
				;;
			*)
				usage
				exit 1
				;;
		esac
		shift
	done

	require_root "${original_args[@]}"

	case "${mode}" in
		loop)
			loopback_test "${bootblk}"
			;;
		emmc)
			write_emmc "${device}" "${bootblk}"
			;;
		rollback)
			rollback_device "${device}"
			;;
	esac
}

main "$@"
