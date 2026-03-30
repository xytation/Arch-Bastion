# Arch Linux Hardened Bastion — Install Guide

---

## Prerequisites

Two files in the same directory:

```
build-iso.sh
bastion-bootstrap.sh
```

Build host must have archiso installed:

```bash
sudo pacman -S archiso
```

---

## 1 — Build the ISO

```bash
sudo ./build-iso.sh
```

Output lands in `./out/arch-bastion-YYYY.MM.DD-x86_64.iso`.
Takes roughly 10–15 minutes depending on mirror speed.

---

## 2 — Write to USB (bare metal install)

```bash
# Check which device is your USB
lsblk

# Write it — replace sdX with your USB device (e.g. sdb)
sudo dd if=out/arch-bastion-*.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

---

## 2 (alternative) — Test in QEMU

Use the included BIOS script — no UEFI/OVMF required:

```bash
# First run — boot the ISO installer
./run-qemu-bios.sh ~/bastion.img out/arch-bastion-*.iso

# After install is complete, boot the installed system
./run-qemu-bios.sh ~/bastion.img
```

> The disk image is created automatically if it does not exist (40G qcow2).

---

## 3 — Boot and Install

Boot the ISO. It auto-logins as root and shows:

```
  ╔══════════════════════════════════════════════════════════════╗
  ║           Arch Linux Hardened Bastion                       ║
  ╠══════════════════════════════════════════════════════════════╣
  ║  [1]  Install bastion to disk                               ║
  ║  [2]  Run security bootstrap only (existing install)        ║
  ║  [3]  Drop to shell                                         ║
  ╚══════════════════════════════════════════════════════════════╝
```

Choose **[1]**. The installer will show available disks and prompt you through the options:

```
  Available disks:
  ────────────────────────────────────────
  /dev/vda     40G
  ────────────────────────────────────────

  Target disk (e.g. /dev/vda): /dev/vda
  Hostname [bastion]: bastion01
  Enable LUKS encryption? [y/N]: n
```

Then it asks:

1. `THIS WILL WIPE /dev/vda — type YES to continue` — type `YES`
2. Set root password
3. Confirm root password
4. LUKS passphrase (only if you chose `y` for encryption)

The installer then runs automatically:

```
[+] Detecting firmware mode...
[+] Partitioning /dev/vda...
[+] Creating filesystems...
[+] Mounting...
[+] Running pacstrap (this takes a few minutes)...
[+] Configuring system in chroot...
[+] Copying bootstrap script...
[+] Unmounting...
```

---

## 4 — Add Your SSH Public Key BEFORE Rebooting

> **This step is critical.** Password authentication is disabled from first boot.
> If you skip this you will be locked out.

Generate a key pair on your **client machine** if you don't have one:

```bash
ssh-keygen -t ed25519 -C "bastion"
cat ~/.ssh/id_ed25519.pub    # copy this entire line
```

Back in the VM or live ISO shell, mount the installed root and add the key:

```bash
# No LUKS — mount directly
# In QEMU the disk is /dev/vda, root partition is /dev/vda3 or /dev/vda4
# The installer output tells you which partition is root
mount /dev/vda3 /mnt

# With LUKS
cryptsetup open /dev/vda3 cryptroot
mount /dev/mapper/cryptroot /mnt

# Add your public key
mkdir -p /mnt/root/.ssh
chmod 700 /mnt/root/.ssh
echo 'ssh-ed25519 AAAA...your-key... you@host' >> /mnt/root/.ssh/authorized_keys
chmod 600 /mnt/root/.ssh/authorized_keys

# Unmount
umount /mnt
# With LUKS also:
cryptsetup close cryptroot
```

---

## 5 — Reboot

```bash
reboot
# Remove USB / ISO when screen goes blank
```

On first boot `bastion-bootstrap.service` runs automatically in the background.
It takes 2–5 minutes — ClamAV signature download is the slow part.

---

## 6 — SSH In

```bash
# Bare metal — use the machine's IP
ssh root@<ip-address>

# QEMU — port 2222 is forwarded to guest port 22
ssh -p 2222 root@localhost
```

Watch the bootstrap finish if it is still running:

```bash
journalctl -fu bastion-bootstrap.service
```

---

## 7 — Verify the Hardening

```bash
# AppArmor enforcing
aa-status

# Audit rules loaded
auditctl -l

# Firewall active
ufw status verbose

# Services running
systemctl is-active fail2ban clamav-daemon auditd chronyd

# Kernel hardening applied
sysctl kernel.kptr_restrict             # expect 2
sysctl kernel.unprivileged_bpf_disabled # expect 1
sysctl net.ipv4.tcp_syncookies          # expect 1

# Rootkit scan
rkhunter --check --sk

# File integrity baseline
aide --check

# osquery — check listening ports
osqueryi "select * from listening_ports;"
```

---

## 8 — Post-Install (Manual Steps)

```bash
# Create a non-root admin user for day-to-day access
useradd -m -G wheel -s /bin/bash admin
passwd admin

# Add their SSH key
mkdir -p /home/admin/.ssh && chmod 700 /home/admin/.ssh
echo 'ssh-ed25519 AAAA...' > /home/admin/.ssh/authorized_keys
chmod 600 /home/admin/.ssh/authorized_keys
chown -R admin:admin /home/admin/.ssh

# Install aide from AUR (needs a real non-root user)
su - admin
paru -S aide
exit

# Once sudo is confirmed working, lock the root account
passwd -l root

# Install and enable the IP blocklist (optional but recommended)
sudo ./blocklist_update.sh --install
```

---

## Partition Layout Reference

| Firmware | Partition 1 | Partition 2 | Partition 3 | Partition 4 |
|----------|------------|------------|------------|------------|
| BIOS     | 1M BIOS boot (`ef02`) | 1G `/boot` | 2G swap (optional) | rest `/` |
| UEFI     | 512M EFI (`ef00`) | 1G `/boot` | 2G swap (optional) | rest `/` |

Disk is detected automatically — no flags needed.

---

## Summary Timeline

| Step | Time |
|------|------|
| `build-iso.sh` | ~10–15 min |
| Write to USB / start QEMU | ~2 min |
| Boot ISO + installer | ~5 min |
| First reboot (bootstrap service) | ~3–5 min |
| Verify + add admin user | ~5 min |
| **Total** | **~25–30 min** |
