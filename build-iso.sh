#!/usr/bin/env bash
# =============================================================================
# build-iso.sh — Build the Arch Bastion ISO using archiso
# =============================================================================
# Requirements: archiso (pacman -S archiso)
# Usage:        sudo ./build-iso.sh [--out /path/to/output]
#
# This script is self-contained. It only needs:
#   - build-iso.sh            (this file)
#   - bastion-bootstrap.sh    (in the same directory)
# Everything else is generated at build time.
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

[[ $EUID -eq 0 ]] || { echo "Must be run as root."; exit 1; }

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${SCRIPT_DIR}/out"
WORK_DIR="/tmp/bastion-iso-work"

for arg in "$@"; do
    case "$arg" in
        --out=*)  OUT_DIR="${arg#*=}" ;;
        --out)    shift; OUT_DIR="$1" ;;
        --work=*) WORK_DIR="${arg#*=}" ;;
    esac
done

MERGED="${WORK_DIR}/profile"

log()  { echo "[+] $(date '+%H:%M:%S') $*"; }
warn() { echo "[!] $(date '+%H:%M:%S') $*"; }
die()  { echo "[✗] $(date '+%H:%M:%S') FATAL: $*" >&2; exit 1; }

########################################
# Dependency check
########################################
for dep in mkarchiso pacman git; do
    command -v "$dep" &>/dev/null || \
        die "Missing: $dep — install with: pacman -S archiso git"
done

########################################
# Bootstrap script check
########################################
BOOTSTRAP_SCRIPT="${SCRIPT_DIR}/bastion-bootstrap.sh"
[[ -f "$BOOTSTRAP_SCRIPT" ]] || \
    die "bastion-bootstrap.sh not found at: $BOOTSTRAP_SCRIPT"

########################################
# Locate releng baseline
########################################
RELENG_DIR="/usr/share/archiso/configs/releng"
[[ -d "$RELENG_DIR" ]] || \
    die "archiso releng profile not found at $RELENG_DIR — run: pacman -S archiso"

########################################
# Build merged profile in work dir
########################################
log "Cleaning work directory: $WORK_DIR"
rm -rf "$WORK_DIR"
mkdir -p "$MERGED"

log "Copying releng baseline..."
cp -a "$RELENG_DIR/." "$MERGED/"

# ── Ensure all airootfs directories exist ─────────────────────────────────────
mkdir -p \
    "$MERGED/airootfs/usr/local/bin" \
    "$MERGED/airootfs/etc/ssh/sshd_config.d" \
    "$MERGED/airootfs/etc/systemd/system/getty@tty1.service.d" \
    "$MERGED/airootfs/etc/systemd/system" \
    "$MERGED/airootfs/root"

########################################
# profiledef.sh
########################################
log "Writing profiledef.sh..."
cat > "$MERGED/profiledef.sh" << PROFILEDEF
#!/usr/bin/env bash
iso_name="arch-bastion"
iso_label="ARCH_BASTION_$(date +%Y%m)"
iso_publisher="Bastion Project"
iso_application="Arch Linux Hardened Bastion"
iso_version="$(date +%Y.%m.%d)"
install_dir="arch"
buildmodes=('iso')
bootmodes=(
    'bios.syslinux'
    'uefi.systemd-boot'
)
arch="x86_64"
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'xz' '-Xbcj' 'x86' '-b' '1M' '-Xdict-size' '1M')
file_permissions=(
    ["/root"]="0:0:750"
    ["/root/.automated_script.sh"]="0:0:755"
    ["/root/.bash_profile"]="0:0:644"
    ["/usr/local/bin/bastion-bootstrap.sh"]="0:0:755"
    ["/usr/local/bin/bastion-install.sh"]="0:0:755"
    ["/etc/ssh/sshd_config.d/99-live-bastion.conf"]="0:0:600"
)
PROFILEDEF

########################################
# packages.x86_64 — append to releng list
########################################
log "Appending bastion packages to packages.x86_64..."
cat >> "$MERGED/packages.x86_64" << 'PKGS'

