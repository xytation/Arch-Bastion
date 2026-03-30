#!/usr/bin/env bash
set -euo pipefail

########################################
# Usage:
#
#  Install mode (boot ISO):
#    ./run-qemu-bios.sh <DISK> <ISO>
#
#  Normal boot (boot disk):
#    ./run-qemu-bios.sh <DISK>
########################################

DISK="${1:-}"
ISO="${2:-}"

if [[ -z "$DISK" ]]; then
    echo "Usage:"
    echo "  Install:   $0 <DISK_IMAGE> <ISO_PATH>"
    echo "  Boot disk: $0 <DISK_IMAGE>"
    exit 1
fi

# ── Disk image — create if missing ───────────────────────────────────────────
if [[ ! -f "$DISK" ]]; then
    echo "[+] Creating fresh 40G disk image: $DISK"
    qemu-img create -f qcow2 "$DISK" 40G
fi

# ── Boot args ─────────────────────────────────────────────────────────────────
CDROM_ARGS=""
BOOT_ARG="-boot c"

if [[ -n "$ISO" ]]; then
    [[ -f "$ISO" ]] || { echo "[✗] ISO not found: $ISO"; exit 1; }
    echo "[+] ISO attached: $ISO"
    CDROM_ARGS="-drive file=${ISO},format=raw,media=cdrom,readonly=on"
    BOOT_ARG="-boot d"
else
    echo "[+] Booting from disk: $DISK"
fi

echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  QEMU BIOS VM"
echo "  Disk: $DISK"
echo "  ISO:  ${ISO:-none}"
echo "  SSH:  ssh -p 2222 root@localhost  (once OS is installed)"
echo "══════════════════════════════════════════════════════════════"
echo ""

# ── Launch ────────────────────────────────────────────────────────────────────
sudo qemu-system-x86_64 \
    -enable-kvm \
    -cpu host \
    -smp 4 \
    -m 4096 \
    -machine type=q35,accel=kvm \
    \
    -drive file="$DISK",format=qcow2,if=virtio \
    ${CDROM_ARGS} \
    ${BOOT_ARG} \
    \
    -device virtio-vga \
    -netdev user,id=net0,hostfwd=tcp::2222-:22 \
    -device virtio-net-pci,netdev=net0
