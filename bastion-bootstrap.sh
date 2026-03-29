#!/usr/bin/env bash
# =============================================================================
# Arch Linux Bastion Security Bootstrap
# =============================================================================
# Usage: sudo ./bastion-bootstrap.sh [--dry-run] [--skip-updates]
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ── CLI Flags ─────────────────────────────────────────────────────────────────
DRY_RUN=false
SKIP_UPDATES=false
for arg in "$@"; do
    case "$arg" in
        --dry-run)     DRY_RUN=true ;;
        --skip-updates) SKIP_UPDATES=true ;;
    esac
done

# ── Constants ─────────────────────────────────────────────────────────────────
readonly LOG_FILE="/var/log/security-bootstrap.log"
readonly ROLLBACK_SCRIPT="/root/security-rollback.sh"
readonly BACKUP_DIR="/root/security-backups/$(date +%F-%H%M%S)"
readonly LSM_STRING="lsm=landlock,lockdown,yama,apparmor,bpf"
readonly SCRIPT_VERSION="2.0.0"

# ── Logging ───────────────────────────────────────────────────────────────────
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

log()    { echo "[+] $(date '+%H:%M:%S') $*"; }
warn()   { echo "[!] $(date '+%H:%M:%S') $*" >&2; }
die()    { echo "[✗] $(date '+%H:%M:%S') FATAL: $*" >&2; exit 1; }
dryrun() { $DRY_RUN && { echo "[DRY] $*"; return 0; } || return 1; }

log "Bastion bootstrap v${SCRIPT_VERSION} starting"
log "Log: $LOG_FILE"

########################################
# Root Check
########################################
[[ $EUID -eq 0 ]] || die "Must be run as root."

########################################
# Distro Detection (Arch-only for bastion)
########################################
# shellcheck source=/etc/os-release
source /etc/os-release 2>/dev/null || die "Cannot read /etc/os-release"

is_arch() {
    [[ "$ID" == "arch" ]] || \
    [[ "${ID_LIKE:-}" == *"arch"* ]]
}

is_arch || die "This script targets Arch Linux. Detected: $ID"
log "Distro: $ID ${VERSION_ID:-}"

########################################
# Backup helper
########################################
mkdir -p "$BACKUP_DIR"

backup() {
    local src="$1"
    [[ -f "$src" ]] || return 0
    local dest="$BACKUP_DIR/$(basename "$src").$(date +%s)"
    cp -p "$src" "$dest"
    log "Backed up: $src → $dest"
}