# ── Bastion security additions ────────────────────────────────────────────────
# Explicitly choose iptables-nft to avoid interactive provider prompt for
# libxtables during mkarchiso package install
iptables-nft
apparmor
audit
clamav
fail2ban
lynis
osquery
rkhunter
ufw
chrony
acl
attr
lsof
strace
tcpdump
base-devel
git
PKGS

########################################
# Embed bootstrap script
########################################
log "Embedding bastion-bootstrap.sh..."
cp "$BOOTSTRAP_SCRIPT" "$MERGED/airootfs/usr/local/bin/bastion-bootstrap.sh"
chmod 755 "$MERGED/airootfs/usr/local/bin/bastion-bootstrap.sh"

########################################
# bastion-install.sh (disk installer)
########################################
log "Writing bastion-install.sh..."
cat > "$MERGED/airootfs/usr/local/bin/bastion-install.sh" << 'INSTALL_SCRIPT'
#!/usr/bin/env bash
# =============================================================================
# bastion-install.sh — Arch Bastion disk installer
# Usage: bastion-install.sh --disk /dev/vda [--hostname NAME] [--luks]
# =============================================================================
set -e

step() { echo ""; echo "[+] $*"; }
die()  { echo "[✗] $*"; exit 1; }

TARGET_DISK=""
HOSTNAME="bastion"
USE_LUKS=false
NO_SWAP=false
TIMEZONE="UTC"
LOCALE="en_US.UTF-8"
SWAP_SIZE="2G"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --disk)       TARGET_DISK="$2"; shift 2 ;;
        --disk=*)     TARGET_DISK="${1#*=}"; shift ;;
        --hostname)   HOSTNAME="$2"; shift 2 ;;
        --hostname=*) HOSTNAME="${1#*=}"; shift ;;
        --luks)       USE_LUKS=true; shift ;;
        --no-swap)    NO_SWAP=true; shift ;;
        --timezone=*) TIMEZONE="${1#*=}"; shift ;;
        --locale=*)   LOCALE="${1#*=}"; shift ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[[ -n "$TARGET_DISK" ]] || die "Usage: $0 --disk /dev/vda [--hostname NAME] [--luks]"
[[ -b "$TARGET_DISK" ]] || die "Not a block device: $TARGET_DISK"
[[ $EUID -eq 0 ]]       || die "Must be root."

SWAP_DISPLAY="$SWAP_SIZE"
if $NO_SWAP; then SWAP_DISPLAY="none"; fi

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Arch Bastion Installer"
echo "  Disk:     $TARGET_DISK"
echo "  Hostname: $HOSTNAME"
echo "  LUKS:     $USE_LUKS"
echo "  Swap:     $SWAP_DISPLAY"
echo "═══════════════════════════════════════════════════════"
echo ""
read -rp "  THIS WILL WIPE $TARGET_DISK — type YES to continue: " confirm
if [[ "$confirm" != "YES" ]]; then
    echo "Aborted."
    exit 1
fi

ROOT_PASS=""
while true; do
    read -rsp "  Set root password: " ROOT_PASS; echo
    read -rsp "  Confirm password:  " ROOT_PASS2; echo
    if [[ "$ROOT_PASS" == "$ROOT_PASS2" ]]; then break; fi
    echo "  Passwords do not match, try again."
done

step "Detecting firmware mode..."
if [[ -d /sys/firmware/efi ]]; then
    FIRMWARE="uefi"
    echo "[+] UEFI firmware detected — using GPT layout with EFI partition"
else
    FIRMWARE="bios"
    echo "[+] BIOS firmware detected — using GPT layout with BIOS boot partition"
fi

step "Partitioning $TARGET_DISK..."
sgdisk --zap-all "$TARGET_DISK"
sgdisk --clear   "$TARGET_DISK"

part_prefix="$TARGET_DISK"
[[ "$TARGET_DISK" =~ nvme|mmcblk ]] && part_prefix="${TARGET_DISK}p"

