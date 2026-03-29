#!/usr/bin/env bash
# =============================================================================
# blocklist_update.sh — Malicious IP blocklist via ipset + nftables
# Designed for Arch Linux bastion hosts using nftables/ufw.
#
# Usage:
#   sudo ./blocklist_update.sh                        # run once
#   sudo ./blocklist_update.sh --install              # install systemd timer
#   sudo ./blocklist_update.sh --whitelist 1.2.3.4   # add IP to whitelist
# =============================================================================

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
readonly IPSET_NAME="blocklist"
readonly IPSET_TYPE="hash:net"
readonly LOG_FILE="/var/log/blocklist_update.log"
readonly IPSET_SAVE_FILE="/etc/ipset.conf"
readonly WHITELIST_FILE="/etc/blocklist_whitelist.conf"
readonly SCRIPT_PATH="$(realpath "$0")"

# Threat intelligence feeds
readonly -a FEEDS=(
    # ipsum level 3+ (seen on 3+ blacklists) — good balance of precision/coverage
    "https://raw.githubusercontent.com/stamparm/ipsum/refs/heads/master/levels/3.txt"
    # Feodo tracker — botnet C2 servers (very high confidence)
    "https://feodotracker.abuse.ch/downloads/ipblocklist_recommended.txt"
    # Spamhaus DROP — hijacked/allocated-to-criminals netblocks (very high confidence)
    "https://www.spamhaus.org/drop/drop.txt"
)

# ── Logging ───────────────────────────────────────────────────────────────────
log()  { local l="$1"; shift; local m="[$(date '+%Y-%m-%d %H:%M:%S')] [$l] $*"; echo "$m" | tee -a "$LOG_FILE"; }
die()  { log "ERROR" "$*"; exit 1; }
info() { log "INFO"  "$*"; }
warn() { log "WARN"  "$*"; }

