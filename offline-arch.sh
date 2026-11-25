#!/usr/bin/env bash
set -Eeuo pipefail

# Build a complete local package repository, then install Arch without network.
# The bundle must be built from the same Arch Linux Archive snapshot as the ISO.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MODE="${1:-}"
BUNDLE="${2:-$SCRIPT_DIR/offline-bundle}"
ARCHIVE_DATE="${ARCHIVE_DATE:-2026/11/01}"

packages=(
  base base-devel archlinux-keyring linux linux-headers linux-firmware amd-ucode intel-ucode
  sudo networkmanager network-manager-applet iwd
  grub efibootmgr gdisk dosfstools exfatprogs ntfs-3g btrfs-progs xfsprogs
  f2fs-tools lvm2 cryptsetup mdadm
  xfce4 xfce4-goodies lightdm lightdm-gtk-greeter
  xorg-server xf86-input-libinput mesa vulkan-icd-loader vulkan-intel
  vulkan-radeon xf86-video-amdgpu xf86-video-intel
  pipewire pipewire-audio pipewire-pulse pipewire-alsa wireplumber pavucontrol
  bluez bluez-utils blueman
  gvfs gvfs-mtp thunar-archive-plugin file-roller firefox
  noto-fonts noto-fonts-cjk noto-fonts-emoji ttf-jetbrains-mono-nerd
  nano vim git curl wget openssh rsync htop fastfetch man-db man-pages
  bash-completion unzip zip 7zip
)

die() { printf 'HATA: %s\n' "$*" >&2; exit 1; }
info() { printf '\n==> %s\n' "$*"; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "'$1' komutu bulunamadı."; }

usage() {
  cat <<'EOF'
Kullanım:
  sudo ./offline-arch.sh prepare [bundle-klasörü]
  ./offline-arch.sh install [bundle-klasörü]

prepare: Arch Linux Archive'dan tüm hedef paketleri ve bağımlılıklarını indirir.
install: Yerel USB paket deposunu kullanarak internetsiz Arch + XFCE kurar.
EOF
}

make_pacman_config() {
  local destination="$1" repo_dir="$2"
  cat > "$destination" <<EOF
[options]
Architecture = auto
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional

[offline]
SigLevel = Required DatabaseOptional
Server = file://$repo_dir
EOF
}

