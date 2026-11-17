#!/usr/bin/env bash
# Install Odoo 19 Community (official .deb repo) + PostgreSQL + wkhtmltopdf + Nginx reverse proxy.
# Usage: curl -fsSL .../install_odoo19.sh | sudo bash                       # access by IP over http
#        curl -fsSL .../install_odoo19.sh | sudo bash -s -- erp.example.com   # + Let's Encrypt SSL
# Targets Ubuntu 22.04 / 24.04. No password is stored here: the master password is generated.
set -euo pipefail

DOMAIN="${1:-}"
ODOO_CONF="/etc/odoo/odoo.conf"
DATA_DIR="/var/lib/odoo"
NGINX_SITE="/etc/nginx/sites-available/odoo"
PASS_FILE="/root/odoo-master-password.txt"
export DEBIAN_FRONTEND=noninteractive

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root (sudo)."
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "This script is for Ubuntu (found: ${ID:-unknown})."

# ---------- base packages + PostgreSQL ----------
log "Installing base packages and PostgreSQL"
apt-get update -y
apt-get install -y curl gnupg ca-certificates postgresql nginx openssl

if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='odoo'" | grep -q 1; then
    sudo -u postgres createuser -d -R -S odoo
fi

# ---------- Odoo 19 ----------
log "Adding the Odoo 19 repository"
curl -fsSL https://nightly.odoo.com/odoo.key | gpg --dearmor --yes -o /usr/share/keyrings/odoo-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/odoo-archive-keyring.gpg] https://nightly.odoo.com/19.0/nightly/deb/ ./" \
    > /etc/apt/sources.list.d/odoo.list
apt-get update -y
log "Installing Odoo 19 (large download)"
apt-get install -y odoo

# ---------- wkhtmltopdf (patched Qt, needed for PDF reports) ----------
if ! command -v wkhtmltopdf &>/dev/null; then
    log "Installing wkhtmltopdf"
    ARCH="$(dpkg --print-architecture)"
    WK_DEB="/tmp/wkhtmltox.deb"
    if curl -fsSL -o "$WK_DEB" \
        "https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.jammy_${ARCH}.deb" \
        && apt-get install -y "$WK_DEB"; then
        echo "Patched wkhtmltopdf installed."
    else
        echo "Patched build unavailable - falling back to Ubuntu's wkhtmltopdf."
        apt-get install -y wkhtmltopdf
    fi
    rm -f "$WK_DEB"
fi

# ---------- Odoo config ----------
log "Writing $ODOO_CONF"
mkdir -p "$DATA_DIR" /var/log/odoo
chown odoo: "$DATA_DIR" /var/log/odoo

if [[ -s "$PASS_FILE" ]]; then
    MASTER_PW="$(cat "$PASS_FILE")"
else
    MASTER_PW="$(openssl rand -base64 32 | tr -d '/+=' | cut -c1-24)"
    ( umask 077; printf '%s\n' "$MASTER_PW" > "$PASS_FILE" )
fi

CPUS="$(nproc)"
WORKERS=$(( CPUS * 2 + 1 ))
if (( WORKERS > 9 )); then WORKERS=9; fi

if [[ -f "$ODOO_CONF" ]]; then cp -a "$ODOO_CONF" "$ODOO_CONF.bak.$(date +%Y%m%d%H%M%S)"; fi
cat > "$ODOO_CONF" <<EOF
[options]
admin_passwd = $MASTER_PW
db_host = False
db_port = False
db_user = odoo
db_password = False
data_dir = $DATA_DIR
logfile = /var/log/odoo/odoo-server.log
http_interface = 127.0.0.1
http_port = 8069
gevent_port = 8072
proxy_mode = True
workers = $WORKERS
max_cron_threads = 1
limit_memory_soft = 2147483648
limit_memory_hard = 2684354560
limit_time_cpu = 600
limit_time_real = 1200
EOF
chown root:odoo "$ODOO_CONF"
chmod 640 "$ODOO_CONF"

systemctl enable odoo
systemctl restart odoo

# ---------- Nginx ----------
log "Configuring Nginx"
SERVER_NAME="${DOMAIN:-_}"
cat > "$NGINX_SITE" <<EOF
upstream odoo { server 127.0.0.1:8069; }
upstream odoochat { server 127.0.0.1:8072; }
map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }

server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name $SERVER_NAME;

    client_max_body_size 200M;
    proxy_read_timeout 720s;
    proxy_connect_timeout 720s;
    proxy_send_timeout 720s;

    access_log /var/log/nginx/odoo.access.log;
    error_log  /var/log/nginx/odoo.error.log;

    location /websocket {
        proxy_pass http://odoochat;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    location / {
        proxy_pass http://odoo;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_redirect off;
    }

    location ~* /web/static/ {
        expires 864000;
        proxy_pass http://odoo;
    }

    gzip on;
    gzip_types text/css text/plain application/json application/javascript text/xml;
}
EOF
ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/odoo
rm -f /etc/nginx/sites-enabled/default
nginx -t || die "nginx config test failed - not reloading. Check $NGINX_SITE."
systemctl enable nginx
systemctl reload nginx

# ---------- firewall ----------
if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    log "ufw active - allowing OpenSSH + HTTP/HTTPS"
    ufw allow OpenSSH
    ufw allow 'Nginx Full'
fi

# ---------- SSL (only when a domain was given) ----------
SCHEME="http"
if [[ -n "$DOMAIN" ]]; then
    log "Requesting Let's Encrypt certificate for $DOMAIN"
    apt-get install -y certbot python3-certbot-nginx
    if certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos \
        --register-unsafely-without-email --redirect; then
        SCHEME="https"
    else
        echo "certbot failed (does $DOMAIN point to this server?). Odoo still works over http." >&2
    fi
fi

# ---------- summary ----------
sleep 3
HOST="${DOMAIN:-$(hostname -I | awk '{print $1}')}"
log "Done"
echo "Odoo service:    $(systemctl is-active odoo || true)"
echo "Nginx service:   $(systemctl is-active nginx || true)"
echo "Open:            $SCHEME://$HOST"
echo "Master password: $MASTER_PW"
echo "  (saved in $PASS_FILE - needed to create/backup/restore databases)"
echo "Logs:            /var/log/odoo/odoo-server.log"