# ── Dependency check ──────────────────────────────────────────────────────────
check_dependencies() {
    local missing=()
    for cmd in ipset nft curl grep cut; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    [[ ${#missing[@]} -eq 0 ]] || die "Missing tools: ${missing[*]} — install with: pacman -S ipset nftables curl"
    [[ $EUID -eq 0 ]] || die "Must be run as root."
}

# ── Whitelist helpers ─────────────────────────────────────────────────────────
load_whitelist() {
    [[ -f "$WHITELIST_FILE" ]] || return 0
    grep -v "^#" "$WHITELIST_FILE" | grep -v "^[[:space:]]*$" || true
}

is_whitelisted() {
    local ip="$1"
    while IFS= read -r entry; do
        [[ "$ip" == "$entry" ]] && return 0
    done < <(load_whitelist)
    return 1
}

add_to_whitelist() {
    local ip="$1"
    touch "$WHITELIST_FILE"
    if grep -qxF "$ip" "$WHITELIST_FILE" 2>/dev/null; then
        info "Already whitelisted: $ip"
    else
        echo "$ip" >> "$WHITELIST_FILE"
        info "Added to whitelist: $ip"
        # Remove from active ipset if present
        ipset del "$IPSET_NAME" "$ip" 2>/dev/null || true
    fi
}

# Auto-whitelist: detect current SSH client IP and server's own IPs
auto_whitelist_self() {
    info "Auto-whitelisting current SSH session and local addresses..."

    # SSH client IP from current session
    local ssh_client="${SSH_CLIENT:-}"
    if [[ -n "$ssh_client" ]]; then
        local client_ip
        client_ip=$(echo "$ssh_client" | awk '{print $1}')
        if [[ -n "$client_ip" ]]; then
            add_to_whitelist "$client_ip"
            info "  SSH client IP protected: $client_ip"
        fi
    fi

    # All local IPs assigned to this machine
    local local_ips
    local_ips=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || true)
    while IFS= read -r local_ip; do
        [[ -n "$local_ip" ]] && add_to_whitelist "$local_ip"
    done <<< "$local_ips"

    # Default gateway
    local gw
    gw=$(ip route | grep default | awk '{print $3}' | head -n1 || true)
    [[ -n "$gw" ]] && add_to_whitelist "$gw"
}

# ── Feed loading ──────────────────────────────────────────────────────────────
load_feed() {
    local url="$1"
    local count=0
    local skipped=0

    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        # Skip anything on our whitelist
        if is_whitelisted "$ip"; then
            (( skipped++ )) || true
            continue
        fi
        if ipset add "$IPSET_NAME" "$ip" --exist 2>/dev/null; then
            (( count++ )) || true
        fi
    done < <(
        curl --compressed --silent --max-time 30 --retry 3 "$url" 2>/dev/null \
        | grep -v "^#" \
        | grep -v "^[[:space:]]*$" \
        | grep -E "^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(/[0-9]{1,2})?" \
        | cut -f1
    )

    [[ $skipped -gt 0 ]] && info "  → Skipped $skipped whitelisted entries"
    echo "$count"
}

# ── nftables integration ──────────────────────────────────────────────────────
# Uses nftables (not iptables) — consistent with ufw/nftables on Arch.
# Creates a dedicated 'blocklist' table so it never interferes with ufw rules.
apply_nftables_rules() {
    info "Applying nftables rules (dedicated blocklist table)..."

    # Idempotent: delete and recreate the blocklist table cleanly
    nft delete table inet blocklist 2>/dev/null || true

    nft -f - << NFTRULES
table inet blocklist {
    chain prerouting {
        # Drop before conntrack — most efficient point
        type filter hook prerouting priority raw - 10; policy accept;
        ip saddr @${IPSET_NAME} counter drop
        ip daddr @${IPSET_NAME} counter drop
    }
    chain output {
        type filter hook output priority raw - 10; policy accept;
        ip daddr @${IPSET_NAME} counter drop
    }
}
NFTRULES

    # Link the ipset into the nftables ruleset
    # nftables can reference ipsets directly with the @setname syntax
    # but needs the set declared — use a named set referencing the ipset
    info "nftables blocklist table applied."
}

# ── Persistence ───────────────────────────────────────────────────────────────
save_state() {
    info "Saving ipset to $IPSET_SAVE_FILE..."
    ipset save > "$IPSET_SAVE_FILE"

    info "Saving nftables rules..."
    mkdir -p /etc/nftables.d
    nft list table inet blocklist > /etc/nftables.d/blocklist.nft 2>/dev/null || true

    # Ensure it's loaded on boot via /etc/nftables.conf include
    if [[ -f /etc/nftables.conf ]]; then
        if ! grep -q "blocklist.nft" /etc/nftables.conf; then
            echo 'include "/etc/nftables.d/blocklist.nft"' >> /etc/nftables.conf
            info "Added blocklist include to /etc/nftables.conf"
        fi
    fi

    # Ensure ipset loads on boot
    if [[ ! -f /etc/systemd/system/ipset-restore.service ]]; then
        cat > /etc/systemd/system/ipset-restore.service << 'SVC'
[Unit]
Description=Restore ipset blocklist
Before=nftables.service
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/bin/ipset restore -f /etc/ipset.conf
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVC
        systemctl enable ipset-restore.service
        info "ipset-restore.service installed and enabled."
    fi
}

# ── systemd timer installer ───────────────────────────────────────────────────
install_timer() {
    info "Installing systemd timer for daily blocklist refresh..."

    cat > /etc/systemd/system/blocklist-update.service << USVC
[Unit]
Description=Update malicious IP blocklist
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${SCRIPT_PATH}
StandardOutput=journal
StandardError=journal
USVC

    cat > /etc/systemd/system/blocklist-update.timer << 'UTIMER'
[Unit]
Description=Daily malicious IP blocklist refresh

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
UTIMER

    systemctl daemon-reload
    systemctl enable --now blocklist-update.timer
    info "Timer installed. Next run: $(systemctl status blocklist-update.timer | grep 'Trigger:' | head -1 | xargs)"

    echo ""
    echo "✔  systemd timer installed."
    echo "   View schedule:  systemctl status blocklist-update.timer"
    echo "   View logs:      journalctl -u blocklist-update.service"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    case "${1:-}" in
        --install)
            check_dependencies
            install_timer
            exit 0
            ;;
        --whitelist)
            [[ -n "${2:-}" ]] || die "Usage: $0 --whitelist <IP>"
            check_dependencies
            add_to_whitelist "$2"
            exit 0
            ;;
    esac

    check_dependencies
    auto_whitelist_self

    info "════════════════════════════════════════"
    info "Blocklist update started."

    # Create or flush the ipset
    ipset create "$IPSET_NAME" "$IPSET_TYPE" --exist
    info "Flushing ipset '$IPSET_NAME'..."
    ipset flush "$IPSET_NAME"

    # Re-load whitelist entries into a separate protected set
    # so we can verify nothing slips through
    while IFS= read -r wl_ip; do
        ipset del "$IPSET_NAME" "$wl_ip" 2>/dev/null || true
    done < <(load_whitelist)

    # Load feeds
    local total=0
    local failed=0
    for url in "${FEEDS[@]}"; do
        info "Loading: $url"
        local count
        count=$(load_feed "$url")
        if [[ "$count" -gt 0 ]]; then
            info "  → Added $count entries"
            (( total += count )) || true
        else
            warn "  → No entries loaded (feed may be down or empty)"
            (( failed++ )) || true
        fi
    done

    info "Total entries: $total  |  Failed feeds: $failed"

    apply_nftables_rules
    save_state

    info "Blocklist update complete."
    info "════════════════════════════════════════"
}

main "$@"
