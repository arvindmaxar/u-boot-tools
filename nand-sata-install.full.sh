#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
TARGET_SCRIPT="${SCRIPT_DIR}/copy-live-system.sh"

if [[ ! -x "${TARGET_SCRIPT}" ]]; then
	printf 'Error: Missing %s\n' "${TARGET_SCRIPT}" >&2
	exit 1
fi

printf '%s\n' 'Warning: k1x-nand-sata-install is a compatibility alias for k1x-copy-live-system.' >&2
printf '%s\n' 'Warning: forwarding to the safer copy-live-system flow.' >&2

exec "${TARGET_SCRIPT}" "$@"