prepare() {
  [[ $EUID -eq 0 ]] || die "prepare root olarak çalıştırılmalı."
  need_cmd pacman
  need_cmd repo-add

  mkdir -p "$BUNDLE"
  BUNDLE="$(cd "$BUNDLE" && pwd)"
  local pkgdir="$BUNDLE/packages"
  local config=/tmp/archoffline-pacman.conf
  local date_path="${ARCHIVE_DATE//-//}"
  local builddb verifydb
  builddb="$(mktemp -d /tmp/archoffline-build-db.XXXXXX)"
  verifydb="$(mktemp -d /tmp/archoffline-verify-db.XXXXXX)"
  mkdir -p "$pkgdir"
  mkdir -p "$builddb/local" "$verifydb/local"
  find "$pkgdir" -maxdepth 1 -type f \( \
    -name '*.pkg.tar.zst' -o -name '*.pkg.tar.zst.sig' -o -name 'offline.db*' \
  \) -delete
  cat > "$config" <<EOF
[options]
Architecture = auto
SigLevel = Required DatabaseOptional

[core]
Server = https://archive.archlinux.org/repos/$date_path/core/os/\$arch

[extra]
Server = https://archive.archlinux.org/repos/$date_path/extra/os/\$arch
EOF

  info "Arch snapshot: $date_path"
  pacman -Syy --dbpath "$builddb" --config "$config" --noconfirm
  info "Temel sistem, base-devel, kernel, XFCE ve tüm bağımlılıklar indiriliyor."
  pacman -Sw --dbpath "$builddb" --config "$config" --noconfirm \
    --cachedir "$pkgdir" "${packages[@]}"

  shopt -s nullglob
  local archives=("$pkgdir"/*.pkg.tar.zst)
  ((${#archives[@]} > 0)) || die "Paket indirme boş sonuç verdi."
  local archive
  for archive in "${archives[@]}"; do
    local safe="${archive//:/_}"
    if [[ "$archive" != "$safe" ]]; then
      [[ ! -f "$archive.sig" ]] || mv -- "$archive.sig" "${safe}.sig"
      mv -- "$archive" "$safe"
    fi
    [[ -f "$safe.sig" ]] || die "Paket im Bundle hat keine Signatur: $safe"
  done
  archives=("$pkgdir"/*.pkg.tar.zst)
  shopt -u nullglob

  rm -f "$pkgdir"/offline.db*
  repo-add "$pkgdir/offline.db.tar.gz" "${archives[@]}"
  if [[ -L "$pkgdir/offline.db" ]]; then
    cp -L "$pkgdir/offline.db" "$pkgdir/offline.db.materialized"
    mv "$pkgdir/offline.db.materialized" "$pkgdir/offline.db"
  fi
  printf '%s\n' "${packages[@]}" > "$BUNDLE/package-manifest.txt"
  printf '%s\n' "$date_path" > "$BUNDLE/arch-snapshot.txt"
  (
    cd "$BUNDLE"
    cp "$SCRIPT_DIR/offline-arch.sh" .
    cp "$SCRIPT_DIR/README.md" .
    cat > README.txt <<EOF
Offline Arch Linux + XFCE bundle
Arch snapshot: $date_path
Includes base, base-devel, Linux kernel/headers, firmware, GRUB, XFCE,
common filesystems, networking, audio, graphics drivers, fonts and utilities.
All direct package dependencies were resolved from the local repository.
Verify files with: sha256sum -c SHA256SUMS
EOF
    sha256sum package-manifest.txt arch-snapshot.txt packages/* > SHA256SUMS
    sha256sum offline-arch.sh README.md README.txt >> SHA256SUMS
  )

  local local_config=/tmp/archoffline-verify.conf
  make_pacman_config "$local_config" "$pkgdir"
  pacman -Sy --dbpath "$verifydb" --config "$local_config" --noconfirm
  pacman -Sp --dbpath "$verifydb" --config "$local_config" --noconfirm \
    "${packages[@]}" >/dev/null

  rm -f "$config" "$local_config"
  rm -rf -- "$builddb" "$verifydb"
  info "Hazır: $BUNDLE"
  info "Paket arşivi sayısı: ${#archives[@]}"
}

ask_default() {
  local prompt="$1" default="$2" answer
  read -r -p "$prompt [$default]: " answer
  printf '%s' "${answer:-$default}"
}

ask_password() {
  local label="$1" first second
  while true; do
    read -r -s -p "$label: " first; printf '\n'
    read -r -s -p "$label (tekrar): " second; printf '\n'
    [[ -n "$first" ]] || { printf 'Parola boş olamaz.\n' >&2; continue; }
    [[ "$first" == "$second" ]] || { printf 'Parolalar eşleşmedi.\n' >&2; continue; }
    [[ "$first" != *$'\n'* && "$first" != *:* ]] || {
      printf 'Parola iki nokta veya satır sonu içeremez.\n' >&2
      continue
    }
    printf '%s' "$first"
    return
  done
}

select_disk() {
  local disks disk mountpoint
  disks="$(lsblk -dpno NAME,SIZE,MODEL,TYPE | awk '$4 == "disk"')"
  [[ -n "$disks" ]] || die "Kurulabilir disk bulunamadı."
  printf 'Diskler (seçilen diskin tamamı silinecek):\n%s\n' "$disks" >&2
  read -r -p "Hedef diskin tam yolunu yazın: " disk
  [[ "$(lsblk -dnro TYPE "$disk" 2>/dev/null)" == "disk" ]] || die "Geçersiz disk: $disk"
  while IFS= read -r mountpoint; do
    [[ -z "$mountpoint" ]] || die "$disk üzerinde bağlı dosya sistemi var ($mountpoint); önce güvenle ayırın."
  done < <(lsblk -nrpo MOUNTPOINT "$disk")
  read -r -p "$disk tamamen silinecek. Onay için disk yolunu tekrar yazın: " confirm
  [[ "$confirm" == "$disk" ]] || die "Disk onayı eşleşmedi."
  printf '%s' "$disk"
}

install() {
  [[ $EUID -eq 0 ]] || die "install root olarak çalıştırılmalı."
  BUNDLE="$(cd "$BUNDLE" && pwd)"
  local pkgdir="$BUNDLE/packages"
  [[ -f "$pkgdir/offline.db" || -f "$pkgdir/offline.db.tar.gz" ]] || die "USB yerel paket veritabanı bulunamadı."
  [[ -f "$BUNDLE/SHA256SUMS" ]] || die "SHA256SUMS yok; bundle eksik veya eski."
  need_cmd pacstrap
  need_cmd arch-chroot
  need_cmd sgdisk

  info "USB bundle bütünlüğü doğrulanıyor."
  (cd "$BUNDLE" && sha256sum -c SHA256SUMS) || die "Bundle checksum doğrulaması başarısız."
  diff -u <(printf '%s\n' "${packages[@]}") "$BUNDLE/package-manifest.txt" ||
    die "Bundle paket manifesti bu installer sürümüyle eşleşmiyor."

  local disk firmware bootloader filesystem swap_size username hostname timezone locale keymap
  disk="$(select_disk)"
  if [[ -d /sys/firmware/efi ]]; then
    firmware=uefi
    bootloader="$(ask_default 'Bootloader: 1) systemd-boot  2) GRUB' '1')"
    [[ "$bootloader" == 1 || "$bootloader" == 2 ]] || die "Bootloader seçimi 1 veya 2 olmalı."
  else
    firmware=bios
    bootloader=2
    info "BIOS/Legacy mod algılandı; GRUB kullanılacak."
  fi

  filesystem="$(ask_default 'Dosya sistemi: 1) ext4  2) Btrfs' '1')"
  [[ "$filesystem" == 1 || "$filesystem" == 2 ]] || die "Dosya sistemi seçimi 1 veya 2 olmalı."
  swap_size="$(ask_default 'Swap dosyası boyutu (GB; 0=kapalı)' '4')"
  [[ "$swap_size" =~ ^[0-9]+$ ]] && ((swap_size <= 128)) ||
    die "Swap boyutu 0 ile 128 GB arasında tam sayı olmalı."
  username="$(ask_default 'Yeni kullanıcı adı' 'arch')"
  [[ "$username" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Geçersiz kullanıcı adı."
  ((${#username} <= 32)) || die "Kullanıcı adı en fazla 32 karakter olabilir."
  [[ "$username" != root ]] || die "root ayrıcalıklı kullanıcı adı olamaz."
  hostname="$(ask_default 'Bilgisayar adı' 'archlinux')"
  [[ "$hostname" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ ]] || die "Geçersiz hostname."
  timezone="$(ask_default 'Saat dilimi' 'Europe/Istanbul')"
  [[ "$timezone" != /* && "$timezone" != *..* ]] || die "Geçersiz saat dilimi."
  [[ -f "/usr/share/zoneinfo/$timezone" ]] || die "Saat dilimi bulunamadı: $timezone"
  locale="$(ask_default 'Sistem dili (tr_TR.UTF-8 veya en_US.UTF-8)' 'tr_TR.UTF-8')"
  [[ "$locale" == tr_TR.UTF-8 || "$locale" == en_US.UTF-8 ]] || die "Desteklenen diller: tr_TR.UTF-8, en_US.UTF-8."
  keymap="$(ask_default 'Konsol klavyesi (trq veya us)' 'trq')"
  [[ "$keymap" == trq || "$keymap" == us ]] || die "Desteklenen klavyeler: trq, us."
  local user_password root_password
  user_password="$(ask_password 'Kullanıcı parolası')"
  root_password="$(ask_password 'Root parolası')"

  info "Kurulum özeti:"
  printf 'Disk: %s | Firmware: %s | Bootloader: %s | Dosya sistemi: %s\n' \
    "$disk" "$firmware" "$bootloader" "$filesystem"
  printf 'Kullanıcı: %s | Hostname: %s | Saat dilimi: %s | Dil: %s | Swap: %s GB\n' \
    "$username" "$hostname" "$timezone" "$locale" "$swap_size"
  read -r -p "Kuruluma başlayıp seçilen diski biçimlendireyim mi? [evet/HAYIR]: " confirm
  [[ "$confirm" == evet ]] || die "Kullanıcı kurulumu iptal etti."

  info "Ağ servisleri durduruluyor; kurulum USB deposu dışına çıkmayacak."
  systemctl stop NetworkManager iwd wpa_supplicant 2>/dev/null || true
  local p1 p2
  if [[ "$disk" == *nvme* || "$disk" == *mmcblk* ]]; then
    p1="${disk}p1"; p2="${disk}p2"
  else
    p1="${disk}1"; p2="${disk}2"
  fi
  sgdisk --zap-all "$disk"
  if [[ "$firmware" == uefi ]]; then
    sgdisk -n 1:0:+1G -t 1:ef00 -c 1:EFI "$disk"
  else
    sgdisk -n 1:0:+2M -t 1:ef02 -c 1:BIOS-BOOT "$disk"
  fi
  sgdisk -n 2:0:0 -t 2:8300 -c 2:ARCH-ROOT "$disk"
  if command -v partprobe >/dev/null 2>&1; then
    partprobe "$disk"
  else
    blockdev --rereadpt "$disk"
  fi
  udevadm settle

  if [[ "$firmware" == uefi ]]; then
    mkfs.fat -F32 "$p1"
  fi
  if [[ "$filesystem" == 1 ]]; then
    mkfs.ext4 -F "$p2"
    mount "$p2" /mnt
  else
    mkfs.btrfs -f "$p2"
    mount "$p2" /mnt
    btrfs subvolume create /mnt/@
    btrfs subvolume create /mnt/@home
    btrfs subvolume set-default "$(btrfs subvolume show /mnt/@ | awk '/Subvolume ID:/ {print $3}')" /mnt
    umount /mnt
    mount -o noatime,compress=zstd,subvol=@ "$p2" /mnt
    mkdir -p /mnt/home
    mount -o noatime,compress=zstd,subvol=@home "$p2" /mnt/home
  fi
  if [[ "$firmware" == uefi ]]; then
    mkdir -p /mnt/boot
    mount "$p1" /mnt/boot
  fi

  local pacman_conf=/tmp/archoffline-install.conf
  make_pacman_config "$pacman_conf" "$pkgdir"
  pacman -Sy --config "$pacman_conf" --noconfirm
  info "Paketler yerel USB deposundan kuruluyor."
  pacstrap -C "$pacman_conf" -M /mnt "${packages[@]}"
  genfstab -U /mnt >> /mnt/etc/fstab

  if ((swap_size > 0)); then
    if [[ "$filesystem" == 2 ]]; then
      chattr +C /mnt
    fi
    truncate -s 0 /mnt/swapfile
    if [[ "$filesystem" == 2 ]]; then
      chattr +C /mnt/swapfile
    fi
    fallocate -l "${swap_size}G" /mnt/swapfile
    chmod 600 /mnt/swapfile
    mkswap /mnt/swapfile
    printf '/swapfile none swap defaults 0 0\n' >> /mnt/etc/fstab
  fi

  local root_uuid
  root_uuid="$(blkid -s UUID -o value "$p2")"
  {
    printf 'USERNAME=%q\n' "$username"
    printf 'HOSTNAME=%q\n' "$hostname"
    printf 'TIMEZONE=%q\n' "$timezone"
    printf 'LOCALE=%q\n' "$locale"
    printf 'KEYMAP=%q\n' "$keymap"
    printf 'BOOTLOADER=%q\n' "$bootloader"
    printf 'FIRMWARE=%q\n' "$firmware"
    printf 'FILESYSTEM=%q\n' "$filesystem"
    printf 'ROOT_UUID=%q\n' "$root_uuid"
    printf 'USER_PASSWORD=%q\n' "$user_password"
    printf 'ROOT_PASSWORD=%q\n' "$root_password"
  } > /mnt/root/.offline-install-settings
  chmod 600 /mnt/root/.offline-install-settings
  printf 'INSTALL_DISK=%q\n' "$disk" >> /mnt/root/.offline-install-settings
  trap 'rm -f /mnt/root/.offline-install-settings /tmp/archoffline-install.conf; unset user_password root_password 2>/dev/null || true' EXIT
  unset user_password root_password

  info "Sistem, kullanıcı, locale ve bootloader yapılandırılıyor."
  arch-chroot /mnt /bin/bash -s <<'CHROOT'
set -Eeuo pipefail
source /root/.offline-install-settings
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc
sed -i "s/^#${LOCALE} UTF-8/${LOCALE} UTF-8/" /etc/locale.gen
locale-gen
printf 'LANG=%s\n' "$LOCALE" > /etc/locale.conf
printf 'KEYMAP=%s\n' "$KEYMAP" > /etc/vconsole.conf
printf '%s\n' "$HOSTNAME" > /etc/hostname
printf '127.0.0.1 localhost\n::1 localhost\n127.0.1.1 %s.localdomain %s\n' "$HOSTNAME" "$HOSTNAME" > /etc/hosts
printf 'root:%s\n' "$ROOT_PASSWORD" | chpasswd
useradd -m -G wheel,audio,video,storage,optical,input "$USERNAME"
printf '%s:%s\n' "$USERNAME" "$USER_PASSWORD" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
visudo -c
mkdir -p /etc/X11/xorg.conf.d
if [[ "$KEYMAP" == trq ]]; then
  printf 'Section "InputClass"\n    Identifier "system-keyboard"\n    MatchIsKeyboard "on"\n    Option "XkbLayout" "tr"\nEndSection\n' > /etc/X11/xorg.conf.d/00-keyboard.conf
else
  printf 'Section "InputClass"\n    Identifier "system-keyboard"\n    MatchIsKeyboard "on"\n    Option "XkbLayout" "us"\nEndSection\n' > /etc/X11/xorg.conf.d/00-keyboard.conf
fi
systemctl enable NetworkManager bluetooth lightdm
mkinitcpio -P
if [[ "$FIRMWARE" == uefi && "$BOOTLOADER" == 1 ]]; then
  bootctl --esp-path=/boot install
  cat > /boot/loader/loader.conf <<EOF
default arch.conf
timeout 3
editor no
EOF
  cat > /boot/loader/entries/arch.conf <<EOF
title Arch Linux
linux /vmlinuz-linux
initrd /initramfs-linux.img
options root=UUID=$ROOT_UUID rw
EOF
elif [[ "$FIRMWARE" == uefi ]]; then
  grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Arch --recheck
  grub-mkconfig -o /boot/grub/grub.cfg
else
  grub-install --target=i386-pc "$INSTALL_DISK"
  grub-mkconfig -o /boot/grub/grub.cfg
fi
rm -f /root/.offline-install-settings
CHROOT

  rm -f "$pacman_conf"
  unset user_password root_password
  umount -R /mnt
  trap - EXIT
  info "Arch Linux + XFCE kurulumu tamamlandı. USB'yi çıkarıp yeniden başlatın."
}

case "$MODE" in
  prepare) prepare ;;
  install) install ;;
  *) usage; exit 2 ;;
esac
