#!/bin/bash

DIR=${DIR:-/usr/lib/linux-u-boot-current-orangepirv2}
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SCRIPT_ARTIFACT_DIR="${SCRIPT_DIR}/artifacts"

spacemit_log()
{
	printf '%s\n' "$*"
}

spacemit_warn()
{
	printf 'Warning: %s\n' "$*" >&2
}

spacemit_fail()
{
	printf 'Error: %s\n' "$*" >&2
	return 1
}

spacemit_need_cmd()
{
	command -v "$1" >/dev/null 2>&1 || spacemit_fail "Required command not found: $1"
}

spacemit_require_root()
{
	[[ ${EUID:-$(id -u)} -eq 0 ]] || spacemit_fail "This helper must run as root"
}

spacemit_assert_block_device()
{
	local device="$1"

	[[ -n "${device}" ]] || spacemit_fail "Missing target device"
	[[ -b "${device}" ]] || spacemit_fail "Target is not a block device: ${device}"
}

spacemit_first_partition()
{
	local device="$1"

	case "${device}" in
		*mmcblk*|*nvme*|*loop*)
			if [[ -b "${device}p1" ]]; then
				printf '%s\n' "${device}p1"
			else
				printf '%s\n' "${device}"
			fi
			;;
		*)
			if [[ -b "${device}1" ]]; then
				printf '%s\n' "${device}1"
			else
				printf '%s\n' "${device}"
			fi
			;;
	esac
}

spacemit_mountpoint_has_boot_files()
{
	local mountpoint="$1"

	[[ -f "${mountpoint}/boot/extlinux/extlinux.conf" ]] || \
	[[ -f "${mountpoint}/boot/boot.scr" ]] || \
	[[ -f "${mountpoint}/boot/boot.scr.uimg" ]] || \
	[[ -f "${mountpoint}/extlinux/extlinux.conf" ]]
}

_spacemit_select_mountpoint_for_part()
{
	local part="$1"
	local candidate
	local selected=""

	while IFS= read -r candidate; do
		[[ -n "${candidate}" ]] || continue
		if spacemit_mountpoint_has_boot_files "${candidate}"; then
			printf '%s\n' "${candidate}"
			return 0
		fi
		if [[ -z "${selected}" || "${candidate}" == "/" ]]; then
			selected="${candidate}"
		fi
	done < <(findmnt -rn -S "${part}" -o TARGET 2>/dev/null || true)

	[[ -n "${selected}" ]] || return 1
	printf '%s\n' "${selected}"
}

spacemit_verify_env_file_content()
{
	local file="$1"

	[[ -f "${file}" ]] || spacemit_fail "Missing env file: ${file}" || return 1
	grep -Fq 'env_source=k1x-usb-first' "${file}" || spacemit_fail "env_source not set as expected in ${file}" || return 1
	grep -Fq 'boot_targets=usb0 mmc2 mmc0 mmc1 nvme0 nvmena pxe dhcp' "${file}" || spacemit_fail "boot_targets not set as expected in ${file}" || return 1
	grep -Fq 'bootcmd_usb0=setenv devnum 0; run usb_boot' "${file}" || spacemit_fail "bootcmd_usb0 not set as expected in ${file}" || return 1
	grep -Fq 'bootcmd_mmc2=setenv devnum 2; run mmc_boot' "${file}" || spacemit_fail "bootcmd_mmc2 not set as expected in ${file}" || return 1
	grep -Fq 'bootcmd=echo "K1X USB-first env imported"; echo "K1X USB-first targets: ${boot_targets}"; echo "K1X USB-first target: usb0"; run bootcmd_usb0; echo "K1X USB-first target: mmc2"; run bootcmd_mmc2; echo "K1X USB-first target: mmc0"; run bootcmd_mmc0; echo "K1X USB-first target: mmc1"; run bootcmd_mmc1; echo "K1X USB-first fallback: run autoboot"; run autoboot; echo "run autoboot"' "${file}" || spacemit_fail "bootcmd not set as expected in ${file}" || return 1
}

