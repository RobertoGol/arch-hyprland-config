#!/bin/bash

# =====================================================================
# ALL-IN-ONE: Установка Arch Linux + Hyprland + VMware Tools + dotfiles
# =====================================================================
# ВАЖНО:
# - Скрипт автоматически ОЧИЩАЕТ и размечает /dev/sda (EFI + SWAP + ROOT).
# - Запускать только в Live-среде Arch (после загрузки с официального ISO).
# - Перед запуском вручную выполнить ТОЛЬКО установку git:
#       pacman -Sy git --noconfirm
# - Затем:
#       git clone https://github.com/RobertoGol/arch-hyprland-config.git
#       cd arch-hyprland-config
#       chmod +x all_in_one_install.sh
#       ./all_in_one_install.sh
# =====================================================================

set -e

# ---------------------- 1. Проверки окружения ------------------------

if [[ $EUID -ne 0 ]]; then
    echo "Этот скрипт должен быть запущен от root."
    exit 1
fi

REPO_SRC="$(pwd)"

# ---------------------- 2. Предупреждение и ввод данных -------------

echo "================================================"
echo "      !!! КРИТИЧЕСКОЕ: АВТОМАТИЧЕСКАЯ ОЧИСТКА ДИСКА !!!"
echo "Этот скрипт сейчас начнет форматировать /dev/sda."
echo "У вас есть 10 секунд, чтобы отменить операцию (Ctrl+C)."
echo "================================================"

sleep 10

# Внутренняя сигнатура (RJ powered), не выводится пользователю во время работы
RJ_SIGNATURE="RJ powered"

# Предопределённые учётные записи (для удобства в тестовой ВМ)
USER_NAME="Archlinux"
USER_PASS="Archlinux"
ROOT_PASS="root"

echo "Будет создан обычный пользователь:  $USER_NAME / $USER_PASS"
echo "Root-пользователь:                 root / $ROOT_PASS"
echo "Рекомендуется сменить эти пароли после установки."

HOST_NAME="arch-hypr-rj"
echo "Имя хоста по умолчанию:           $HOST_NAME"

echo "Доступные диски:"
lsblk -d -o NAME,SIZE,MODEL

DEFAULT_DISK="/dev/sda"
read -rp "Введите устройство диска для установки [${DEFAULT_DISK}]: " USER_DISK
DISK="${USER_DISK:-$DEFAULT_DISK}"

if [[ ! -b "$DISK" ]]; then
    echo "Ошибка: устройство $DISK не найдено."
    exit 1
fi

EFI_PART="${DISK}1"
SWAP_PART="${DISK}2"
ROOT_PART="${DISK}3"

# Определяем виртуализацию (важно для VMware: у Live-ISO очень маленький overlay)
VIRT_TYPE="$(systemd-detect-virt 2>/dev/null || echo "unknown")"
PACMAN_CACHE_REDIR=0

# ---------------------- 3. Настройка зеркал --------------------------

MIRROR_LIST=(
    'https://mirror.yandex.ru/archlinux/$repo/os/$arch'
    'https://geo.mirror.pkgbuild.com/$repo/os/$arch'
    'https://arch.mirror.constant.com/$repo/os/$arch'
)

function set_preferred_mirrors {
    echo "Настройка списка зеркал для ускоренной загрузки..."

    # Очищаем старый mirrorlist и создаем новый
    > /etc/pacman.d/mirrorlist
    
    for MIRROR_URL in "${MIRROR_LIST[@]}"; do
        echo "Server = ${MIRROR_URL}" >> /etc/pacman.d/mirrorlist
    done

    pacman-key --init
    pacman-key --populate archlinux

    echo "Зеркала успешно установлены и синхронизированы."
}

# ---------------------- 4. Разметка и форматирование -----------------

echo "Запуск автоматической разметки диска \$DISK..."
sfdisk --delete "\$DISK" || true
echo "label: gpt
size=512MiB, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name=EFI
size=2GiB, type=0657FD6D-A4E3-40A1-8C5C-9A5C0C2D8B9A, name=SWAP
type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=ROOT" | sfdisk "\$DISK"

sleep 2

echo "Форматирование разделов..."
mkfs.fat -F 32 "\$EFI_PART"
mkswap "\$SWAP_PART"
mkfs.ext4 "\$ROOT_PART"

# ---------------------- 5. Монтирование и базовая система -----------

echo "Монтирование разделов и активация SWAP..."
mount "\$ROOT_PART" /mnt
mkdir -p /mnt/boot
mount "\$EFI_PART" /mnt/boot
swapon "\$SWAP_PART"

