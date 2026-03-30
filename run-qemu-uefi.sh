#!/usr/bin/env bash
set -euo pipefail

########################################
# Usage:
#
#  Install mode (boot ISO):
#    ./run-qemu-uefi.sh <DISK> <ISO>
#
#  Normal boot (boot disk):
#    ./run-qemu-uefi.sh <DISK>
#
#  Reset UEFI firmware + Install:
#    ./run-qemu-uefi.sh --reset-fw <DISK> <ISO>
#
#  Reset UEFI firmware + Boot disk:
#    ./run-qemu-uefi.sh --reset-fw <DISK>
########################################

# ── Argument parsing ──────────────────────────────────────────────────────────
RESET_FW=false
WIPE_DISK=false
while true; do
    case "${1:-}" in
        --reset-fw) RESET_FW=true;  shift ;;
        --wipe)     WIPE_DISK=true; RESET_FW=true; shift ;;
        *) break ;;
    esac
done

DISK="${1:-}"
ISO="${2:-}"

if [[ -z "$DISK" ]]; then
    echo "Usage:"
    echo "  Install:         $0 <DISK_IMAGE> <ISO_PATH>"
    echo "  Boot disk:       $0 <DISK_IMAGE>"
    echo "  Fresh install:   $0 --wipe <DISK_IMAGE> <ISO_PATH>   ← wipes disk + resets NVRAM"
    echo "  Reset FW+ISO:    $0 --reset-fw <DISK_IMAGE> <ISO_PATH>"
    echo "  Reset FW+Boot:   $0 --reset-fw <DISK_IMAGE>"
    exit 1
fi

# ── OVMF firmware paths ───────────────────────────────────────────────────────
# Try common locations across distros
for candidate in \
    /usr/share/edk2-ovmf/x64/OVMF_CODE.4m.fd \
    /usr/share/edk2/x64/OVMF_CODE.fd \
    /usr/share/OVMF/OVMF_CODE.fd \
    /usr/share/ovmf/OVMF.fd; do
    if [[ -f "$candidate" ]]; then
        OVMF_CODE="$candidate"
        break
    fi
done
[[ -n "${OVMF_CODE:-}" ]] || { echo "[✗] OVMF firmware not found. Install: pacman -S edk2-ovmf"; exit 1; }

for candidate in \
    /usr/share/edk2-ovmf/x64/OVMF_VARS.4m.fd \
    /usr/share/edk2/x64/OVMF_VARS.fd \
    /usr/share/OVMF/OVMF_VARS.fd \
    /usr/share/ovmf/OVMF.fd; do
    if [[ -f "$candidate" ]]; then
        OVMF_VARS_TEMPLATE="$candidate"
        break
    fi
done
[[ -n "${OVMF_VARS_TEMPLATE:-}" ]] || { echo "[✗] OVMF_VARS template not found."; exit 1; }

# Store OVMF_VARS alongside the disk image — avoids all sudo/HOME path
# confusion. Each disk gets its own NVRAM so VMs never share boot entries.
OVMF_VARS_LOCAL="${DISK}.OVMF_VARS.fd"

# Nuke any stale shared copies left by previous script versions
rm -f "$HOME/.config/qemu/OVMF_VARS.fd"           2>/dev/null || true
rm -f "/root/.config/qemu/OVMF_VARS.fd"           2>/dev/null || true
if [[ -n "${SUDO_USER:-}" ]]; then
    REAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    rm -f "${REAL_HOME}/.config/qemu/OVMF_VARS.fd" 2>/dev/null || true
fi

echo "[+] OVMF_VARS: $OVMF_VARS_LOCAL"

# ── OVMF_VARS handling ────────────────────────────────────────────────────────
# KEY FIX: always reset vars when an ISO is provided.
# Stale NVRAM boot entries from a previous run will make OVMF skip the CD
# entirely and try to boot from disk (or drop to EFI shell).
if $RESET_FW; then
    echo "[+] Resetting UEFI firmware vars (--reset-fw)"
    rm -f "$OVMF_VARS_LOCAL"