########################################
# Rollback script skeleton
########################################
cat > "$ROLLBACK_SCRIPT" << 'ROLLBACK'
#!/usr/bin/env bash
# Auto-generated rollback script
set -euo pipefail
echo "Restoring backups from: BACKUP_PLACEHOLDER"
BACKUP_DIR="BACKUP_PLACEHOLDER"
for f in "$BACKUP_DIR"/*; do
    orig_name=$(basename "$f" | sed 's/\.[0-9]*$//')
    case "$orig_name" in
        grub)          cp "$f" /etc/default/grub && grub-mkconfig -o /boot/grub/grub.cfg ;;
        sshd_config)   cp "$f" /etc/ssh/sshd_config && systemctl restart sshd ;;
        99-paranoid*)  rm -f /etc/sysctl.d/99-paranoid.conf ; sysctl --system ;;
    esac
    echo "Restored: $orig_name"
done
ROLLBACK
sed -i "s|BACKUP_PLACEHOLDER|$BACKUP_DIR|g" "$ROLLBACK_SCRIPT"
chmod 700 "$ROLLBACK_SCRIPT"

########################################
# Package Installation
########################################

# ── Resolve an unprivileged build user ───────────────────────────────────────
# makepkg and paru refuse to run as root. We use $SUDO_USER when available,
# otherwise create a dedicated ephemeral _aur_build account for this session.
AUR_BUILD_USER=""
AUR_BUILD_USER_CREATED=false

resolve_build_user() {
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
        AUR_BUILD_USER="$SUDO_USER"
        log "AUR build user: $AUR_BUILD_USER (from SUDO_USER)"
        return 0
    fi

    # No SUDO_USER — create a throwaway account
    AUR_BUILD_USER="_aur_build"
    if ! id "$AUR_BUILD_USER" &>/dev/null; then
        log "Creating temporary AUR build user: $AUR_BUILD_USER"
        dryrun "useradd -m -r -s /bin/bash $AUR_BUILD_USER" || \
            useradd -m -r -s /bin/bash "$AUR_BUILD_USER"
        AUR_BUILD_USER_CREATED=true
    fi

    # Grant passwordless sudo for pacman only (needed by paru's dependency resolver)
    local sudoers_drop="/etc/sudoers.d/99-aur-build-tmp"
    dryrun "Writing $sudoers_drop" || \
        echo "${AUR_BUILD_USER} ALL=(ALL) NOPASSWD: /usr/bin/pacman" > "$sudoers_drop"
    chmod 440 "$sudoers_drop"

    log "AUR build user: $AUR_BUILD_USER (ephemeral)"
}

# ── Run a command as the build user ──────────────────────────────────────────
as_build_user() {
    dryrun "sudo -u $AUR_BUILD_USER $*" && return 0
    sudo -u "$AUR_BUILD_USER" env HOME="$(getent passwd "$AUR_BUILD_USER" | cut -d: -f6)" "$@"
}

# ── Bootstrap paru from AUR ───────────────────────────────────────────────────
install_paru() {
    if command -v paru &>/dev/null; then
        log "paru already installed: $(paru --version | head -n1)"
        return 0
    fi

    log "Bootstrapping paru from AUR..."

    # base-devel and git are required for makepkg
    dryrun "pacman -S --needed --noconfirm base-devel git" || \
        pacman -S --needed --noconfirm base-devel git

    local build_home
    build_home="$(getent passwd "$AUR_BUILD_USER" | cut -d: -f6)"
    local paru_src="${build_home}/paru-build"

    # Clean any stale build dir
    dryrun "rm -rf $paru_src" || rm -rf "$paru_src"

    # Clone paru from AUR
    dryrun "git clone https://aur.archlinux.org/paru.git $paru_src" || \
        as_build_user git clone https://aur.archlinux.org/paru.git "$paru_src"

    # Build and install (--noconfirm skips prompts; --needed avoids reinstall)
    dryrun "makepkg -si --noconfirm in $paru_src" || \
        as_build_user bash -c "cd '$paru_src' && makepkg -si --noconfirm"

    # Verify
    if ! command -v paru &>/dev/null; then
        die "paru installation failed. Check build logs in $paru_src."
    fi

    log "paru installed: $(paru --version | head -n1)"

    # Harden paru config: never use root, enable colour, enable devel updates
    local paru_cfg_dir="${build_home}/.config/paru"
    dryrun "mkdir -p $paru_cfg_dir" || \
        install -d -o "$AUR_BUILD_USER" -g "$AUR_BUILD_USER" "$paru_cfg_dir"

    dryrun "Writing paru.conf" || \
    cat > "${paru_cfg_dir}/paru.conf" << 'PARU_CONF'
[options]
BottomUp
SudoLoop
UseAsk
CombinedUpgrade
CleanAfter
NewsOnUpgrade
# Never elevate to root inside paru — let the pacman sudoers rule handle it
PARU_CONF

    chown -R "${AUR_BUILD_USER}:${AUR_BUILD_USER}" "$paru_cfg_dir"
}

# ── Install AUR packages via paru ─────────────────────────────────────────────
install_aur_packages() {
    local aur_pkgs=("$@")
    log "Installing AUR packages: ${aur_pkgs[*]}"
    dryrun "paru -S --needed --noconfirm ${aur_pkgs[*]}" || \
        as_build_user paru -S --needed --noconfirm "${aur_pkgs[@]}"
}

# ── Cleanup ephemeral build user ─────────────────────────────────────────────
cleanup_build_user() {
    if $AUR_BUILD_USER_CREATED; then
        log "Removing ephemeral build user: $AUR_BUILD_USER"
        dryrun "userdel -r $AUR_BUILD_USER" || userdel -r "$AUR_BUILD_USER" || true
        dryrun "rm -f /etc/sudoers.d/99-aur-build-tmp" || \
            rm -f /etc/sudoers.d/99-aur-build-tmp
        log "Build user removed."
    fi
}
# Register cleanup to run on exit (success or failure)
trap cleanup_build_user EXIT

# ── Main install sequence ─────────────────────────────────────────────────────
install_packages() {
    local pacman_pkgs=(
        # Core security tooling
        apparmor
        audit
        clamav
        fail2ban
        lynis
        osquery
        rkhunter
        # Firewall
        ufw
        # Integrity (base-devel + git needed to build aide/paru from AUR)
        base-devel
        git
        # Utilities
        openssh
        chrony
        acl
        attr
        lsof
        strace
        tcpdump
        wireshark-cli
    )

    local aur_pkgs=(
        aide    # File integrity monitoring — AUR only on Arch
    )

    if ! $SKIP_UPDATES; then
        log "Updating system..."
        dryrun "pacman -Syu --noconfirm" || pacman -Syu --noconfirm
    fi

    log "Installing pacman packages..."
    dryrun "pacman -S --needed --noconfirm ${pacman_pkgs[*]}" || \
        pacman -S --needed --noconfirm "${pacman_pkgs[@]}"

    # Resolve build user before touching AUR
    resolve_build_user

    # Bootstrap paru (builds from AUR source if not present)
    install_paru

    # Install AUR packages through paru
    install_aur_packages "${aur_pkgs[@]}"
}

install_packages

########################################
# Secure Boot Detection
########################################
detect_secure_boot() {
    if command -v mokutil &>/dev/null; then
        mokutil --sb-state 2>/dev/null | grep -q "SecureBoot enabled" \
            && echo "enabled" || echo "disabled"
    elif [[ -d /sys/firmware/efi ]]; then
        echo "efi-no-mokutil"
    else
        echo "legacy-bios"
    fi
}
SECURE_BOOT=$(detect_secure_boot)
log "Secure Boot: $SECURE_BOOT"

########################################
# Bootloader Detection
########################################
detect_bootloader() {
    if [[ -f /etc/default/grub ]] || [[ -d /boot/grub ]]; then
        echo "grub"
    elif command -v bootctl &>/dev/null && bootctl is-installed &>/dev/null; then
        echo "systemd-boot"
    else
        echo "unknown"
    fi
}
BOOTLOADER=$(detect_bootloader)
log "Bootloader: $BOOTLOADER"

########################################
# LSM / Kernel Cmdline Hardening
########################################
configure_grub() {
    local grub_file="/etc/default/grub"
    backup "$grub_file"

    local current
    current=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$grub_file" | cut -d'"' -f2)

    # Idempotency: skip if already set
    if echo "$current" | grep -q "lsm="; then
        warn "GRUB already has lsm= parameter. Review manually: $grub_file"
        return 0
    fi

    # Additional hardening params beyond LSMs
    local extra_params=(
        "$LSM_STRING"
        "slab_nomerge"          # Prevent slab merging (heap spray mitigation)
        "slub_debug=FZP"        # Slab debugging
        "page_alloc.shuffle=1"  # Page allocator randomisation
        "pti=on"                # Page Table Isolation (Meltdown)
        "spectre_v2=on"         # Spectre v2 mitigation
        "spec_store_bypass_disable=on"
        "mce=0"                 # Disable MCE
        "vsyscall=none"         # Disable legacy vsyscall
        "debugfs=off"           # Disable debugfs
        "quiet loglevel=0"      # Suppress boot messages (reduces info leak)
    )

    local new_cmdline="$current ${extra_params[*]}"
    dryrun "Updating GRUB_CMDLINE_LINUX_DEFAULT" || \
        sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${new_cmdline}\"|" "$grub_file"

    dryrun "grub-mkconfig -o /boot/grub/grub.cfg" || \
        grub-mkconfig -o /boot/grub/grub.cfg
    log "GRUB updated with hardening params."
}

configure_systemd_boot() {
    local entry
    entry=$(find /boot/loader/entries -name "*.conf" 2>/dev/null | head -n1)
    [[ -n "$entry" ]] || { warn "No systemd-boot entry found."; return 1; }

    backup "$entry"

    if grep -q "lsm=" "$entry"; then
        warn "systemd-boot entry already has lsm=. Review: $entry"
        return 0
    fi

    dryrun "Patching systemd-boot entry: $entry" || \
        sed -i "s|^options \(.*\)|options \1 ${LSM_STRING} slab_nomerge pti=on vsyscall=none debugfs=off|" "$entry"
    log "systemd-boot entry updated."
}

case "$BOOTLOADER" in
    grub)         configure_grub ;;
    systemd-boot) configure_systemd_boot ;;
    *)            warn "Unknown bootloader. Manually add: $LSM_STRING to kernel cmdline." ;;
esac

########################################
# Service Enable Helper
########################################
enable_service() {
    local svc="$1"
    if systemctl list-unit-files --quiet "$svc" &>/dev/null; then
        dryrun "systemctl enable --now $svc" || systemctl enable --now "$svc" || true
        log "Enabled & started: $svc"
    else
        warn "Service not found, skipping: $svc"
    fi
}

########################################
# SSH Hardening
########################################
harden_ssh() {
    local ssh_cfg="/etc/ssh/sshd_config"
    local drop_in_dir="/etc/ssh/sshd_config.d"
    backup "$ssh_cfg"
    mkdir -p "$drop_in_dir"

    # Use a drop-in so distro updates don't clobber changes
    dryrun "Writing $drop_in_dir/99-bastion-hardening.conf" || \
    cat > "$drop_in_dir/99-bastion-hardening.conf" << 'SSH_EOF'
# Bastion SSH Hardening
# ------- Authentication -------
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AuthorizationKeysFile .ssh/authorized_keys
ChallengeResponseAuthentication no
UsePAM yes
KerberosAuthentication no
GSSAPIAuthentication no

# ------- Privilege separation -------
UsePrivilegeSeparation sandbox

# ------- Session / Protocol -------
Protocol 2
Port 22
AddressFamily inet
LoginGraceTime 30
MaxAuthTries 3
MaxSessions 5
ClientAliveInterval 300
ClientAliveCountMax 2
TCPKeepAlive no
Compression no

# ------- Features (attack surface reduction) -------
AllowAgentForwarding no
AllowTcpForwarding no
X11Forwarding no
PermitTunnel no
PrintMotd no
Banner /etc/ssh/banner

# ------- Ciphers / MACs (Mozilla Modern) -------
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com

# ------- Logging -------
LogLevel VERBOSE
SyslogFacility AUTH
SSH_EOF

    # SSH Banner
    dryrun "Writing /etc/ssh/banner" || \
    cat > /etc/ssh/banner << 'BANNER'
###############################################################################
AUTHORISED ACCESS ONLY. All activity is monitored and logged.
Unauthorised access is a criminal offence.
###############################################################################
BANNER

    # Tighten sshd_config permissions
    chmod 600 "$ssh_cfg"
    chmod 600 "$drop_in_dir/99-bastion-hardening.conf"

    # Remove short Diffie-Hellman moduli (< 3071 bits)
    if [[ -f /etc/ssh/moduli ]]; then
        backup /etc/ssh/moduli
        awk '$5 >= 3071' /etc/ssh/moduli > /etc/ssh/moduli.safe && \
            mv /etc/ssh/moduli.safe /etc/ssh/moduli
        log "Pruned weak DH moduli."
    fi

    enable_service sshd
}

harden_ssh

########################################
# UFW Firewall
########################################
configure_ufw() {
    if ! command -v ufw &>/dev/null; then
        warn "ufw not installed. Install it manually."
        return 1
    fi

    dryrun "Configuring UFW" || {
        ufw --force reset
        ufw default deny incoming
        ufw default deny forward
        ufw default allow outgoing
        ufw limit OpenSSH comment 'Rate-limited SSH'
        ufw logging on
        ufw --force enable
    }
    log "UFW configured."
}

configure_ufw

########################################
# AppArmor
########################################
configure_apparmor() {
    enable_service apparmor

    # Enforce all profiles that are in complain mode
    if command -v aa-enforce &>/dev/null; then
        find /etc/apparmor.d -maxdepth 1 -type f ! -name "*.dpkg-*" | while read -r profile; do
            dryrun "aa-enforce $profile" || aa-enforce "$profile" 2>/dev/null || true
        done
        log "AppArmor profiles enforced."
    fi
}

configure_apparmor

########################################
# Fail2ban
########################################
configure_fail2ban() {
    local jail_local="/etc/fail2ban/jail.local"

    if [[ ! -f "$jail_local" ]]; then
        dryrun "Writing $jail_local" || \
        cat > "$jail_local" << 'F2B'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 3
backend  = systemd
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled  = true
port     = 22
logpath  = %(sshd_log)s
maxretry = 3
bantime  = 24h
F2B
    fi

    enable_service fail2ban
}

configure_fail2ban

########################################
# ClamAV
########################################
configure_clamav() {
    if ! command -v freshclam &>/dev/null; then
        warn "ClamAV not found, skipping."
        return 1
    fi

    dryrun "freshclam" || freshclam || true
    enable_service clamav-daemon
    enable_service clamav-freshclam
}

configure_clamav

########################################
# RKHunter
########################################
configure_rkhunter() {
    if ! command -v rkhunter &>/dev/null; then
        warn "rkhunter not found, skipping."
        return 1
    fi

    local rk_cfg="/etc/rkhunter.conf"
    backup "$rk_cfg"

    dryrun "rkhunter --update" || rkhunter --update || true
    dryrun "rkhunter --propupd" || rkhunter --propupd || true

    # Silence some Arch-specific false positives
    if [[ -f "$rk_cfg" ]]; then
        dryrun "Patching rkhunter.conf" || {
            sed -i 's|^#MAIL-ON-WARNING=|MAIL-ON-WARNING=|' "$rk_cfg"
            sed -i 's|PKGMGR=NONE|PKGMGR=PACMAN|'           "$rk_cfg"
            sed -i 's|^#SCRIPTWHITELIST=|SCRIPTWHITELIST=|' "$rk_cfg"
        }
    fi

    log "rkhunter configured."
}

configure_rkhunter

########################################
# Lynis
########################################
run_lynis() {
    if command -v lynis &>/dev/null; then
        dryrun "lynis audit" || lynis audit system --quick --logfile /var/log/lynis.log || true
        log "Lynis scan complete. Report: /var/log/lynis.log"
    fi
}

run_lynis

########################################
# AIDE (File Integrity Monitoring)
########################################
configure_aide() {
    if ! command -v aide &>/dev/null; then
        warn "aide not found, skipping."
        return 1
    fi

    local aide_cfg="/etc/aide.conf"
    backup "$aide_cfg"

    dryrun "aide --init" || aide --init || true

    local new_db="/var/lib/aide/aide.db.new"
    local live_db="/var/lib/aide/aide.db"

    if [[ -f "$new_db" ]]; then
        dryrun "mv $new_db $live_db" || mv "$new_db" "$live_db"
        log "AIDE database initialised at $live_db"
    fi

    # Weekly AIDE check via systemd timer
    dryrun "Writing aide check timer" || \
    cat > /etc/systemd/system/aide-check.service << 'AIDE_SVC'
[Unit]
Description=AIDE Integrity Check
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/bin/aide --check
StandardOutput=journal
StandardError=journal
AIDE_SVC

    dryrun "Writing aide-check.timer" || \
    cat > /etc/systemd/system/aide-check.timer << 'AIDE_TIMER'
[Unit]
Description=Weekly AIDE Integrity Check

[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
AIDE_TIMER

    dryrun "systemctl enable --now aide-check.timer" || \
        systemctl enable --now aide-check.timer || true
}

configure_aide

########################################
# auditd
########################################
configure_auditd() {
    enable_service auditd

    dryrun "Writing audit rules" || \
    cat > /etc/audit/rules.d/99-bastion.rules << 'AUDIT_EOF'
# ── Delete existing rules ────────────────────────────────────────────────────
-D
# Set buffer size (increase if you see lost events)
-b 8192
# Failure mode: 1=printk, 2=panic (panic is safer for bastion but noisy)
-f 1

# ── Privilege escalation ─────────────────────────────────────────────────────
-w /usr/bin/sudo         -p x  -k priv_esc
-w /usr/bin/su           -p x  -k priv_esc
-w /usr/bin/newgrp       -p x  -k priv_esc
-w /usr/bin/pkexec       -p x  -k priv_esc

# ── Kernel module tampering ───────────────────────────────────────────────────
-w /usr/bin/insmod       -p x  -k kernel_mod
-w /usr/bin/rmmod        -p x  -k kernel_mod
-w /usr/bin/modprobe     -p x  -k kernel_mod
-a always,exit -F arch=b64 -S init_module -S delete_module -k kernel_mod
-a always,exit -F arch=b64 -S finit_module                  -k kernel_mod

# ── Dangerous syscalls ────────────────────────────────────────────────────────
-a always,exit -F arch=b64 -S ptrace                -k tracing
-a always,exit -F arch=b64 -S personality           -k personality
-a always,exit -F arch=b64 -S prctl                 -k prctl

# ── Persistence targets ───────────────────────────────────────────────────────
-w /etc/passwd           -p wa -k persistence
-w /etc/shadow           -p wa -k persistence
-w /etc/group            -p wa -k persistence
-w /etc/gshadow          -p wa -k persistence
-w /etc/sudoers          -p wa -k persistence
-w /etc/sudoers.d        -p wa -k persistence
-w /etc/pacman.conf      -p wa -k persistence
-w /etc/pacman.d         -p wa -k persistence
-w /etc/systemd/system   -p wa -k persistence
-w /etc/cron.d           -p wa -k persistence
-w /etc/cron.daily       -p wa -k persistence
-w /etc/cron.hourly      -p wa -k persistence
-w /etc/crontab          -p wa -k persistence
-w /var/spool/cron       -p wa -k persistence
-w /etc/hosts            -p wa -k network_config
-w /etc/resolv.conf      -p wa -k network_config

# ── Authentication ────────────────────────────────────────────────────────────
-w /etc/pam.d            -p wa -k pam_config
-w /etc/security         -p wa -k pam_config
-w /var/log/auth.log     -p wa -k auth_log
-w /var/log/faillog      -p wa -k auth_log

# ── Sensitive binaries ────────────────────────────────────────────────────────
-w /usr/bin/passwd       -p x  -k passwd_change
-w /usr/bin/chpasswd     -p x  -k passwd_change
-w /usr/bin/useradd      -p x  -k user_mgmt
-w /usr/bin/userdel      -p x  -k user_mgmt
-w /usr/bin/usermod      -p x  -k user_mgmt
-w /usr/bin/groupadd     -p x  -k user_mgmt
-w /usr/bin/groupdel     -p x  -k user_mgmt
-w /usr/bin/ssh          -p x  -k ssh_exec
-w /usr/sbin/sshd        -p x  -k ssh_exec

# ── Root execution ────────────────────────────────────────────────────────────
-a always,exit -F arch=b64 -S execve -F euid=0 -F auid!=0 -k root_exec

# ── Immutable mode (comment out during initial setup) ────────────────────────
# -e 2
AUDIT_EOF

    dryrun "augenrules --load" || augenrules --load || true
    log "auditd rules loaded."
}

configure_auditd

########################################
# Kernel Hardening (sysctl)
########################################
configure_sysctl() {
    dryrun "Writing /etc/sysctl.d/99-bastion.conf" || \
    cat > /etc/sysctl.d/99-bastion.conf << 'SYSCTL'
# =============================================================================
# Bastion Kernel Hardening - sysctl
# =============================================================================

## ── Kernel ───────────────────────────────────────────────────────────────────
# Hide kernel pointers from /proc
kernel.kptr_restrict = 2
# Restrict dmesg to root
kernel.dmesg_restrict = 1
# Disable kexec (prevents loading a new kernel at runtime)
kernel.kexec_load_disabled = 1
# Restrict unprivileged BPF
kernel.unprivileged_bpf_disabled = 1
# Restrict perf events
kernel.perf_event_paranoid = 3
# Restrict ptrace to parent process only (Yama)
kernel.yama.ptrace_scope = 2
# Disable sysrq
kernel.sysrq = 0
# Randomise kernel stack offset
kernel.randomize_va_space = 2
# Restrict user namespaces (can break rootless containers — adjust if needed)
kernel.unprivileged_userns_clone = 0

## ── Network ──────────────────────────────────────────────────────────────────
# Reverse path filtering
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
# SYN flood protection
net.ipv4.tcp_syncookies = 1
# Ignore ICMP broadcast (smurf attack)
net.ipv4.icmp_echo_ignore_broadcasts = 1
# Ignore bogus ICMP errors
net.ipv4.icmp_ignore_bogus_error_responses = 1
# Disable ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
# Disable sending redirects
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
# Log martian packets
net.ipv4.conf.all.log_martians = 1
# Disable source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
# Disable IPv6 router advertisements
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0
# Disable TCP timestamps (leaks uptime, minor privacy)
net.ipv4.tcp_timestamps = 0
# Increase local port range
net.ipv4.ip_local_port_range = 1024 65535
# TIME-WAIT assassination protection
net.ipv4.tcp_rfc1337 = 1

## ── Filesystem ───────────────────────────────────────────────────────────────
# Protect hard/symlinks against TOCTOU
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
# Restrict FIFO writes
fs.protected_fifos = 2
fs.protected_regular = 2
# Disable core dumps for setuid binaries
fs.suid_dumpable = 0
# Restrict /proc access
kernel.perf_cpu_time_max_percent = 1
SYSCTL

    dryrun "sysctl --system" || sysctl --system
    log "sysctl hardening applied."
}

configure_sysctl

########################################
# Kernel Module Blacklisting
########################################
configure_module_blacklist() {
    dryrun "Writing /etc/modprobe.d/99-bastion-blacklist.conf" || \
    cat > /etc/modprobe.d/99-bastion-blacklist.conf << 'MODS'
# ── Uncommon network protocols ────────────────────────────────────────────────
# These are rarely needed on a bastion and expand the attack surface
blacklist dccp
blacklist sctp
blacklist rds
blacklist tipc
blacklist n-hdlc
blacklist ax25
blacklist netrom
blacklist x25
blacklist rose
blacklist decnet
blacklist econet
blacklist af_802154
blacklist ipx
blacklist appletalk
blacklist psnap
blacklist p8023
blacklist llc
blacklist p8022

# ── Uncommon filesystems ───────────────────────────────────────────────────────
blacklist cramfs
blacklist freevxfs
blacklist jffs2
blacklist hfs
blacklist hfsplus
blacklist squashfs
blacklist udf

# ── Thunderbolt / FireWire DMA ─────────────────────────────────────────────────
blacklist thunderbolt
blacklist firewire-core
blacklist firewire-ohci
blacklist firewire-sbp2

# ── Bluetooth (uncomment if not needed) ───────────────────────────────────────
# blacklist bluetooth
# blacklist btusb

# ── USB storage (uncomment for high-security bastion) ─────────────────────────
# blacklist usb-storage
MODS

    log "Module blacklist configured."
}

configure_module_blacklist

########################################
# PAM Hardening
########################################
configure_pam() {
    local pw_quality="/etc/security/pwquality.conf"
    backup "$pw_quality"

    dryrun "Configuring pwquality" || \
    cat > "$pw_quality" << 'PAM'
minlen   = 16
minclass = 4
maxrepeat = 2
maxsequence = 3
dcredit  = -1
ucredit  = -1
lcredit  = -1
ocredit  = -1
dictcheck = 1
usercheck = 1
PAM

    # Restrict su to wheel group
    local su_pam="/etc/pam.d/su"
    if [[ -f "$su_pam" ]]; then
        backup "$su_pam"
        dryrun "Restricting su to wheel" || \
            sed -i 's/^#\(auth.*pam_wheel.*\)/\1/' "$su_pam"
    fi

    log "PAM hardening applied."
}

configure_pam

########################################
# Login / Account Policies
########################################
configure_login_defs() {
    local logindefs="/etc/login.defs"
    backup "$logindefs"

    dryrun "Patching login.defs" || {
        sed -i 's/^PASS_MAX_DAYS.*/PASS_MAX_DAYS   90/'   "$logindefs"
        sed -i 's/^PASS_MIN_DAYS.*/PASS_MIN_DAYS   1/'    "$logindefs"
        sed -i 's/^PASS_WARN_AGE.*/PASS_WARN_AGE   14/'   "$logindefs"
        sed -i 's/^UMASK.*/UMASK           027/'          "$logindefs"
        # Require SHA-512 password hashing
        sed -i 's/^#\s*ENCRYPT_METHOD.*/ENCRYPT_METHOD SHA512/' "$logindefs"
    }

    log "login.defs hardened."
}