if [[ "$VIRT_TYPE" == "vmware" ]]; then
    echo "Обнаружена виртуализация VMware. Перенаправляем кэши pacman на целевой диск..."
    mkdir -p /var/cache/pacman/pkg
    mkdir -p /mnt/var/cache/pacman/pkg
    mount --bind /mnt/var/cache/pacman/pkg /var/cache/pacman/pkg
    PACMAN_CACHE_REDIR=1
fi

set_preferred_mirrors

echo "Установка базовых пакетов..."
pacstrap /mnt base linux linux-firmware nano git arch-install-scripts sudo

echo "Генерация fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

echo "Копирование репозитория в новую систему..."
cp -r "\$REPO_SRC" /mnt/arch-hyprland-config

# ---------------------- 6. Конфигурация в chroot ---------------------

echo "Переход в CHROOT для настройки..."
arch-chroot /mnt /bin/bash <<EOF

# 6.1. Установка рабочего зеркала в CHROOT
MIRROR_LIST=(
    'https://mirror.yandex.ru/archlinux/$repo/os/$arch'
    'https://geo.mirror.pkgbuild.com/$repo/os/$arch'
    'https://arch.mirror.constant.com/$repo/os/$arch'
)
$(declare -f set_preferred_mirrors)
set_preferred_mirrors

# 6.2. Установка ядра и Initramfs
pacman -Syu --noconfirm
pacman -S linux linux-firmware --overwrite "*" --noconfirm

echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=us" > /etc/vconsole.conf

mkinitcpio -P

# 6.3. Локаль и Время
echo "$HOST_NAME" > /etc/hostname
ln -sf /usr/share/zoneinfo/Asia/Omsk /etc/localtime
hwclock --systohc

sed -i 's/^#\(en_US.UTF-8 UTF-8\)$/\1/' /etc/locale.gen
sed -i 's/^#\(ru_RU.UTF-8 UTF-8\)$/\1/' /etc/locale.gen
locale-gen

# 6.3.1. Установка шрифтов для русского и английского языков (ранняя установка)
echo "Установка шрифтов для корректного отображения русского и английского текста..."
pacman -S noto-fonts noto-fonts-cjk noto-fonts-emoji ttf-fira-code ttf-jetbrains-mono --noconfirm