if [[ "$FIRMWARE" == "uefi" ]]; then
    # UEFI layout: EFI + boot + swap(opt) + root
    sgdisk -n 1:0:+512M        -t 1:ef00 -c 1:"EFI"  "$TARGET_DISK"
    sgdisk -n 2:0:+1G          -t 2:8300 -c 2:"boot" "$TARGET_DISK"
    if ! $NO_SWAP; then
        sgdisk -n 3:0:+"${SWAP_SIZE}" -t 3:8200 -c 3:"swap" "$TARGET_DISK"
        sgdisk -n 4:0:0               -t 4:8300 -c 4:"root" "$TARGET_DISK"
    else
        sgdisk -n 3:0:0               -t 3:8300 -c 3:"root" "$TARGET_DISK"
    fi
    EFI_PART="${part_prefix}1"
    BOOT_PART="${part_prefix}2"
    if ! $NO_SWAP; then
        SWAP_PART="${part_prefix}3"; ROOT_PART="${part_prefix}4"
    else
        ROOT_PART="${part_prefix}3"
    fi
else
    # BIOS layout: BIOS boot partition + boot + swap(opt) + root
    sgdisk -n 1:0:+1M          -t 1:ef02 -c 1:"BIOS" "$TARGET_DISK"
    sgdisk -n 2:0:+1G          -t 2:8300 -c 2:"boot" "$TARGET_DISK"
    if ! $NO_SWAP; then
        sgdisk -n 3:0:+"${SWAP_SIZE}" -t 3:8200 -c 3:"swap" "$TARGET_DISK"
        sgdisk -n 4:0:0               -t 4:8300 -c 4:"root" "$TARGET_DISK"
    else
        sgdisk -n 3:0:0               -t 3:8300 -c 3:"root" "$TARGET_DISK"
    fi
    BIOS_PART="${part_prefix}1"
    BOOT_PART="${part_prefix}2"
    if ! $NO_SWAP; then
        SWAP_PART="${part_prefix}3"; ROOT_PART="${part_prefix}4"
    else
        ROOT_PART="${part_prefix}3"
    fi
fi

if $USE_LUKS; then
    step "Setting up LUKS2 on $ROOT_PART..."
    while true; do
        read -rsp "LUKS passphrase: " LUKS_PASS; echo
        read -rsp "Confirm: " LUKS_PASS2; echo
        [[ "$LUKS_PASS" == "$LUKS_PASS2" ]] && break
        echo "Passphrases differ."
    done
    echo -n "$LUKS_PASS" | cryptsetup luksFormat \
        --type luks2 --cipher aes-xts-plain64 --key-size 512 \
        --hash sha512 --pbkdf argon2id --iter-time 5000 \
        --batch-mode "$ROOT_PART" -
    echo -n "$LUKS_PASS" | cryptsetup open "$ROOT_PART" cryptroot -
    ROOT_DEVICE="/dev/mapper/cryptroot"
else
    ROOT_DEVICE="$ROOT_PART"
fi

step "Creating filesystems..."
if [[ "$FIRMWARE" == "uefi" ]]; then
    mkfs.fat -F32 -n EFI "$EFI_PART"
fi
mkfs.ext4 -F -L boot "$BOOT_PART"
mkfs.ext4 -F -L root "$ROOT_DEVICE"
if ! $NO_SWAP; then mkswap -L swap "$SWAP_PART"; swapon "$SWAP_PART"; fi

step "Mounting..."
mount "$ROOT_DEVICE" /mnt
mkdir -p /mnt/boot
mount "$BOOT_PART" /mnt/boot
if [[ "$FIRMWARE" == "uefi" ]]; then
    mkdir -p /mnt/boot/efi
    mount "$EFI_PART" /mnt/boot/efi
fi

step "Running pacstrap (this takes a few minutes)..."
pacstrap -K /mnt \
    base linux linux-firmware linux-headers \
    grub efibootmgr \
    openssh ufw apparmor audit clamav fail2ban lynis rkhunter osquery \
    chrony sudo vim git base-devel networkmanager \
    acl lsof strace tmux htop

genfstab -U /mnt >> /mnt/etc/fstab

step "Configuring system in chroot..."
arch-chroot /mnt /bin/bash << CHROOT
set -euo pipefail
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
hwclock --systohc
sed -i "s|^#\(${LOCALE}.*\)|\1|" /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf
echo "${HOSTNAME}" > /etc/hostname
printf '127.0.0.1\tlocalhost\n::1\tlocalhost\n127.0.1.1\t${HOSTNAME}.localdomain ${HOSTNAME}\n' > /etc/hosts
echo "root:${ROOT_PASS}" | chpasswd

