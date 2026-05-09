#!/bin/bash

set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin:$PATH"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

ok() { echo -e "${GREEN}[OK]${NC} $1"; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err() { echo -e "${RED}[ERR]${NC} $1"; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
    err "Please run as root"
fi

default_name="$(curl -4fsS https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')"
read -rp "Domain or public IP for HTTPS [$default_name]: " cert_name
cert_name=${cert_name:-$default_name}
[ -n "$cert_name" ] || err "Domain or IP is required"

read -rp "Email for Let's Encrypt notices [blank to skip]: " cert_email

if [[ "$cert_name" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    warn "Using an IP certificate. It requires Certbot 5.4.0+ and the certificate is short-lived."
else
    warn "After this, you must browse with this domain name. Using the IP URL will still show a certificate warning."
fi

warn "TCP port 80 must be open to this server during certificate issuance."

info "Installing Certbot..."
apt-get update >/dev/null 2>&1
DEBIAN_FRONTEND=noninteractive apt-get install -y snapd ca-certificates curl >/dev/null 2>&1
systemctl enable --now snapd.socket >/dev/null 2>&1 || true
snap wait system seed.loaded >/dev/null 2>&1 || true
snap install core >/dev/null 2>&1 || true
snap refresh core >/dev/null 2>&1 || true
snap install --classic certbot >/dev/null 2>&1 || snap refresh certbot >/dev/null 2>&1
ln -sf /snap/bin/certbot /usr/bin/certbot
certbot --version

nginx_was_active=0
if systemctl is-active --quiet nginx; then
    nginx_was_active=1
    info "Stopping nginx for HTTP validation..."
    systemctl stop nginx
fi

restart_nginx() {
    if [ "$nginx_was_active" = "1" ]; then
        systemctl start nginx >/dev/null 2>&1 || true
    fi
}
trap restart_nginx EXIT

email_args=(--register-unsafely-without-email)
if [ -n "$cert_email" ]; then
    email_args=(-m "$cert_email")
fi

info "Requesting certificate for $cert_name..."
certbot certonly \
    --standalone \
    --preferred-challenges http \
    -d "$cert_name" \
    --agree-tos \
    --non-interactive \
    "${email_args[@]}"

src_dir="/etc/letsencrypt/live/$cert_name"
[ -f "$src_dir/fullchain.pem" ] || err "Certificate was not created: $src_dir/fullchain.pem"
[ -f "$src_dir/privkey.pem" ] || err "Private key was not created: $src_dir/privkey.pem"

info "Installing certificate into lxdapi..."
mkdir -p /opt/lxdapi/certs
cp "$src_dir/fullchain.pem" /opt/lxdapi/certs/server.crt
cp "$src_dir/privkey.pem" /opt/lxdapi/certs/server.key
chmod 600 /opt/lxdapi/certs/server.key

hook="/etc/letsencrypt/renewal-hooks/deploy/lxdapi-cert.sh"
mkdir -p "$(dirname "$hook")"
cat > "$hook" <<EOF
#!/bin/bash
set -e
CERT_NAME="$cert_name"
cp "/etc/letsencrypt/live/\$CERT_NAME/fullchain.pem" /opt/lxdapi/certs/server.crt
cp "/etc/letsencrypt/live/\$CERT_NAME/privkey.pem" /opt/lxdapi/certs/server.key
chmod 600 /opt/lxdapi/certs/server.key
systemctl restart lxdapi
EOF
chmod +x "$hook"

systemctl restart lxdapi
ok "HTTPS certificate installed. Open: https://$cert_name:8443"
