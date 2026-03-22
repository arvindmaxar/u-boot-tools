# K1X USB-First U-Boot Tools

This toolkit keeps `env_k1-x.txt` under your control without patching
package-managed files in `/usr/bin` or `/usr/lib`.

Installed locations:

- `/usr/local/lib/u-boot-tools/`
- `/usr/sbin/k1x-copy-live-system`
- `/usr/local/sbin/k1x-refresh-env`
- `/usr/local/sbin/k1x-test-platform-install`
- `/usr/local/sbin/k1x-nand-sata-install`
- `/etc/kernel/postinst.d/99-k1x-usb-first-env`

Fresh install from an extracted package:

```sh
cd k1x-u-boot-tools-package-20260321
sudo ./install-u-boot-tools.sh
```

## What it does

- Generates a USB-first `env_k1-x.txt`
- Prefers `usb0`, then `mmc2`, then `mmc0`, then `mmc1`
- Leaves raw boot block updates optional
- Refreshes `env_k1-x.txt` automatically after kernel package upgrades
- Treats `k1x-nand-sata-install` as a compatibility alias to the safer
  `k1x-copy-live-system` flow

## Safe commands

Refresh env files on the current root device and known boot targets:

```sh
sudo /usr/local/sbin/k1x-refresh-env
```

Copy the current live root filesystem to eMMC or another target, update the
target UUID in `extlinux.conf` and `fstab`, then refresh boot blocks and env:

```sh
sudo /usr/sbin/k1x-copy-live-system --force /dev/mmcblk2
```

The copy helper now creates a target boot-area backup under
`/var/tmp/k1x-copy-live-system-backups/` before making destructive changes.
By default it also creates the target root partition starting at sector
`32768` (16 MiB) so the raw boot blobs do not overlap the filesystem.

If you want to skip raw boot block writes and refresh only `env_k1-x.txt` on
the target after copying:

```sh
sudo /usr/sbin/k1x-copy-live-system --force --env-only /dev/mmcblk2
```

Legacy compatibility alias:

```sh
sudo /usr/local/sbin/k1x-nand-sata-install --force /dev/mmcblk2
```

That wrapper now forwards to `k1x-copy-live-system` and should be treated as an
alias, not as a separate implementation.

Run the safe loopback test:

```sh
sudo /usr/local/sbin/k1x-test-platform-install
```

Run the loopback test including raw boot blocks:

```sh
sudo /usr/local/sbin/k1x-test-platform-install -bootblk
```

Update eMMC env only:

```sh
sudo /usr/local/sbin/k1x-test-platform-install -emmc /dev/mmcblk2
```

Update eMMC env plus raw boot blocks:

```sh
sudo /usr/local/sbin/k1x-test-platform-install -emmc /dev/mmcblk2 -bootblk
```

Rollback the last eMMC test:

```sh
sudo /usr/local/sbin/k1x-test-platform-install -rollback /dev/mmcblk2
```

## Copy Script Flow

The main flow in `k1x-copy-live-system` is:

1. Parse options and require `--force`.
2. Validate the source root and target device.
3. Back up the target boot areas before destructive writes.
4. Repartition and format the target unless `--keep-partition-table` was used.
   The default new partition layout starts the root filesystem at sector
   `32768` (16 MiB) to reserve space for raw boot blocks.
5. Verify the reformatted target is `ext4`, mount it explicitly as `ext4`, and
   verify it has enough free space.
6. `rsync` the live source filesystem to the target.
7. Update the target root UUID in `extlinux.conf` and `fstab`.
8. Unmount the target and call the shared `platform_install.sh` helper to
   refresh `env_k1-x.txt`, and optionally write raw boot blocks too.

Major functions in the script:

- `assert_source_root_ready()`: checks that the source path is absolute,
  mounted, and contains `/boot/extlinux/extlinux.conf`.
- `assert_target_is_whole_device()` and `assert_safe_target()`: reject unsafe
  targets such as partitions, mounted devices, or the live source device.
- `backup_target_state()`: stores the first 8 MiB, `boot0` when present, and
  partition metadata under `/var/tmp/k1x-copy-live-system-backups/`.
- `prepare_target_partition()`: recreates or reuses the target partition and
  formats it as ext4, with a boot-area gap by default.
- `assert_partition_start_safe()`: refuses layouts where the root partition
  would overlap the raw boot-block region.
- `ensure_target_capacity()`: compares source used space with target free space
  before copying.
- `copy_live_system()`: runs the `rsync` copy with exclusions for pseudo-filesystems,
  transient directories, and the backup directory.
- `update_target_extlinux()` and `update_target_fstab()`: rewrite the target
  root UUID after the new filesystem UUID is known.
- `write_uboot_platform()` / `write_uboot_platform_with_bootblk()`: shared
  boot update helpers from `platform_install.sh`. On current-fit eMMC targets
  with `boot0`, these now keep `bootinfo_emmc.bin` and `FSBL.bin` on `boot0`
  only, so the GPT on the main user area is not overwritten.

## Upgrade behavior

`apt upgrade` may replace package-managed `/boot` artifacts, but it should not
touch `/env_k1-x.txt`. The post-install hook refreshes `env_k1-x.txt` after
kernel package upgrades so you should not need to rerun the env update manually
after normal upgrades.

Raw boot block writes are still manual. The post-install hook does not rewrite
FSBL, U-Boot, or other early boot blobs.