cat > /etc/default/grub << 'GRUB'
GRUB_DEFAULT=0
GRUB_TIMEOUT=3
GRUB_DISTRIBUTOR="Arch Bastion"
GRUB_CMDLINE_LINUX_DEFAULT="quiet lsm=landlock,lockdown,yama,apparmor,bpf slab_nomerge pti=on vsyscall=none debugfs=off spectre_v2=on page_alloc.shuffle=1"
GRUB_CMDLINE_LINUX=""
GRUB_PRELOAD_MODULES="part_gpt part_msdos"
GRUB_TIMEOUT_STYLE=hidden
GRUB_TERMINAL_INPUT=console
GRUB_TERMINAL_OUTPUT=console
GRUB

# Auto-detect BIOS vs UEFI and install GRUB accordingly
if [[ -d /sys/firmware/efi ]]; then
    echo "[+] UEFI detected — installing GRUB for EFI"
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ARCH_BASTION
else
    echo "[+] BIOS detected — installing GRUB for i386-pc"
    grub-install --target=i386-pc "${TARGET_DISK}"
fi
grub-mkconfig -o /boot/grub/grub.cfg
mkinitcpio -P

systemctl enable sshd ufw apparmor fail2ban auditd chronyd NetworkManager

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
CHROOT

step "Copying bootstrap script..."
cp /usr/local/bin/bastion-bootstrap.sh /mnt/usr/local/bin/bastion-bootstrap.sh
chmod 755 /mnt/usr/local/bin/bastion-bootstrap.sh

cat > /mnt/etc/systemd/system/bastion-bootstrap.service << 'SVC'
[Unit]
Description=Bastion Security Bootstrap (First Boot)
After=network-online.target multi-user.target
Wants=network-online.target
ConditionPathExists=!/var/lib/bastion/.bootstrap-complete

[Service]
Type=oneshot
ExecStart=/usr/local/bin/bastion-bootstrap.sh --skip-updates
ExecStartPost=/bin/bash -c "mkdir -p /var/lib/bastion && touch /var/lib/bastion/.bootstrap-complete"
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
SVC
arch-chroot /mnt systemctl enable bastion-bootstrap.service

step "Unmounting..."
umount -R /mnt
$USE_LUKS && cryptsetup close cryptroot || true
$NO_SWAP  || swapoff "${SWAP_PART:-}" 2>/dev/null || true

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Installation complete! Add SSH key then reboot."
echo ""
echo "  mount ${ROOT_DEVICE} /mnt"
echo "  mkdir -p /mnt/root/.ssh && chmod 700 /mnt/root/.ssh"
echo "  echo 'ssh-ed25519 AAAA...' >> /mnt/root/.ssh/authorized_keys"
echo "  chmod 600 /mnt/root/.ssh/authorized_keys"
echo "  umount /mnt && reboot"
echo "═══════════════════════════════════════════════════════"
INSTALL_SCRIPT
chmod 755 "$MERGED/airootfs/usr/local/bin/bastion-install.sh"

########################################
# SSH config for live ISO
########################################
log "Writing live SSH config..."
cat > "$MERGED/airootfs/etc/ssh/sshd_config.d/99-live-bastion.conf" << 'SSH'
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
X11Forwarding no
MaxAuthTries 3
SSH

########################################
# tty1 autologin
########################################
log "Writing tty1 autologin override..."
cat > "$MERGED/airootfs/etc/systemd/system/getty@tty1.service.d/autologin.conf" << 'ALOG'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
ALOG

########################################
# First-boot service
########################################
log "Writing bastion-bootstrap.service..."
cat > "$MERGED/airootfs/etc/systemd/system/bastion-bootstrap.service" << 'SVC'
[Unit]
Description=Bastion Security Bootstrap (First Boot)
After=network-online.target multi-user.target
Wants=network-online.target
ConditionPathExists=!/var/lib/bastion/.bootstrap-complete

