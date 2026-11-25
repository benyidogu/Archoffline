# Archoffline

One Bash installer builds its own USB package repository (`prepare`) and installs
Arch Linux + XFCE without network access (`install`). The package list includes
`base`, `base-devel`, the Linux kernel and headers, firmware, bootloader,
filesystem tools, XFCE, display/audio/network drivers, common utilities, and all
dependencies resolved by pacman. It does not attempt to download every package
in Arch's repositories; that would be several terabytes and is not part of an
OS install.

## Prepare the USB bundle from Windows

1. Open **Actions → Build offline XFCE bundle → Run workflow**.
2. Wait for the run to succeed, then download `arch-xfce-offline-bundle` from
   **Artifacts**, or use the attached file on the **Releases** page.
3. Extract the downloaded ZIP, then extract `arch-xfce-offline-bundle.tar.gz`
   onto the Ventoy data partition. Keep the `.pkg.tar.zst` packages and
   `offline.db` together inside the `packages` directory.

The workflow downloads from Arch's official rolling mirror and resolves every
dependency against an empty target-system package database. The ISO is used to
boot the installer; the new system is installed from one internally consistent
package set downloaded during the workflow. The ISO's own package versions do
not need to match the newly installed system.

## Install completely offline

Boot the ISO in UEFI or BIOS/Legacy mode. Find the Ventoy data partition and
bundle directory, then run as root:

```bash
cd /path/to/arch-xfce-offline-bundle
bash offline-arch.sh install .
```

The installer verifies every bundle file and checks the package manifest before
asking for the target disk. It asks for bootloader, filesystem, swap size,
username/password, root password, hostname, timezone, locale, and keyboard.
It then displays a summary and requires typing `evet` before erasing the
selected disk. UEFI supports systemd-boot or GRUB; BIOS/Legacy uses GRUB.

The install reads package files only from the USB's local repository; it does
not use the network. The selected installation disk is completely erased.
Never select the Ventoy USB as the target.

## Building from an Arch Linux environment

For a machine that has Arch and network access, the same script can build the
bundle locally:

```bash
sudo ./offline-arch.sh prepare ./offline-bundle
```
