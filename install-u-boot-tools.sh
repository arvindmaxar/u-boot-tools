#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
INSTALL_ROOT="/usr/local/lib/u-boot-tools"
LOCAL_SBIN="/usr/local/sbin"
SYSTEM_SBIN="/usr/sbin"
POSTINST_ROOT="/etc/kernel/postinst.d"
PACKAGE_TOOL_DIR="${SCRIPT_DIR}/lib/u-boot-tools"
PACKAGE_SBIN_DIR="${SCRIPT_DIR}/sbin"
PACKAGE_POSTINST_DIR="${SCRIPT_DIR}/kernel-postinst"
ARTIFACT_ROOT="${INSTALL_ROOT}/artifacts"

log()
{
	printf '%s\n' "$*"
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
	[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run this installer with sudo"
}

assert_package_layout()
{
	[[ -d "${PACKAGE_TOOL_DIR}" ]] || die "Missing package tool directory: ${PACKAGE_TOOL_DIR}"
	[[ -d "${PACKAGE_SBIN_DIR}" ]] || die "Missing package wrapper directory: ${PACKAGE_SBIN_DIR}"
	[[ -d "${PACKAGE_POSTINST_DIR}" ]] || die "Missing package postinst directory: ${PACKAGE_POSTINST_DIR}"
	[[ -f "${PACKAGE_TOOL_DIR}/platform_install.sh" ]] || die "Incomplete package: platform_install.sh missing"
	[[ -f "${PACKAGE_TOOL_DIR}/copy-live-system.sh" ]] || die "Incomplete package: copy-live-system.sh missing"
	[[ -f "${PACKAGE_SBIN_DIR}/k1x-copy-live-system" ]] || die "Incomplete package: k1x-copy-live-system wrapper missing"
	[[ -f "${PACKAGE_POSTINST_DIR}/99-k1x-usb-first-env" ]] || die "Incomplete package: postinst hook missing"
}

copy_if_present()
{
	local source="$1"
	local target_dir="$2"

	if [[ -f "${source}" ]]; then
		install -m 0644 "${source}" "${target_dir}/$(basename "${source}")"
	fi
}

copy_artifacts_from_dir()
{
	local source_dir="$1"
	local artifact

	[[ -d "${source_dir}" ]] || return 0

	for artifact in \
		bootinfo_emmc.bin \
		bootinfo_spinor.bin \
		FSBL.bin \
		fw_dynamic.itb \
		u-boot.itb \
		u-boot-env-default.bin \
		bootinfo_sd.bin \
		u-boot-opensbi.itb
	do
		copy_if_present "${source_dir}/${artifact}" "${ARTIFACT_ROOT}"
	done
}

install_toolkit()
{
	install -d -m 0755 "${INSTALL_ROOT}" "${ARTIFACT_ROOT}" "${LOCAL_SBIN}" "${SYSTEM_SBIN}" "${POSTINST_ROOT}"

	install -m 0755 "${PACKAGE_TOOL_DIR}/platform_install.sh" "${INSTALL_ROOT}/platform_install.sh"
	install -m 0755 "${PACKAGE_TOOL_DIR}/refresh-env.sh" "${INSTALL_ROOT}/refresh-env.sh"
	install -m 0755 "${PACKAGE_TOOL_DIR}/test-platform-install.sh" "${INSTALL_ROOT}/test-platform-install.sh"
	install -m 0755 "${PACKAGE_TOOL_DIR}/copy-live-system.sh" "${INSTALL_ROOT}/copy-live-system.sh"
	install -m 0755 "${PACKAGE_TOOL_DIR}/nand-sata-install.sh" "${INSTALL_ROOT}/nand-sata-install.sh"
	install -m 0644 "${PACKAGE_TOOL_DIR}/README.md" "${INSTALL_ROOT}/README.md"

	install -m 0755 "${PACKAGE_SBIN_DIR}/k1x-refresh-env" "${LOCAL_SBIN}/k1x-refresh-env"
	install -m 0755 "${PACKAGE_SBIN_DIR}/k1x-test-platform-install" "${LOCAL_SBIN}/k1x-test-platform-install"
	install -m 0755 "${PACKAGE_SBIN_DIR}/k1x-nand-sata-install" "${LOCAL_SBIN}/k1x-nand-sata-install"
	install -m 0755 "${PACKAGE_SBIN_DIR}/k1x-copy-live-system" "${SYSTEM_SBIN}/k1x-copy-live-system"

	install -m 0755 "${PACKAGE_POSTINST_DIR}/99-k1x-usb-first-env" "${POSTINST_ROOT}/99-k1x-usb-first-env"
}

populate_artifacts()
{
	copy_artifacts_from_dir "${PACKAGE_TOOL_DIR}/artifacts"
	copy_artifacts_from_dir "/usr/lib/linux-u-boot-current-orangepirv2"
	copy_artifacts_from_dir "/usr/lib/linux-u-boot-current-orangepir2s_1.0.0_riscv64"
	copy_artifacts_from_dir "/media/usr/lib/linux-u-boot-current-orangepir2s_1.0.0_riscv64"
}

verify_install()
{
	bash -n "${INSTALL_ROOT}/platform_install.sh"
	bash -n "${INSTALL_ROOT}/refresh-env.sh"
	bash -n "${INSTALL_ROOT}/test-platform-install.sh"
	bash -n "${INSTALL_ROOT}/copy-live-system.sh"
	bash -n "${INSTALL_ROOT}/nand-sata-install.sh"
	bash -n "${POSTINST_ROOT}/99-k1x-usb-first-env"
}

main()
{
	need_cmd install
	need_cmd bash
	require_root
	assert_package_layout

	install_toolkit
	populate_artifacts
	verify_install

	"${INSTALL_ROOT}/refresh-env.sh" --allow-empty || true

	log "Installed toolkit under ${INSTALL_ROOT}"
	log "Installed wrappers under ${LOCAL_SBIN} and ${SYSTEM_SBIN}"
	log "Installed kernel postinst hook at ${POSTINST_ROOT}/99-k1x-usb-first-env"
}

main "$@"