configure_login_defs

########################################
# Chrony (Secure NTP)
########################################
configure_ntp() {
    local chrony_cfg="/etc/chrony.conf"
    backup "$chrony_cfg"

    dryrun "Configuring chrony" || \
    cat > "$chrony_cfg" << 'NTP'
# Use NTS-capable servers where possible
server time.cloudflare.com iburst nts
server ntppool1.time.nl iburst nts
pool pool.ntp.org iburst

# Restrict queries
restrict default nomodify nopeer noquery notrap
restrict 127.0.0.1
restrict ::1

# Key management
keyfile /etc/chrony.keys
driftfile /var/lib/chrony/drift
logdir /var/log/chrony

# Secure operation
rtcsync
makestep 1.0 3
NTP

    enable_service chronyd
}

configure_ntp

########################################
# Pacman Integrity Hooks
########################################
configure_pacman_hooks() {
    local hook_dir="/etc/pacman.d/hooks"
    mkdir -p "$hook_dir"

    dryrun "Writing pacman integrity hook" || \
    cat > "$hook_dir/99-aide-update.hook" << 'HOOK'
[Trigger]
Operation = Install
Operation = Upgrade
Operation = Remove
Type = Package
Target = *

[Action]
Description = Updating AIDE database after package change...
When = PostTransaction
Exec = /usr/bin/aide --update
Depends = aide
HOOK

    dryrun "Writing pacman audit hook" || \
    cat > "$hook_dir/99-audit-pkginstall.hook" << 'HOOK2'
[Trigger]
Operation = Install
Operation = Upgrade
Operation = Remove
Type = Package
Target = *

[Action]
Description = Logging package change to audit log...
When = PostTransaction
Exec = /usr/bin/logger -p audit.info -t pacman "Package transaction completed"
HOOK2

    log "Pacman hooks installed."
}