elif [[ -n "$ISO" ]]; then
    echo "[+] ISO provided — resetting UEFI vars so CD is seen as first boot device"
    rm -f "$OVMF_VARS_LOCAL"
fi

if [[ ! -f "$OVMF_VARS_LOCAL" ]]; then
    echo "[+] Creating fresh OVMF_VARS from template: $OVMF_VARS_TEMPLATE"
    cp "$OVMF_VARS_TEMPLATE" "$OVMF_VARS_LOCAL"
fi

# ── Disk image ────────────────────────────────────────────────────────────────
if $WIPE_DISK && [[ -f "$DISK" ]]; then
    echo "[+] --wipe: removing existing disk image: $DISK"
    rm -f "$DISK"
fi
if [[ ! -f "$DISK" ]]; then
    echo "[+] Creating fresh 40G qcow2 disk: $DISK"
    qemu-img create -f qcow2 "$DISK" 40G
fi

# KEY FIX: do NOT attach the disk when booting from ISO.
# OVMF scans every attached storage device for EFI partitions regardless
# of NVRAM state. If the disk has any EFI partition (even a broken one from
# a partial install), OVMF will find it and try it before the CD — and fail.
# Solution: only attach the disk when there is no ISO.
DISK_ARGS=""
if [[ -z "$ISO" ]]; then
    DISK_ARGS="-drive id=hd0,if=none,format=qcow2,file=${DISK} -device virtio-blk-pci,drive=hd0"
    echo "[+] Disk attached: $DISK"
else
    echo "[+] ISO mode — disk not attached (prevents stale EFI entries interfering)"
fi

# ── CD-ROM args ───────────────────────────────────────────────────────────────
# Attach ISO as a proper optical disc with media=cdrom so OVMF can read
# the El Torito EFI boot catalog and find the systemd-boot EFI binary.
# No AHCI controller needed — a plain ide-cd device on the default ICH9
# AHCI bus (q35 provides one) is exactly what OVMF expects for CD boot.
CDROM_DRIVE=""

if [[ -n "$ISO" ]]; then
    [[ -f "$ISO" ]] || { echo "[✗] ISO not found: $ISO"; exit 1; }
    echo "[+] ISO attached: $ISO"
    # Simplest form OVMF reliably boots from — no controller splitting,
    # no bootindex. QEMU attaches it to the ICH9 AHCI bus automatically.
    # Fresh OVMF_VARS (reset above) means the CD is the ONLY boot entry
    # so OVMF picks it without needing bootindex hints.
    CDROM_DRIVE="-drive file=${ISO},format=raw,media=cdrom,readonly=on"
else
    echo "[+] Booting from disk only"
fi

# ── Network ───────────────────────────────────────────────────────────────────
# Port-forward host:2222 → guest:22 so you can SSH in without a bridge
NET_ARGS="-netdev user,id=net0,hostfwd=tcp::2222-:22 \
    -device virtio-net-pci,netdev=net0"

echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  QEMU UEFI VM"
echo "  Disk:     $DISK"
echo "  ISO:      ${ISO:-none}"
echo "  OVMF:     $OVMF_CODE"
echo "  SSH:      ssh -p 2222 root@localhost  (once OS is installed)"
echo "══════════════════════════════════════════════════════════════"
echo ""

# ── Launch ────────────────────────────────────────────────────────────────────
# KEY FIX: no -boot flag at all.
# -boot c / -boot d are SeaBIOS (legacy BIOS) directives — OVMF ignores them.
# Boot priority for UEFI is controlled by:
#   Boot order: fresh OVMF_VARS + CD as only bootable device = CD boots first
#   2. OVMF_VARS NVRAM entries (reset above when ISO provided)
sudo qemu-system-x86_64 \
    -enable-kvm \
    -cpu host \
    -smp 4 \
    -m 4096 \
    -machine type=q35,accel=kvm \
    \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$OVMF_VARS_LOCAL" \
    \
    ${DISK_ARGS} \
    \
    ${CDROM_DRIVE} \
    \
    -device virtio-vga \
    ${NET_ARGS}
