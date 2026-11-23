#!/usr/bin/env bash
set -Eeuo pipefail

# Offline Arch Linux + XFCE installer.
# Run "prepare" on an internet-connected Arch environment and "install"
# from the prepared directory while booted from the Arch ISO.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MODE="${1:-}"
BUNDLE="${2:-$SCRIPT_DIR/offline-bundle}"
official_packages=(
  base linux linux-firmware sudo networkmanager
  grub efibootmgr dosfstools e2fsprogs
  xfce4 xfce4-goodies lightdm lightdm-gtk-greeter
  xfce4-pulseaudio-plugin network-manager-applet
  pipewire pipewire-audio pipewire-pulse pipewire-alsa wireplumber
  pavucontrol bluez bluez-utils blueman upower
  gvfs gvfs-mtp
  firefox xorg-server xorg-xinit
  noto-fonts noto-fonts-cjk noto-fonts-emoji ttf-jetbrains-mono-nerd fontconfig
)

die() { printf 'HATA: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "'$1' komutu bulunamadı."; }

usage() {
  cat <<'EOF'
Kullanım:
  ./offline-arch.sh prepare [çıktı-klasörü]
  ./offline-arch.sh install [paket-klasörü]

prepare: İnternetli Arch ortamında XFCE paketlerini USB için hazırlar.
install: Arch ISO'dan, ağ kullanmadan diske kurulum yapar.
EOF
}

prepare() {
  [[ $EUID -eq 0 ]] || die "prepare root olarak çalıştırılmalı."
  need_cmd pacman
  need_cmd repo-add

  local pkgdir="$BUNDLE/packages"
  mkdir -p "$pkgdir" "$BUNDLE"
  info "Paket veritabanı güncelleniyor."
  pacman -Sy --noconfirm

  info "Resmi paketler indiriliyor."
  pacman -Sw --noconfirm --cachedir "$pkgdir" "${official_packages[@]}"

  shopt -s nullglob
  local packages=("$pkgdir"/*.pkg.tar.zst)
  ((${#packages[@]} > 0)) || die "Hiç paket indirilemedi."
  repo-add "$pkgdir/offline.db.tar.gz" "${packages[@]}"
  shopt -u nullglob

  printf '%s\n' "${official_packages[@]}" > "$BUNDLE/package-manifest.txt"
  cat > "$BUNDLE/README.txt" <<EOF
Bu klasör Arch ISO ile offline kurulum içindir.
Kurulum sırasında ağ kullanılmaz.
Paket sayısı: ${#packages[@]}
EOF
  info "Hazırlandı: $BUNDLE"
}

select_disk() {
  mapfile -t disks < <(lsblk -dpno NAME,SIZE,MODEL,TYPE | awk '$4 == "disk"')
  ((${#disks[@]} > 0)) || die "Kurulabilir disk bulunamadı."
  printf '%s\n' "Bulunan diskler:" >&2
  printf '  %s\n' "${disks[@]}" >&2
  printf '\n' >&2
  read -r -p "Hedef diski tam yoluyla yazın (ör. /dev/nvme0n1): " disk >&2
  printf '%s\n' "${disks[@]}" | grep -q "^${disk} " || die "Disk listede yok: $disk"
  read -r -p "$disk tamamen silinecek. Devam etmek için DISKİ-SİL yazın: " confirm >&2
  [[ "$confirm" == "DISKİ-SİL" ]] || die "Onay alınmadı."
  printf '%s\n' "$disk"
}

install() {
  [[ $EUID -eq 0 ]] || die "install root olarak çalıştırılmalı."
  [[ -d "$BUNDLE/packages" ]] || die "Paket klasörü bulunamadı: $BUNDLE/packages"
  [[ -f "$BUNDLE/packages/offline.db.tar.gz" ]] || die "offline.db.tar.gz bulunamadı."
  [[ -d /sys/firmware/efi ]] || die "Bu sürüm yalnızca UEFI modunu destekliyor."

  local disk
  disk="$(select_disk)"
  local esp="${disk}1" root="${disk}2"
  [[ "$disk" == *nvme* || "$disk" == *mmcblk* ]] && esp="${disk}p1" && root="${disk}p2"

  info "Kurulum ortamında ağ bağlantısı kapatılıyor."
  command -v rfkill >/dev/null 2>&1 && rfkill block all || true
  command -v systemctl >/dev/null 2>&1 && systemctl stop NetworkManager 2>/dev/null || true

  info "Disk bölümlendiriliyor."
  umount -R /mnt 2>/dev/null || true
  sgdisk --zap-all "$disk"
  sgdisk -n 1:0:+1G -t 1:ef00 -n 2:0:0 -t 2:8300 "$disk"
  partprobe "$disk"
  mkfs.fat -F32 "$esp"
  mkfs.ext4 -F "$root"
  mount "$root" /mnt
  mkdir -p /mnt/boot
  mount "$esp" /mnt/boot

  local pacman_conf=/tmp/offline-pacman.conf
  cat > "$pacman_conf" <<EOF
[options]
Architecture = auto
SigLevel = Never
LocalFileSigLevel = Never
[offline]
SigLevel = Never
Server = file://$BUNDLE/packages
EOF

  info "Temel sistem ve XFCE kuruluyor."
  pacstrap -C "$pacman_conf" -M /mnt "${official_packages[@]}"
  genfstab -U /mnt >> /mnt/etc/fstab

  local username hostname timezone
  read -r -p "Kullanıcı adı [arch]: " username
  username="${username:-arch}"
  [[ "$username" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Geçersiz kullanıcı adı."
  read -r -p "Bilgisayar adı [archbox]: " hostname
  hostname="${hostname:-archbox}"
  read -r -p "Saat dilimi [Europe/Istanbul]: " timezone
  timezone="${timezone:-Europe/Istanbul}"
  read -r -s -p "Kullanıcı parolası: " user_password; printf '\n'
  read -r -s -p "root parolası: " root_password; printf '\n'

  info "Sistem yapılandırılıyor."
  arch-chroot /mnt /bin/bash -s -- "$username" "$hostname" "$timezone" "$user_password" "$root_password" <<'CHROOT'
set -Eeuo pipefail
username="$1"; hostname="$2"; timezone="$3"; user_password="$4"; root_password="$5"
ln -sf "/usr/share/zoneinfo/$timezone" /etc/localtime
hwclock --systohc
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
sed -i 's/^#tr_TR.UTF-8 UTF-8/tr_TR.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
printf 'LANG=tr_TR.UTF-8\n' > /etc/locale.conf
printf '%s\n' "$hostname" > /etc/hostname
printf '127.0.0.1 localhost\n::1 localhost\n127.0.1.1 %s.localdomain %s\n' "$hostname" "$hostname" > /etc/hosts
printf 'root:%s\n' "$root_password" | chpasswd
useradd -m -G wheel,audio,video,storage,input "$username"
printf '%s:%s\n' "$username" "$user_password" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
systemctl enable NetworkManager bluetooth lightdm
bootctl install
cat > /boot/loader/loader.conf <<EOF
default arch.conf
timeout 3
editor no
EOF
ROOT_UUID="$(blkid -s UUID -o value "$root")"
cat > /boot/loader/entries/arch.conf <<EOF
title Arch Linux
linux /vmlinuz-linux
initrd /initramfs-linux.img
options root=UUID=$ROOT_UUID rw
EOF
CHROOT

  rm -f "$pacman_conf"
  umount -R /mnt
  info "Kurulum tamamlandı. USB'yi çıkarıp yeniden başlatın."
}

case "$MODE" in
  prepare) prepare ;;
  install) install ;;
  *) usage; exit 2 ;;
esac