configure_pacman_hooks

########################################
# Arch Package Integrity Check
########################################
arch_integrity_check() {
    log "Running pacman package integrity check..."
    dryrun "pacman -Qkk" || pacman -Qkk > /var/log/pacman-integrity.log 2>&1 || true
    log "Package integrity log: /var/log/pacman-integrity.log"
}

arch_integrity_check

########################################
# systemd Hardening
########################################
configure_systemd_hardening() {
    # Restrict systemd-logind and journald
    mkdir -p /etc/systemd/system/systemd-logind.service.d
    dryrun "Writing logind hardening override" || \
    cat > /etc/systemd/system/systemd-logind.service.d/hardening.conf << 'SD'
[Service]
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
RestrictRealtime=true
SD

    # Journal hardening: persist logs, set size limit
    backup /etc/systemd/journald.conf
    dryrun "Configuring journald" || \
    cat > /etc/systemd/journald.conf.d/99-bastion.conf << 'JD'
[Journal]
Storage=persistent
Compress=yes
SyncIntervalSec=1m
RateLimitIntervalSec=30s
RateLimitBurst=10000
SystemMaxUse=500M
MaxLevelConsole=warning
JD

    mkdir -p /etc/systemd/journald.conf.d
    log "systemd hardening applied."
}

configure_systemd_hardening