write_k1x_usb_first_env_file()
{
	local mountpoint="$1"
	local tempfile

	[[ -d "${mountpoint}" ]] || spacemit_fail "Missing mountpoint for env_k1-x.txt: ${mountpoint}" || return 1
	[[ -w "${mountpoint}" ]] || spacemit_fail "Mountpoint is not writable: ${mountpoint}" || return 1

	tempfile=$(mktemp "${mountpoint}/.env_k1-x.txt.XXXXXX") || return 1
	cat > "${tempfile}" <<'EOF'
env_source=k1x-usb-first
boot_prefixes=/ /boot/
boot_scripts=boot.scr.uimg boot.scr
boot_syslinux_conf=extlinux/extlinux.conf
boot_extlinux=echo "K1X USB-first extlinux: ${prefix}${boot_syslinux_conf}"; sysboot ${devtype} ${devnum}:${distro_bootpart} any ${scriptaddr} ${prefix}${boot_syslinux_conf}
scan_dev_for_extlinux=if test -e ${devtype} ${devnum}:${distro_bootpart} ${prefix}${boot_syslinux_conf}; then echo "K1X USB-first found extlinux: ${prefix}${boot_syslinux_conf}"; run boot_extlinux; fi
boot_a_script=echo "K1X USB-first script: ${prefix}${script}"; load ${devtype} ${devnum}:${distro_bootpart} ${scriptaddr} ${prefix}${script}; source ${scriptaddr}
scan_dev_for_scripts=for script in ${boot_scripts}; do if test -e ${devtype} ${devnum}:${distro_bootpart} ${prefix}${script}; then echo "K1X USB-first found script: ${prefix}${script}"; run boot_a_script; fi; done
scan_dev_for_boot=echo "K1X USB-first scan: ${devtype} ${devnum}:${distro_bootpart}"; for prefix in ${boot_prefixes}; do echo "K1X USB-first prefix: ${prefix}"; run scan_dev_for_extlinux; run scan_dev_for_scripts; done; if env exists scan_dev_for_efi; then run scan_dev_for_efi; fi
scan_dev_for_boot_part=part list ${devtype} ${devnum} -bootable devplist; env exists devplist || setenv devplist 1; for distro_bootpart in ${devplist}; do if fstype ${devtype} ${devnum}:${distro_bootpart} bootfstype; then run scan_dev_for_boot; fi; done; setenv devplist
usb_boot=echo "K1X USB-first probe: usb${devnum}"; usb start; if usb dev ${devnum}; then setenv devtype usb; run scan_dev_for_boot_part; fi
mmc_boot=echo "K1X USB-first probe: mmc${devnum}"; if mmc dev ${devnum}; then setenv devtype mmc; run scan_dev_for_boot_part; fi
bootcmd_usb0=setenv devnum 0; run usb_boot
bootcmd_mmc2=setenv devnum 2; run mmc_boot
bootcmd_mmc0=setenv devnum 0; run mmc_boot
bootcmd_mmc1=setenv devnum 1; run mmc_boot
boot_targets=usb0 mmc2 mmc0 mmc1 nvme0 nvmena pxe dhcp
distro_bootcmd=for target in ${boot_targets}; do echo "K1X USB-first target: ${target}"; run bootcmd_${target}; done
bootcmd=echo "K1X USB-first env imported"; echo "K1X USB-first targets: ${boot_targets}"; echo "K1X USB-first target: usb0"; run bootcmd_usb0; echo "K1X USB-first target: mmc2"; run bootcmd_mmc2; echo "K1X USB-first target: mmc0"; run bootcmd_mmc0; echo "K1X USB-first target: mmc1"; run bootcmd_mmc1; echo "K1X USB-first fallback: run autoboot"; run autoboot; echo "run autoboot"
EOF
	chmod 0644 "${tempfile}" || {
		rm -f "${tempfile}"
		return 1
	}
	mv -f "${tempfile}" "${mountpoint}/env_k1-x.txt" || {
		rm -f "${tempfile}"
		return 1
	}
	sync
}

spacemit_refresh_env_on_mountpoint()
{
	local mountpoint="$1"
	local env_file="${mountpoint}/env_k1-x.txt"

	write_k1x_usb_first_env_file "${mountpoint}" || return 1
	spacemit_verify_env_file_content "${env_file}" || return 1
}

spacemit_refresh_existing_bootfs()
{
	local dir="$1"
	local device="$2"
	local mountpoint
	local reused
	local rc=0
	local -a mount_info

	spacemit_require_root || return 1
	spacemit_assert_block_device "${device}" || return 1
	mapfile -t mount_info < <(_spacemit_mount_device_partition "${device}") || return 1
	mountpoint="${mount_info[1]}"
	reused="${mount_info[2]}"

	if ! spacemit_mountpoint_has_boot_files "${mountpoint}"; then
		spacemit_warn "Skipping ${device}: no boot files found on $(spacemit_first_partition "${device}")"
		rc=1
	else
		spacemit_refresh_env_on_mountpoint "${mountpoint}" || rc=1
	fi

	_spacemit_release_mountpoint "${mountpoint}" "${reused}" || rc=1
	return "${rc}"
}

