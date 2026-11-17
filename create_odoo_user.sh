#!/usr/bin/env bash
# Create (or fix) the "odoo" user on Ubuntu: bash shell, home dir, full sudo, SSH login.
# Usage: sudo bash create_odoo_user.sh ["ssh-ed25519 AAAA... comment"]
# No password is stored here: you are prompted by passwd at run time.
set -euo pipefail

USER_NAME="odoo"
PUBKEY="${1:-}"
SUDOERS_FILE="/etc/sudoers.d/90-odoo"
SSHD_MAIN="/etc/ssh/sshd_config"
SSHD_DROPIN="/etc/ssh/sshd_config.d/10-odoo-user.conf"
CLOUD_INIT_CONF="/etc/ssh/sshd_config.d/50-cloud-init.conf"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root (sudo bash $0)."

# ---------- 1. user ----------
if id "$USER_NAME" &>/dev/null; then
    log "User $USER_NAME exists - updating it"
    usermod -s /bin/bash "$USER_NAME"
    HOME_DIR="$(getent passwd "$USER_NAME" | cut -d: -f6)"
    if [[ -z "$HOME_DIR" || "$HOME_DIR" == "/" || "$HOME_DIR" == "/nonexistent" ]]; then
        HOME_DIR="/home/$USER_NAME"
        usermod -d "$HOME_DIR" "$USER_NAME"
    fi
    if [[ ! -d "$HOME_DIR" ]]; then
        mkdir -p "$HOME_DIR"
        cp -rT /etc/skel "$HOME_DIR" 2>/dev/null || true
    fi
    chown "$USER_NAME:" "$HOME_DIR"
else
    log "Creating user $USER_NAME"
    useradd -m -s /bin/bash "$USER_NAME"
    HOME_DIR="/home/$USER_NAME"
fi

# ---------- 2. sudo ----------
log "Granting sudo"
usermod -aG sudo "$USER_NAME"
printf '%s ALL=(ALL:ALL) NOPASSWD:ALL\n' "$USER_NAME" > "$SUDOERS_FILE"
chmod 0440 "$SUDOERS_FILE"
if ! visudo -cf "$SUDOERS_FILE"; then
    rm -f "$SUDOERS_FILE"
    die "sudoers file invalid - removed it."
fi

# ---------- 3. password ----------
log "Set the password for $USER_NAME"
# Read from the terminal, not stdin: stdin is the script itself under "curl ... | sudo bash".
[[ -r /dev/tty ]] || die "No terminal available to ask for the password."
until passwd "$USER_NAME" < /dev/tty; do echo "Try again."; done

# ---------- 4. SSH ----------
if ! command -v sshd &>/dev/null && [[ ! -x /usr/sbin/sshd ]]; then
    log "Installing openssh-server"
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server
fi

log "Preparing ~/.ssh"
SSH_DIR="$HOME_DIR/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"
mkdir -p "$SSH_DIR"
touch "$AUTH_KEYS"
if [[ -n "$PUBKEY" ]]; then
    if grep -qxF "$PUBKEY" "$AUTH_KEYS"; then
        echo "Public key already present."
    else
        printf '%s\n' "$PUBKEY" >> "$AUTH_KEYS"
        echo "Public key added."
    fi
fi
chmod 700 "$SSH_DIR"
chmod 600 "$AUTH_KEYS"
chown -R "$USER_NAME:" "$SSH_DIR"

log "Configuring sshd"
BACKUP="$SSHD_MAIN.bak.$(date +%Y%m%d%H%M%S)"
cp -a "$SSHD_MAIN" "$BACKUP"
echo "Backup: $BACKUP"

mkdir -p /etc/ssh/sshd_config.d
cat > "$SSHD_DROPIN" <<'EOF'
# Added by create_odoo_user.sh
PasswordAuthentication yes
PubkeyAuthentication yes
EOF

if [[ -f "$CLOUD_INIT_CONF" ]] && grep -qiE '^\s*PasswordAuthentication\s+no' "$CLOUD_INIT_CONF"; then
    cp -a "$CLOUD_INIT_CONF" "$CLOUD_INIT_CONF.bak.$(date +%Y%m%d%H%M%S)"
    sed -i -E 's/^\s*PasswordAuthentication\s+no/PasswordAuthentication yes/I' "$CLOUD_INIT_CONF"
    echo "50-cloud-init.conf: PasswordAuthentication -> yes"
fi

if grep -qE '^\s*AllowUsers\s' "$SSHD_MAIN"; then
    if ! grep -qE "^\s*AllowUsers\s.*\b$USER_NAME\b" "$SSHD_MAIN"; then
        sed -i -E "s/^(\s*AllowUsers\s.*)$/\1 $USER_NAME/" "$SSHD_MAIN"
        echo "Added $USER_NAME to AllowUsers"
    fi
fi

mkdir -p /run/sshd
if sshd -t; then
    log "sshd config OK - restarting ssh"
    systemctl restart ssh 2>/dev/null || systemctl restart sshd
else
    echo "sshd -t FAILED - ssh NOT restarted. Restoring $SSHD_MAIN from backup." >&2
    cp -a "$BACKUP" "$SSHD_MAIN"
    die "Fix the sshd configuration manually (drop-in: $SSHD_DROPIN)."
fi

# ---------- 5. firewall ----------
if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    log "ufw active - allowing OpenSSH"
    ufw allow OpenSSH
fi

# ---------- 6. summary ----------
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
log "Done"
echo "User:   $USER_NAME"
echo "Groups: $(id -nG "$USER_NAME")"
echo "Login:  ssh $USER_NAME@${IP:-<server-ip>}"
