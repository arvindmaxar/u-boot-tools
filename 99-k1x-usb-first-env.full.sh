#!/bin/bash

TOOL_DIR=/usr/local/lib/u-boot-tools
REFRESH_ENV="${TOOL_DIR}/refresh-env.sh"

if [[ -x "${REFRESH_ENV}" ]]; then
	"${REFRESH_ENV}" --allow-empty || true
fi

exit 0
