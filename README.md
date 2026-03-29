# Arch Linux Hardened Bastion

A complete, automated security hardening toolkit for Arch Linux bastion hosts,
with an `archiso`-based custom ISO builder.

---

## Repository Structure

```
.
├── bastion-bootstrap.sh          # Main hardening script (run on any Arch system)
├── build-iso.sh                  # Builds the custom bootable ISO
└── archiso-profile/
    ├── profiledef.sh             # ISO metadata (name, label, boot modes)
    ├── packages.x86_64           # Package list baked into the ISO
    └── airootfs/
        ├── usr/local/bin/
        │   └── bastion-install.sh   # Guided installer run from live ISO
        ├── etc/systemd/system/
        │   └── bastion-bootstrap.service  # First-boot hardening service
        └── etc/ssh/sshd_config.d/
            └── 99-live-bastion.conf       # Live ISO SSH config
```

---

## Quick Start

### Option A — Run on an existing Arch system

```bash
git clone <this-repo> && cd <repo>
chmod +x bastion-bootstrap.sh
sudo ./bastion-bootstrap.sh
# Optional flags:
#   --dry-run        Show what would be done, make no changes
#   --skip-updates   Skip pacman -Syu (useful in CI)
sudo reboot
```

### Option B — Build a custom ISO and install to bare metal / VM

**Prerequisites** (on an Arch host):
```bash
sudo pacman -S archiso
```

**Build:**
```bash
sudo ./build-iso.sh
# Output: ./out/arch-bastion-YYYY.MM.DD-x86_64.iso
```

**Write to USB:**
```bash
sudo dd if=out/arch-bastion*.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

**Boot the ISO**, then at the menu:
```
[1] Install bastion to disk
```

This will run `bastion-install.sh`, which:
1. Partitions the target disk (EFI + boot + swap + root)
2. Runs `pacstrap` with the bastion package set
3. Configures locale, hostname, GRUB with hardening cmdline params
4. Installs and enables `bastion-bootstrap.service`
5. On first reboot, the full hardening is applied automatically

---

## What Gets Hardened

| Area | Detail |
|------|--------|
| **Kernel cmdline** | LSMs: AppArmor, Yama, Landlock, BPF; PTI, Spectre/Meltdown mitigations, vsyscall=none, debugfs=off, slab_nomerge |
| **sysctl** | kptr_restrict=2, dmesg_restrict, kexec disabled, unprivileged BPF/userns disabled, ICMP hardening, TCP SYN cookies, source routing off |
| **SSH** | No passwords, no root login, modern ciphers only (chacha20/aes-gcm), rate-limited, forwarding disabled, DH moduli pruned |
| **Firewall** | UFW: deny all inbound except rate-limited SSH |
| **AppArmor** | Enabled + all profiles enforced |
| **Fail2ban** | SSH jail: 3 retries → 24h ban |
| **auditd** | Privilege escalation, kernel module tampering, persistence paths, root execve, user management |
| **Kernel modules** | Rare/dangerous protocols blacklisted (DCCP, SCTP, RDS, Bluetooth optionally) |
| **PAM** | 16-char minimum passwords, complexity requirements, su restricted to wheel |
| **AIDE** | File integrity DB initialised; pacman hook updates DB after every transaction |
| **rkhunter** | Updated and configured for Arch (PKGMGR=PACMAN) |
| **Lynis** | Full audit run on bootstrap |
| **osquery** | Listening ports, logged-in users, kernel modules, crontab monitored every 60s |
| **ClamAV** | Signature DB updated, daemon enabled |
| **NTP** | chrony with NTS (authenticated NTP) via Cloudflare |
| **journald** | Persistent logs, 500M cap, 1-second sync |

---

## Post-Install Checklist

After first reboot:

```bash
# Add your SSH public key BEFORE rebooting if not done during install:
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo "ssh-ed25519 AAAA..." >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

# Verify AppArmor is enforcing
aa-status

# Check audit rules loaded
auditctl -l

# Verify sysctl hardening
sysctl kernel.kptr_restrict       # should be 2
sysctl net.ipv4.tcp_syncookies    # should be 1

# Check UFW status
ufw status verbose

# Run rkhunter check
rkhunter --check --sk

# Verify AIDE baseline
aide --check

# Review Lynis report
cat /var/log/lynis.log | grep Warning
cat /var/log/lynis.log | grep Suggestion

# Check osquery is running
osqueryi "select * from listening_ports;"
```

---

## AUR Packages (aide, paru)

`aide` is installed from the AUR. The bootstrap script installs it via `paru` as
your `$SUDO_USER`. On a fresh ISO install, after the first boot run:

```bash
# As non-root user (create one first):
useradd -m -G wheel admin
passwd admin
su - admin
paru -S aide
```

Or use `makepkg` directly from the AUR.

---

## LUKS Full-Disk Encryption

The installer supports LUKS2 encryption with `--luks`:

```bash
bastion-install.sh --disk /dev/sda --luks
```

This wraps the root partition with:
- LUKS2 + AES-XTS-512 + Argon2id KDF
- A separate unencrypted `/boot` for GRUB

---

## Rollback

Each run of `bastion-bootstrap.sh` creates a timestamped backup directory
and a rollback script:

```bash
/root/security-rollback.sh
```

---

## Dry Run

```bash
sudo ./bastion-bootstrap.sh --dry-run
```

Prints every action without making any changes. Useful for CI pipelines or
reviewing what would change on an existing system.
