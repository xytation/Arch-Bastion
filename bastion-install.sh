#!/usr/bin/env bash
# =============================================================================
# bastion-install.sh — Unattended Arch Bastion installer
# Runs from the live ISO to install to disk
# =============================================================================
# Usage: bastion-install.sh --disk /dev/sda [--hostname bastion01]
#                           [--no-swap] [--luks]
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

########################################
# Defaults & CLI parsing
########################################
TARGET_DISK=""
HOSTNAME="bastion"
USE_LUKS=false
NO_SWAP=false
LOCALE="en_US.UTF-8"
TIMEZONE="UTC"
SWAP_SIZE="2G"
ROOT_PASS=""  # Will prompt if empty

for i in "$@"; do
    case "$i" in
        --disk=*)      TARGET_DISK="${i#*=}" ;;
        --disk)        shift; TARGET_DISK="$1" ;;
        --hostname=*)  HOSTNAME="${i#*=}" ;;
        --hostname)    shift; HOSTNAME="$1" ;;
        --luks)        USE_LUKS=true ;;
        --no-swap)     NO_SWAP=true ;;
        --locale=*)    LOCALE="${i#*=}" ;;
        --timezone=*)  TIMEZONE="${i#*=}" ;;
    esac
done

[[ -n "$TARGET_DISK" ]] || { echo "Usage: $0 --disk /dev/sdX [--hostname NAME] [--luks]"; exit 1; }
[[ -b "$TARGET_DISK" ]] || { echo "Not a block device: $TARGET_DISK"; exit 1; }
[[ $EUID -eq 0 ]] || { echo "Must be root."; exit 1; }

echo "═══════════════════════════════════════════════════════"
echo "  Arch Bastion Installer"
echo "  Disk:     $TARGET_DISK"
echo "  Hostname: $HOSTNAME"
echo "  LUKS:     $USE_LUKS"
echo "═══════════════════════════════════════════════════════"
echo ""
read -rp "THIS WILL WIPE $TARGET_DISK. Type YES to continue: " confirm
[[ "$confirm" == "YES" ]] || { echo "Aborted."; exit 1; }

########################################
# Prompt for root password
########################################
while true; do
    read -rsp "Set root password: " ROOT_PASS; echo
    read -rsp "Confirm root password: " ROOT_PASS2; echo
    [[ "$ROOT_PASS" == "$ROOT_PASS2" ]] && break
    echo "Passwords do not match. Try again."
done

########################################
# Partition disk
########################################
echo "[+] Partitioning $TARGET_DISK..."

sgdisk --zap-all "$TARGET_DISK"
sgdisk --clear "$TARGET_DISK"

# Partition layout:
#   1: EFI  (512M)
#   2: boot (1G)    — separate /boot keeps it unencrypted for GRUB
#   3: swap (SWAP_SIZE, optional)
#   4: root (remainder)

sgdisk -n 1:0:+512M   -t 1:ef00 -c 1:"EFI"      "$TARGET_DISK"
sgdisk -n 2:0:+1G     -t 2:8300 -c 2:"boot"     "$TARGET_DISK"

if ! $NO_SWAP; then
    sgdisk -n 3:0:+"${SWAP_SIZE}" -t 3:8200 -c 3:"swap" "$TARGET_DISK"
    sgdisk -n 4:0:0               -t 4:8300 -c 4:"root" "$TARGET_DISK"
else
    sgdisk -n 3:0:0               -t 3:8300 -c 3:"root" "$TARGET_DISK"
fi

# Resolve partition names (handles nvme0n1p1 vs sda1)
part_prefix="$TARGET_DISK"
[[ "$TARGET_DISK" =~ nvme|mmcblk ]] && part_prefix="${TARGET_DISK}p"

EFI_PART="${part_prefix}1"
BOOT_PART="${part_prefix}2"
if ! $NO_SWAP; then
    SWAP_PART="${part_prefix}3"
    ROOT_PART="${part_prefix}4"
else
    ROOT_PART="${part_prefix}3"
fi

########################################
# LUKS encryption (optional)
########################################
if $USE_LUKS; then
    echo "[+] Setting up LUKS on $ROOT_PART..."
    read -rsp "LUKS passphrase: " LUKS_PASS; echo
    read -rsp "Confirm LUKS passphrase: " LUKS_PASS2; echo
    [[ "$LUKS_PASS" == "$LUKS_PASS2" ]] || { echo "Passphrases differ. Aborting."; exit 1; }

    echo -n "$LUKS_PASS" | cryptsetup luksFormat \
        --type luks2 \
        --cipher aes-xts-plain64 \
        --key-size 512 \
        --hash sha512 \
        --pbkdf argon2id \
        --iter-time 5000 \
        --batch-mode \
        "$ROOT_PART" -

    echo -n "$LUKS_PASS" | cryptsetup open "$ROOT_PART" cryptroot -
    ROOT_DEVICE="/dev/mapper/cryptroot"
else
    ROOT_DEVICE="$ROOT_PART"
fi