_spacemit_find_artifact()
{
	local dir="$1"
	local name="$2"
	local candidate
	local -a candidates=(
		"${SCRIPT_ARTIFACT_DIR}/${name}"
		"${SCRIPT_DIR}/${name}"
		"${dir}/${name}"
		"/usr/lib/linux-u-boot-current-orangepirv2/${name}"
		"/usr/lib/linux-u-boot-current-orangepir2s_1.0.0_riscv64/${name}"
	)

	if [[ "${name}" == "bootinfo_sd.bin" ]]; then
		candidates+=("/media/usr/lib/linux-u-boot-current-orangepir2s_1.0.0_riscv64/${name}")
	fi

	for candidate in "${candidates[@]}"; do
		if [[ -f "${candidate}" ]]; then
			printf '%s\n' "${candidate}"
			return 0
		fi
	done

	return 1
}

_spacemit_require_artifact()
{
	local dir="$1"
	local name="$2"
	local artifact

	artifact=$(_spacemit_find_artifact "${dir}" "${name}") || {
		spacemit_fail "Missing required artifact: ${name}"
		return 1
	}

	printf '%s\n' "${artifact}"
}

_spacemit_boot_block_profile()
{
	local dir="$1"

	if _spacemit_find_artifact "${dir}" "u-boot-opensbi.itb" >/dev/null 2>&1; then
		printf '%s\n' "legacy-opensbi"
		return 0
	fi

	if _spacemit_find_artifact "${dir}" "fw_dynamic.itb" >/dev/null 2>&1 && \
	   _spacemit_find_artifact "${dir}" "u-boot.itb" >/dev/null 2>&1; then
		printf '%s\n' "current-fit"
		return 0
	fi

	return 1
}

spacemit_boot_block_specs()
{
	local dir="$1"
	local device="$2"
	local profile
	local artifact

	spacemit_assert_block_device "${device}" || return 1
	profile=$(_spacemit_boot_block_profile "${dir}") || {
		spacemit_fail "Unsupported boot-block artifact set in ${dir}"
		return 1
	}

	if [[ -b "${device}boot0" ]]; then
		artifact=$(_spacemit_require_artifact "${dir}" "bootinfo_emmc.bin") || return 1
		printf '%s|%s|%s|%s\n' "bootinfo_emmc.bin" "${artifact}" "${device}boot0" "0"

		artifact=$(_spacemit_require_artifact "${dir}" "FSBL.bin") || return 1
		printf '%s|%s|%s|%s\n' "FSBL.boot0" "${artifact}" "${device}boot0" "512"
	fi

	case "${profile}" in
		legacy-opensbi)
			artifact=$(_spacemit_require_artifact "${dir}" "bootinfo_sd.bin") || return 1
			printf '%s|%s|%s|%s\n' "bootinfo_sd.bin" "${artifact}" "${device}" "0"

			artifact=$(_spacemit_require_artifact "${dir}" "FSBL.bin") || return 1
			printf '%s|%s|%s|%s\n' "FSBL.bin" "${artifact}" "${device}" "131072"

			artifact=$(_spacemit_require_artifact "${dir}" "u-boot-env-default.bin") || return 1
			printf '%s|%s|%s|%s\n' "u-boot-env-default.bin" "${artifact}" "${device}" "393216"

			artifact=$(_spacemit_require_artifact "${dir}" "u-boot-opensbi.itb") || return 1
			printf '%s|%s|%s|%s\n' "u-boot-opensbi.itb" "${artifact}" "${device}" "851968"
			;;
		current-fit)
			if [[ ! -b "${device}boot0" ]]; then
				artifact=$(_spacemit_require_artifact "${dir}" "bootinfo_emmc.bin") || return 1
				printf '%s|%s|%s|%s\n' "bootinfo_emmc.bin" "${artifact}" "${device}" "0"

				artifact=$(_spacemit_require_artifact "${dir}" "FSBL.bin") || return 1
				printf '%s|%s|%s|%s\n' "FSBL.bin" "${artifact}" "${device}" "512"
			fi

			artifact=$(_spacemit_require_artifact "${dir}" "fw_dynamic.itb") || return 1
			printf '%s|%s|%s|%s\n' "fw_dynamic.itb" "${artifact}" "${device}" "655360"

			artifact=$(_spacemit_require_artifact "${dir}" "u-boot.itb") || return 1
			printf '%s|%s|%s|%s\n' "u-boot.itb" "${artifact}" "${device}" "1048576"
			;;
	esac
}

_spacemit_set_boot0_force_ro()
{
	local device="$1"
	local value="$2"
	local sysfs="/sys/block/${device##*/}boot0/force_ro"

	if [[ -e "${sysfs}" ]]; then
		printf '%s\n' "${value}" > "${sysfs}" || return 1
	fi
}