[Service]
Type=oneshot
ExecStart=/usr/local/bin/bastion-bootstrap.sh --skip-updates
ExecStartPost=/bin/bash -c "mkdir -p /var/lib/bastion && touch /var/lib/bastion/.bootstrap-complete"
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
SVC

########################################
# Live installer menu
########################################
log "Writing live installer menu..."
cat > "$MERGED/airootfs/root/.automated_script.sh" << 'AUTO'
#!/usr/bin/env bash
clear
cat << 'BANNER'

  ╔══════════════════════════════════════════════════════════════╗
  ║           Arch Linux Hardened Bastion                       ║
  ╠══════════════════════════════════════════════════════════════╣
  ║  [1]  Install bastion to disk                               ║
  ║  [2]  Run security bootstrap only (existing install)        ║
  ║  [3]  Drop to shell                                         ║
  ╚══════════════════════════════════════════════════════════════╝

BANNER
read -rp "  Choice [1-3]: " choice
case "$choice" in
    1)
        echo ""
        echo "  Available disks:"
        echo "  ────────────────────────────────────────"
        lsblk -dpno NAME,SIZE,MODEL | grep -v "loop\|sr0\|rom" |             awk '{printf "  %-12s %s %s\n", $1, $2, $3}'
        echo "  ────────────────────────────────────────"
        echo ""
        read -rp "  Target disk (e.g. /dev/vda): " DISK
        [[ -b "$DISK" ]] || { echo "  [✗] Not a valid block device: $DISK"; exec bash; }
        read -rp "  Hostname [bastion]: " HN
        HN="${HN:-bastion}"
        read -rp "  Enable LUKS encryption? [y/N]: " LUKS
        LUKS_FLAG=""
        [[ "$LUKS" =~ ^[Yy]$ ]] && LUKS_FLAG="--luks"
        echo ""
        /usr/local/bin/bastion-install.sh --disk "$DISK" --hostname "$HN" $LUKS_FLAG
        ;;
    2) /usr/local/bin/bastion-bootstrap.sh ;;
    *) exec bash ;;
esac
AUTO
chmod 755 "$MERGED/airootfs/root/.automated_script.sh"

# Trigger menu on autologin — append to .bash_profile (releng uses that, not .bashrc)
cat >> "$MERGED/airootfs/root/.bash_profile" << 'RC'

[[ -z "${BASTION_MENU_SHOWN:-}" && -f /root/.automated_script.sh ]] && {
    export BASTION_MENU_SHOWN=1
    /root/.automated_script.sh
}
RC

########################################
# Optional: apply local archiso-profile/ overlay if present
# (user can place custom files there without editing this script)
########################################
LOCAL_PROFILE="${SCRIPT_DIR}/archiso-profile"
if [[ -d "$LOCAL_PROFILE" ]]; then
    log "Applying local archiso-profile/ overlay..."
    cp -a "$LOCAL_PROFILE/." "$MERGED/"
else
    log "No archiso-profile/ overlay found — using generated defaults."
fi

########################################
# Build
########################################
mkdir -p "$OUT_DIR"
log "Building ISO — this usually takes 5-15 minutes..."
mkarchiso \
    -v \
    -w "${WORK_DIR}/mkarchiso-work" \
    -o "${OUT_DIR}" \
    "$MERGED"

ISO_FILE=$(find "$OUT_DIR" -name "arch-bastion*.iso" 2>/dev/null | sort | tail -n1)
[[ -n "${ISO_FILE:-}" ]] || ISO_FILE=$(find "$OUT_DIR" -name "*.iso" 2>/dev/null | sort | tail -n1)

echo ""
echo "══════════════════════════════════════════════════════════════"
echo " ISO build complete"
echo " Output: ${ISO_FILE:-$OUT_DIR}"
if [[ -n "${ISO_FILE:-}" ]]; then
    echo " Size:   $(du -sh "$ISO_FILE" | cut -f1)"
    echo " SHA256: $(sha256sum "$ISO_FILE" | cut -d' ' -f1)"
fi
echo ""
echo " Write to USB:"
echo "   dd if='${ISO_FILE:-<iso>}' of=/dev/sdX bs=4M status=progress oflag=sync"
echo "══════════════════════════════════════════════════════════════"
