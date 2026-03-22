# K1X USB-First Toolkit Spec

## Purpose

This workspace contains a standalone U-Boot/boot-management toolkit for the
SpacemiT K1X OrangePi RV2 / R2S-style Armbian systems.

The toolkit keeps custom boot logic outside package-managed `/usr/bin` and
`/usr/lib` paths by installing into `/usr/local`.

## Current Board State

- Primary active board: `armbian@10.0.0.44`
- Running system: USB-based Armbian root on `/dev/sda1`
- eMMC device: `/dev/mmcblk2`
- Current kernel observed during the work: `6.18.18-current-spacemit`
- Installed U-Boot package dir on the board:
  `/usr/lib/linux-u-boot-current-orangepirv2`

Important boot detail:
- The current U-Boot on this platform imports `/env_k1-x.txt` from the boot
  filesystem root.
- The USB-first policy is therefore implemented in `env_k1-x.txt`, not in the
  raw saved env blob alone.

## Installed Toolkit Layout

On the board, the intended permanent install layout is:

- `/usr/local/lib/u-boot-tools/`
- `/usr/local/lib/u-boot-tools/artifacts/`
- `/usr/local/sbin/k1x-refresh-env`
- `/usr/local/sbin/k1x-test-platform-install`
- `/usr/local/sbin/k1x-nand-sata-install`
- `/usr/local/sbin/k1x-copy-live-system`
- `/etc/kernel/postinst.d/99-k1x-usb-first-env`

The wrappers in `/usr/local/sbin` are tiny `exec` scripts that call the real
implementation under `/usr/local/lib/u-boot-tools`.

## USB-First Boot Logic

The generated `env_k1-x.txt` does this:

- tries `usb0` first
- then falls back to `mmc2`
- then `mmc0`
- then `mmc1`
- then falls back to `autoboot`

It prints visible U-Boot markers such as:

- `K1X USB-first env imported`
- `K1X USB-first target: usb0`
- `K1X USB-first probe: usb0`
- `K1X USB-first found extlinux: ...`

Important fix that was needed:
- explicit `setenv devnum 0` for `bootcmd_usb0`
- explicit `setenv devnum 2` for `bootcmd_mmc2`

Without that, the imported env could probe the wrong USB device number and
fall through to eMMC incorrectly.

## Automatic Refresh Behavior

`k1x-refresh-env` refreshes `env_k1-x.txt` on:

- the current root device
- `/dev/sda`
- `/dev/mmcblk2`

with duplicates removed.

The kernel postinst hook
`/etc/kernel/postinst.d/99-k1x-usb-first-env` calls that same refresh path
after kernel upgrades.

Result:
- normal kernel upgrades should refresh both USB and eMMC env files
- raw boot blocks are **not** rewritten automatically during upgrades

## Important Local Source Files

- `/Users/arvindsrinivasan/Code:Codex/platform_install.full.sh`
- `/Users/arvindsrinivasan/Code:Codex/refresh-env.full.sh`
- `/Users/arvindsrinivasan/Code:Codex/test-platform-install.full.sh`
- `/Users/arvindsrinivasan/Code:Codex/nand-sata-install.full.sh`
- `/Users/arvindsrinivasan/Code:Codex/copy-live-system.full.sh`
- `/Users/arvindsrinivasan/Code:Codex/install-k1x-u-boot-tools.full.sh`
- `/Users/arvindsrinivasan/Code:Codex/cleanup-k1x-loopback.full.sh`
- `/Users/arvindsrinivasan/Code:Codex/README.u-boot-tools.md`

Wrappers:

- `/Users/arvindsrinivasan/Code:Codex/k1x-refresh-env.wrapper.sh`
- `/Users/arvindsrinivasan/Code:Codex/k1x-test-platform-install.wrapper.sh`
- `/Users/arvindsrinivasan/Code:Codex/k1x-nand-sata-install.wrapper.sh`
- `/Users/arvindsrinivasan/Code:Codex/k1x-copy-live-system.wrapper.sh`

## Script Roles

### `platform_install.full.sh`

Core shared helper library.