# 6.4. Настройка GRUB 
pacman -S grub efibootmgr --noconfirm
rm -rf /boot/grub/*
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Arch
grub-mkconfig -o /boot/grub/grub.cfg

# 6.5. Оптимизация pacman для ускорения установки
echo "Оптимизация pacman..."
sed -i 's/^#ParallelDownloads = 5/ParallelDownloads = 10/' /etc/pacman.conf
sed -i 's/^#Color/Color/' /etc/pacman.conf

# 6.6. Установка Hyprland, приложений, fastfetch и инструментов VMware
echo "Установка Hyprland, приложений, fastfetch и инструментов VMware..."
pacman -S hyprland wayland-protocols xdg-desktop-portal-hyprland polkit-gnome \
         waybar wofi kitty networkmanager network-manager-applet \
         feh htop acpi fastfetch hyprpaper brightnessctl grim slurp wl-clipboard \
         thunar thunar-archive-plugin file-roller \
         pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber \
         alsa-utils pulseaudio-alsa \
         open-vm-tools xf86-video-vmware --noconfirm

# Маскировка reflector.service для предотвращения зависания
systemctl mask reflector.service

systemctl enable NetworkManager
systemctl enable vmtoolsd

# 6.7. Пользователи и Пароли
echo "Настройка пароля root..."
echo "root:$ROOT_PASS" | chpasswd

echo "Создание пользователя $USER_NAME..."
useradd -m -g users -G wheel,audio,video,storage -s /bin/bash "$USER_NAME"
echo "$USER_NAME:$USER_PASS" | chpasswd

sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# 6.7.1. Установка yay и Firefox Developer Edition через AUR
echo "Установка yay для AUR пакетов..."
pacman -S --needed base-devel git --noconfirm

# Устанавливаем yay от имени пользователя
sudo -u "$USER_NAME" bash -c "cd /tmp && git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si --noconfirm" || echo "Yay installation skipped, Firefox Developer Edition will be installed manually later"

# 6.8. Оптимизация системы для производительности
echo "Настройка оптимизаций системы..."

# Оптимизация swappiness для лучшей производительности
cat > /etc/sysctl.d/99-rj-optimizations.conf <<'SYSCTL'
vm.swappiness=10
vm.vfs_cache_pressure=50
vm.dirty_ratio=15
vm.dirty_background_ratio=5
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
SYSCTL

# Оптимизация I/O scheduler (для SSD/NVMe)
cat > /etc/udev/rules.d/60-ioschedulers.rules << 'IOEOF'
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="none"
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/scheduler}="none"
IOEOF

# Настройка лимитов для пользователя
cat > /etc/security/limits.d/99-rj-limits.conf << 'LIMITEOF'
* soft nofile 65536
* hard nofile 65536
* soft nproc 32768
* hard nproc 32768
LIMITEOF

# 6.9. Копирование пользовательских конфигов (dotfiles)
CONFIG_SRC="/arch-hyprland-config/config"
USER_HOME="/home/$USER_NAME"
USER_CONFIG="\$USER_HOME/.config"

if [ -d "\$CONFIG_SRC" ]; then
    echo "Копирование конфигов из \$CONFIG_SRC в \$USER_CONFIG ..."
    mkdir -p "\$USER_CONFIG"
    cp -r "\$CONFIG_SRC/"* "\$USER_CONFIG/" 2>/dev/null || true
    
    # Создаём placeholder для обоев, если его нет
    if [ ! -f "\$USER_CONFIG/hypr/wallpaper.png" ]; then
        echo "Создание placeholder для обоев..."
        mkdir -p "\$USER_CONFIG/hypr"
        # Создаём простой градиентный фон через ImageMagick (если установлен) или оставляем пустым
        # Пользователь может заменить wallpaper.png на свой
    fi
    
    echo "Конфиги успешно скопированы."
else
    echo "Папка \$CONFIG_SRC не найдена. Пропускаю копирование конфигов."
    echo "Вы сможете скопировать их вручную после загрузки."
fi

# 6.9.1. Установка Firefox Developer Edition через yay (если yay установлен)
if command -v yay >/dev/null 2>&1; then
    echo "Установка Firefox Developer Edition через yay..."
    sudo -u "$USER_NAME" yay -S firefox-developer-edition firefox-developer-edition-i18n-ru --noconfirm || echo "Firefox Developer Edition installation failed, install manually: yay -S firefox-developer-edition firefox-developer-edition-i18n-ru"
    
    # Установка дополнительных модулей и утилит для Firefox
    echo "Установка дополнительных модулей для Firefox..."
    pacman -S --needed firejail firejail-profiles \
         xdg-desktop-portal-wlr xdg-desktop-portal-gtk \
         libva-mesa-driver mesa-vdpau intel-media-driver \
         --noconfirm || echo "Some Firefox modules installation skipped"
else
    echo "Yay не установлен. Firefox Developer Edition можно установить вручную после загрузки:"
    echo "  yay -S firefox-developer-edition firefox-developer-edition-i18n-ru"
fi

# 6.10. Автозапуск fastfetch и ASCII-баннера при входе пользователя
PROFILE_FILE="\$USER_HOME/.bash_profile"

echo "Настройка авто-запуска fastfetch и баннера RJ powered..."
cat << 'EOPROFILE' >> "\$PROFILE_FILE"

if command -v fastfetch >/dev/null 2>&1; then
  fastfetch
fi

cat << 'RJ'
  ______   __        ____                               _ 
 |  __  \ |  |      |  _ \                             | |
 | |__) | | |______ | |_) |  ___   _ __   _   _   __ _ | |
 |  _  /  | |______||  _ <  / _ \ | '_ \ | | | | / _` || |
 | | \ \  | |       | |_) || (_) || | | || |_| || (_| ||_|
 |_|  \_\ |_|       |____/  \___/ |_| |_| \__,_| \__, |(_)
                                                   __/ |   
                                                  |___/    

                     RJ powered
RJ

EOPROFILE

# Права на домашний каталог и профиль пользователя
chown -R "$USER_NAME:users" "\$USER_HOME"

echo "Конфигурация CHROOT завершена."

EOF

# ---------------------- 7. Финализация и перезагрузка ----------------

echo "================================================"
echo "Установка завершена. Перезагрузка."
echo "Не забудьте настроить порядок загрузки в настройках VMware,"
echo "чтобы загрузиться с диска, а не с ISO!"
echo "================================================"

if [[ "$PACMAN_CACHE_REDIR" -eq 1 ]]; then
    echo "Отмонтирование перенаправленных кэшей pacman..."
    umount /var/cache/pacman/pkg || true
fi
umount -R /mnt
swapoff "\$SWAP_PART" || true
reboot