########################################
# osquery
########################################
configure_osquery() {
    if ! command -v osqueryd &>/dev/null; then
        warn "osquery not found, skipping."
        return 1
    fi

    mkdir -p /etc/osquery

    dryrun "Writing osquery config" || \
    cat > /etc/osquery/osquery.conf << 'OSQ'
{
  "options": {
    "logger_path": "/var/log/osquery",
    "disable_logging": "false",
    "log_result_events": "true",
    "schedule_splay_percent": "10",
    "events_expiry": "3600",
    "utc": "true"
  },
  "schedule": {
    "sshd_config": {
      "query": "SELECT * FROM sshd_config;",
      "interval": 3600
    },
    "listening_ports": {
      "query": "SELECT pid, port, protocol, address FROM listening_ports;",
      "interval": 60
    },
    "logged_in_users": {
      "query": "SELECT liu.*, p.name, p.cmdline, p.cwd, p.root FROM logged_in_users liu, processes p WHERE liu.pid = p.pid;",
      "interval": 60
    },
    "crontab": {
      "query": "SELECT * FROM crontab;",
      "interval": 3600
    },
    "kernel_modules": {
      "query": "SELECT * FROM kernel_modules;",
      "interval": 3600
    },
    "startup_items": {
      "query": "SELECT * FROM startup_items;",
      "interval": 3600
    },
    "users": {
      "query": "SELECT * FROM users;",
      "interval": 3600
    },
    "processes_with_open_sockets": {
      "query": "SELECT DISTINCT p.pid, p.name, p.cmdline, os.remote_address, os.remote_port FROM processes p JOIN open_sockets os USING (pid) WHERE os.remote_port != 0;",
      "interval": 60
    }
  }
}
OSQ

    enable_service osqueryd
}