Handles:
- generating `env_k1-x.txt`
- refreshing env on mounted or unmounted targets
- writing raw boot blocks
- verifying boot-block hashes

It now includes defensive guards and mountpoint selection logic that prefers a
single sane mount target even when `findmnt` returns multiple targets for the
same filesystem (for example `/` and `/var/log.hdd`).

### `refresh-env.full.sh`

Safe operational helper for refreshing `env_k1-x.txt` across known targets.

### `test-platform-install.full.sh`

Safe test helper.

Supports:
- loopback env-only test
- loopback env + bootblock test
- target-device env test
- target-device env + bootblock test
- rollback

### `nand-sata-install.full.sh`

Compatibility alias only.

It now forwards to `copy-live-system.full.sh` so there is a single safer
copy/install flow instead of two divergent implementations.

### `copy-live-system.full.sh`

New helper to clone the current live root filesystem to another block device.

Behavior:
- requires `--force`
- repartitions the target by default to a single GPT ext4 partition
  starting at sector `32768` (16 MiB)
- reformats the target root partition
- rsyncs the current live root filesystem to the target
- updates target `/boot/extlinux/extlinux.conf`
- updates target `/etc/fstab`
- then calls `platform_install.sh` to refresh env and, by default, raw boot
  blocks too
- for current-fit eMMC targets with `boot0`, the raw boot update must leave
  `bootinfo_emmc.bin` and `FSBL.bin` on `boot0` only and keep the main user
  area writes to `fw_dynamic.itb` and `u-boot.itb`

Key options:
- `--env-only`
- `--keep-partition-table`
- `--source-root PATH`

Defensive guards added:
- requires `--force`
- requires an absolute source root with `/boot/extlinux/extlinux.conf`
- refuses mounted or non-whole-disk targets
- refuses overwriting the live source device
- creates a pre-write backup of target boot areas under
  `/var/tmp/k1x-copy-live-system-backups/`
- checks target free space before `rsync`
- verifies the reformatted target is `ext4` and mounts it explicitly as `ext4`
- excludes the backup directory from the copy
- refuses a target mountpoint that would live under a non-root source tree
- refuses partition layouts that would overlap the raw boot-block region

## Known Board-Side Paths

Board-side README:
- `/usr/local/lib/u-boot-tools/README.md`

Current installed wrappers on the board:
- `/usr/local/sbin/k1x-refresh-env`
- `/usr/local/sbin/k1x-test-platform-install`
- `/usr/local/sbin/k1x-nand-sata-install`

The local source now also defines:
- `/usr/local/sbin/k1x-copy-live-system`

If a new session needs to verify whether that last wrapper has been deployed,
inspect `/usr/local/lib/u-boot-tools` and `/usr/local/sbin` on `10.0.0.44`.

Important cleanup decision:
- `k1x-nand-sata-install` should be treated as a compatibility alias to
  `k1x-copy-live-system`, not as a separate older Armbian-derived tool.
- the package tarball now includes `install-u-boot-tools.sh` at the package
  root for a fresh install via `sudo ./install-u-boot-tools.sh`

## Cleanup/Debug Notes

Temporary helper scripts uploaded to `/home/armbian` during development were
removed.

Staged package tarballs and unpack directories in `/home/armbian` were also
removed.

Loopback cleanup was handled via a temporary helper; the current workspace still
contains the source file:
- `/Users/arvindsrinivasan/Code:Codex/cleanup-k1x-loopback.full.sh`

## Recommended Next-Session Starting Point

1. Re-read this file.
2. Inspect `/usr/local/lib/u-boot-tools/README.md` on `10.0.0.44`.
3. Verify installed wrapper set under `/usr/local/sbin`.
4. If needed, deploy the newly added `k1x-copy-live-system` script and wrapper.
5. If testing clone/install behavior, start with:
   - `sudo /usr/local/sbin/k1x-test-platform-install`
   - `sudo /usr/local/sbin/k1x-test-platform-install -bootblk`

## Note About Session Compaction

There is no direct user-facing tool in this environment to manually trigger
context compaction on demand. This file is the durable handoff document for a
fresh Codex session.