########################################
# Filesystem creation
########################################
echo "[+] Creating filesystems..."
mkfs.fat  -F32 "$EFI_PART"
mkfs.ext4 -F   "$BOOT_PART"
mkfs.ext4 -F -L bastion-root "$ROOT_DEVICE"
! $NO_SWAP || true
$NO_SWAP || { mkswap "$SWAP_PART"; swapon "$SWAP_PART"; }

########################################
# Mount
########################################
echo "[+] Mounting..."
mount "$ROOT_DEVICE" /mnt
mkdir -p /mnt/boot /mnt/boot/efi
mount "$BOOT_PART"   /mnt/boot
mount "$EFI_PART"    /mnt/boot/efi

########################################
# Pacstrap
########################################
echo "[+] Running pacstrap (this may take a while)..."
pacstrap -K /mnt \
    base linux linux-firmware \
    linux-headers \
    grub efibootmgr \
    openssh \
    ufw \
    apparmor \
    audit \
    clamav \
    fail2ban \
    lynis \
    rkhunter \
    osquery \
    chrony \
    sudo \
    vim \
    git \
    base-devel \
    networkmanager \
    acl \
    lsof \
    strace \
    tmux \
    htop

########################################
# fstab
########################################
genfstab -U /mnt >> /mnt/etc/fstab
echo "[+] fstab generated."

########################################
# Chroot configuration
########################################
echo "[+] Configuring system in chroot..."

arch-chroot /mnt /bin/bash << CHROOT
set -euo pipefail

# Timezone
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
hwclock --systohc

# Locale
sed -i "s/^#${LOCALE}/${LOCALE}/" /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf

# Hostname
echo "${HOSTNAME}" > /etc/hostname
cat > /etc/hosts << 'HOSTS'
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
HOSTS

# Root password
echo "root:${ROOT_PASS}" | chpasswd

# GRUB (with hardening params)
cat > /etc/default/grub << 'GRUB'
GRUB_DEFAULT=0
GRUB_TIMEOUT=3
GRUB_DISTRIBUTOR="Arch Bastion"
GRUB_CMDLINE_LINUX_DEFAULT="quiet lsm=landlock,lockdown,yama,apparmor,bpf slab_nomerge pti=on vsyscall=none debugfs=off spectre_v2=on page_alloc.shuffle=1"
GRUB_CMDLINE_LINUX=""
GRUB_PRELOAD_MODULES="part_gpt part_msdos"
GRUB_ENABLE_CRYPTODISK=n
GRUB_TIMEOUT_STYLE=hidden
GRUB_TERMINAL_INPUT=console
GRUB_TERMINAL_OUTPUT=console
GRUB

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ARCH_BASTION
grub-mkconfig -o /boot/grub/grub.cfg

# mkinitcpio
# If LUKS: add encrypt hook
MKINIT_HOOKS="base udev autodetect microcode modconf kms keyboard keymap consolefont block filesystems fsck"
if [ "${USE_LUKS}" = "true" ]; then
    MKINIT_HOOKS="base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems fsck"
fi
sed -i "s/^HOOKS=.*/HOOKS=(\${MKINIT_HOOKS})/" /etc/mkinitcpio.conf
mkinitcpio -P

# Enable services
systemctl enable sshd
systemctl enable ufw
systemctl enable apparmor
systemctl enable fail2ban
systemctl enable auditd
systemctl enable chronyd
systemctl enable NetworkManager

# SSH: disable password auth and root login immediately
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-bastion.conf << 'SSH'
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
MaxAuthTries 3
LoginGraceTime 30
SSH

echo "[chroot] Configuration complete."
CHROOT

########################################
# Copy bootstrap script to installed system
########################################
echo "[+] Installing bastion bootstrap script..."
cp /usr/local/bin/bastion-bootstrap.sh /mnt/usr/local/bin/bastion-bootstrap.sh
chmod 755 /mnt/usr/local/bin/bastion-bootstrap.sh

# Install and enable first-boot service
cp /etc/systemd/system/bastion-bootstrap.service \
   /mnt/etc/systemd/system/bastion-bootstrap.service

arch-chroot /mnt systemctl enable bastion-bootstrap.service

########################################
# Unmount
########################################
echo "[+] Unmounting..."
umount -R /mnt
$USE_LUKS && cryptsetup close cryptroot || true
$NO_SWAP || swapoff "$SWAP_PART" 2>/dev/null || true

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Installation complete!"
echo "  On first boot, bastion-bootstrap.service will run"
echo "  the full security hardening automatically."
echo ""
echo "  Next steps BEFORE rebooting:"
echo "   1. Mount and add your SSH public key:"
echo "      mount ${ROOT_DEVICE} /mnt"
echo "      mkdir -p /mnt/root/.ssh"
echo "      echo 'ssh-ed25519 AAAA...' > /mnt/root/.ssh/authorized_keys"
echo "      chmod 700 /mnt/root/.ssh"
echo "      chmod 600 /mnt/root/.ssh/authorized_keys"
echo "      umount /mnt"
echo "   2. Reboot: reboot"
echo "═══════════════════════════════════════════════════════"
