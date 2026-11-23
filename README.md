# Archoffline

Arch ISO ile ağ kullanmadan **Arch Linux + XFCE** kurar.

## Önemli sınır

Windows tek başına Arch paketlerini güvenilir biçimde üretemez. `prepare` aşaması
internet erişimli bir **Arch ortamında** çalıştırılmalıdır. Windows üzerinde bunun
en pratik yolu WSL2 içine Arch Linux kurmak veya geçici bir Arch sanal makinesi
kullanmaktır. Hazırlanan klasörü Ventoy bölümüne kopyalayın.

## Hazırlama

Arch ortamında:

```bash
chmod +x offline-arch.sh
sudo ./offline-arch.sh prepare /mnt/ventoy/arch-offline
```

Bu işlem XFCE ve gerekli resmi paketleri USB'ye indirir.

## Offline kurulum

Arch ISO ile UEFI modunda açın ve USB'deki klasöre geçin:

```bash
chmod +x offline-arch.sh
./offline-arch.sh install /run/media/arch/VENTOY/arch-offline
```

Script ağı kapatır, diskleri listeler, açık bir silme onayı ister, diski
bölümlendirir ve paketleri yalnızca USB'deki yerel depodan kurar. Kurulum
sırasında hedef diskin tamamı silinir. Hyprland/Grit-Dots daha sonra ayrı
bir aşama olarak eklenebilir.
