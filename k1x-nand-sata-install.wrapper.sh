#!/bin/sh
printf '%s\n' 'Warning: k1x-nand-sata-install is a compatibility alias for k1x-copy-live-system.' >&2
exec /usr/local/lib/u-boot-tools/copy-live-system.sh "$@"