spacemit_write_boot_blocks()
{
	local dir="$1"
	local device="$2"
	local specs_text
	local label artifact target offset
	local rc=0
	local restore_boot0=0

	spacemit_require_root || return 1
	spacemit_need_cmd dd || return 1
	spacemit_assert_block_device "${device}" || return 1
	specs_text=$(spacemit_boot_block_specs "${dir}" "${device}") || return 1
	[[ -n "${specs_text}" ]] || return 1

	if [[ -b "${device}boot0" ]]; then
		_spacemit_set_boot0_force_ro "${device}" 0 || return 1
		restore_boot0=1
	fi

	while IFS='|' read -r label artifact target offset; do
		[[ -n "${label}" ]] || continue
		dd if="${artifact}" of="${target}" bs=1 seek="${offset}" conv=notrunc status=none || {
			spacemit_warn "Failed to write ${label} to ${target} at offset ${offset}"
			rc=1
			break
		}
	done <<< "${specs_text}"

	sync
	if [[ "${restore_boot0}" -eq 1 ]]; then
		_spacemit_set_boot0_force_ro "${device}" 1 || rc=1
	fi

	return "${rc}"
}

spacemit_verify_boot_block_hashes()
{
	local dir="$1"
	local device="$2"
	local specs_text
	local label artifact target offset
	local size expected actual

	spacemit_need_cmd dd || return 1
	spacemit_need_cmd sha256sum || return 1
	spacemit_assert_block_device "${device}" || return 1
	specs_text=$(spacemit_boot_block_specs "${dir}" "${device}") || return 1
	[[ -n "${specs_text}" ]] || return 1

	while IFS='|' read -r label artifact target offset; do
		[[ -n "${label}" ]] || continue
		size=$(wc -c < "${artifact}") || return 1
		expected=$(sha256sum "${artifact}" | awk '{print $1}') || return 1
		actual=$(dd if="${target}" bs=1 skip="${offset}" count="${size}" status=none | sha256sum | awk '{print $1}') || return 1

		if [[ "${expected}" != "${actual}" ]]; then
			spacemit_fail "Hash mismatch for ${label}: expected ${expected}, got ${actual}"
			return 1
		fi
	done <<< "${specs_text}"
}

_spacemit_mount_device_partition()
{
	local device="$1"
	local part
	local mountpoint
	local reused=0

	spacemit_require_root || return 1
	spacemit_need_cmd findmnt || return 1
	spacemit_need_cmd mount || return 1
	spacemit_need_cmd mktemp || return 1
	spacemit_assert_block_device "${device}" || return 1

	part=$(spacemit_first_partition "${device}")
	[[ -b "${part}" ]] || {
		spacemit_fail "No usable target partition found for ${device}"
		return 1
	}

	mountpoint=$(_spacemit_select_mountpoint_for_part "${part}" || true)
	if [[ -n "${mountpoint}" ]]; then
		reused=1
	else
		mountpoint=$(mktemp -d /tmp/k1x-bootfs.XXXXXX) || return 1
		if ! mount "${part}" "${mountpoint}"; then
			rmdir "${mountpoint}"
			return 1
		fi
	fi

	printf '%s\n%s\n%s\n' "${part}" "${mountpoint}" "${reused}"
}

_spacemit_release_mountpoint()
{
	local mountpoint="$1"
	local reused="${2:-0}"
	local rc=0

	[[ -n "${mountpoint}" ]] || return 0
	if [[ "${reused}" -eq 0 ]]; then
		umount "${mountpoint}" || rc=1
		rmdir "${mountpoint}" || rc=1
	fi

	return "${rc}"
}

write_uboot_platform ()
{
	local device="$2"
	local mountpoint
	local reused
	local rc=0
	local -a mount_info

	spacemit_require_root || return 1
	mapfile -t mount_info < <(_spacemit_mount_device_partition "${device}") || return 1
	mountpoint="${mount_info[1]}"
	reused="${mount_info[2]}"
	spacemit_refresh_env_on_mountpoint "${mountpoint}" || rc=1
	_spacemit_release_mountpoint "${mountpoint}" "${reused}" || rc=1

	return "${rc}"
}

write_uboot_platform_with_bootblk ()
{
	local dir="$1"
	local device="$2"

	write_uboot_platform "${dir}" "${device}" || return 1
	spacemit_write_boot_blocks "${dir}" "${device}" || return 1
	spacemit_verify_boot_block_hashes "${dir}" "${device}"
}

write_uboot_platform_mtd ()
{
	spacemit_fail "MTD env update is not implemented in this standalone helper"
}