configure_osquery

########################################
# Final: MOTD / Issue Files
########################################
configure_motd() {
    dryrun "Setting /etc/issue" || \
    cat > /etc/issue << 'ISSUE'

  *** AUTHORISED USERS ONLY ***
  This system is for authorised use only. Unauthorised or improper use
  of this system is prohibited and may result in criminal prosecution.
  All activity is monitored and logged.

ISSUE

    cp /etc/issue /etc/issue.net
    log "MOTD and issue files set."
}

configure_motd

########################################
# Summary
########################################
echo ""
echo "══════════════════════════════════════════════════════════════"
echo " Bastion Bootstrap Complete"
echo "══════════════════════════════════════════════════════════════"
echo " Log:          $LOG_FILE"
echo " Backups:      $BACKUP_DIR"
echo " Rollback:     $ROLLBACK_SCRIPT"
echo ""
echo " POST-BOOT CHECKLIST:"
echo "  [ ] Verify AppArmor: aa-status"
echo "  [ ] Verify auditd:   auditctl -l"
echo "  [ ] Check rkhunter:  rkhunter --check"
echo "  [ ] Review Lynis:    cat /var/log/lynis.log"
echo "  [ ] Verify AIDE DB:  aide --check"
echo "  [ ] Check osquery:   osqueryi 'select * from listening_ports;'"
echo "  [ ] Verify sysctl:   sysctl -a | grep kernel.kptr_restrict"
echo "  [ ] Verify UFW:      ufw status verbose"
echo "  [ ] Add SSH keys:    ~/.ssh/authorized_keys"
echo "══════════════════════════════════════════════════════════════"
echo " A REBOOT IS REQUIRED for kernel cmdline and module changes."
echo "══════════════════════════════════════════════════════════════"
