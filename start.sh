#!/bin/sh
set -e

rand_secret() {
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32
}

DATA_DIR=/data
# Fixed internal listen ports — remap on the host via Docker's `ports:` if needed.
PORT=55555
VLESS_PORT=55556
TROJAN_PORT=55557
SNELL_PORT=55558
PASSWORD="${PASSWORD:-$(rand_secret)}"
WARP="${WARP:-false}"
# Cloudflare rate-limits WARP device registration (HTTP 429) and wgcf does not
# retry, so back off exponentially here. After the final attempt the script
# exits non-zero: the proxy is never served without WARP, and `restart: always`
# brings the container back after a delay rather than in a tight crash loop.
WARP_MAX_ATTEMPTS="${WARP_MAX_ATTEMPTS:-6}"
WARP_BACKOFF_SECONDS="${WARP_BACKOFF_SECONDS:-30}"
WARP_MAX_BACKOFF_SECONDS="${WARP_MAX_BACKOFF_SECONDS:-1800}"
# wgcf's device account lives in /tmp (ephemeral); persist a copy under /data so
# restarts reuse the same WARP device instead of registering a new one.
WGCF_ACCOUNT_PERSIST="$DATA_DIR/wgcf-account.toml"
# snell-server has no log config of its own, so its stdout goes to disk instead
# of `docker compose logs`. Capped at LOG_MAX_BYTES; on overflow the newest
# LOG_KEEP_BYTES are retained and the rest dropped.
LOG_FILE="$DATA_DIR/nexus.log"
LOG_MAX_BYTES=$((5 * 1024 * 1024))
LOG_KEEP_BYTES=$((2 * 1024 * 1024))
# Public IP for the share links. Detected here, before WARP comes up, so it's
# the server's real inbound address and not the WARP exit IP.
SERVER="$(wget -qO- -T 5 http://api.ipify.org 2>/dev/null || true)"

json_escape() {
  awk 'BEGIN {
    value = ARGV[1]
    ARGV[1] = ""
    gsub(/\\/, "\\\\", value)
    gsub(/"/, "\\\"", value)
    gsub(/\r/, "\\r", value)
    gsub(/\t/, "\\t", value)
    gsub(/\n/, "\\n", value)
    printf "%s", value
  }' "$1"
}

# Trim in place rather than renaming: snell-server's stdout is an append-mode fd
# from the `>>` redirect below, so its write offset follows the truncation and
# it keeps writing to the same inode.
rotate_logs() {
  size=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
  [ "$size" -gt "$LOG_MAX_BYTES" ] || return 0
  if ! tail -c "$LOG_KEEP_BYTES" "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null; then
    rm -f "$LOG_FILE.tmp"
    return 0
  fi
  cat "$LOG_FILE.tmp" > "$LOG_FILE"
  rm -f "$LOG_FILE.tmp"
}

log_rotator() {
  while :; do
    sleep 600
    rotate_logs
  done
}

warp_enabled() {
  case "$WARP" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

# Build warp.conf from the WARP account, retrying with exponential backoff
# because Cloudflare rate-limits these API calls (HTTP 429) and wgcf does not
# retry. A successful registration is persisted under /data so retries — and
# later container restarts — reuse the same device instead of registering a new
# one against the same rate limit.
build_warp_profile() {
  attempt=1
  delay=$WARP_BACKOFF_SECONDS
  while :; do
    if [ ! -f "$WGCF_ACCOUNT_PERSIST" ]; then
      echo "Registering WARP account (attempt ${attempt}/${WARP_MAX_ATTEMPTS})..."
      # wgcf refuses to overwrite an existing account, so clear partial state.
      rm -f /tmp/wgcf-account.toml /tmp/wgcf-profile.conf
      if (cd /tmp && wgcf register --accept-tos); then
        cp /tmp/wgcf-account.toml "$WGCF_ACCOUNT_PERSIST"
        chmod 600 "$WGCF_ACCOUNT_PERSIST"
      fi
    fi
    if [ -f "$WGCF_ACCOUNT_PERSIST" ]; then
      cp "$WGCF_ACCOUNT_PERSIST" /tmp/wgcf-account.toml
      if (cd /tmp && wgcf generate --profile /tmp/wgcf-profile.conf); then
        # Force IPv4 endpoint and set MTU
        sed -i 's|^[[:space:]]*Endpoint[[:space:]]*=.*|Endpoint = 162.159.192.1:2408|' /tmp/wgcf-profile.conf
        sed -i 's|^[[:space:]]*MTU[[:space:]]*=.*|MTU = 1280|' /tmp/wgcf-profile.conf
        cp /tmp/wgcf-profile.conf "$DATA_DIR/warp.conf"
        chmod 600 "$DATA_DIR/warp.conf"
        return 0
      fi
    fi
    if [ "$attempt" -ge "$WARP_MAX_ATTEMPTS" ]; then
      echo "[warp] failed to provision WARP after ${WARP_MAX_ATTEMPTS} attempts" >&2
      return 1
    fi
    echo "[warp] attempt ${attempt} failed, retrying in ${delay}s" >&2
    sleep "$delay"
    attempt=$((attempt + 1))
    delay=$((delay * 2))
    [ "$delay" -le "$WARP_MAX_BACKOFF_SECONDS" ] || delay=$WARP_MAX_BACKOFF_SECONDS
  done
}

setup_warp() {
  if [ ! -f "$DATA_DIR/warp.conf" ]; then
    build_warp_profile || return 1
  fi
  # wg-quick would rewrite resolv.conf via the DNS line; sing-box handles
  # its own DNS, so drop it and let the container resolver work normally.
  # Also sanitize any existing persisted config.
  sed -i '/^[[:space:]]*DNS[[:space:]]*=/d' "$DATA_DIR/warp.conf"
}

mkdir -p "$DATA_DIR"

if [ ! -f "$DATA_DIR/cert.pem" ]; then
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
    -keyout "$DATA_DIR/key.pem" -out "$DATA_DIR/cert.pem" \
    -days 3650 -nodes -subj "/CN=www.alibaba.com"
fi

if [ ! -f "$DATA_DIR/reality.env" ]; then
  VLESS_UUID=$(cat /proc/sys/kernel/random/uuid)
  REALITY_KEYS=$(sing-box generate reality-keypair)
  REALITY_PRIVATE=$(echo "$REALITY_KEYS" | awk '/PrivateKey/{print $2}')
  REALITY_PUBLIC=$(echo "$REALITY_KEYS" | awk '/PublicKey/{print $2}')
  REALITY_SHORT_ID=$(openssl rand -hex 8)
  cat > "$DATA_DIR/reality.env" << ENV
VLESS_UUID=${VLESS_UUID}
REALITY_PRIVATE=${REALITY_PRIVATE}
REALITY_PUBLIC=${REALITY_PUBLIC}
REALITY_SHORT_ID=${REALITY_SHORT_ID}
ENV
fi
. "$DATA_DIR/reality.env"

if warp_enabled; then
  if ! command -v wg-quick >/dev/null 2>&1; then
    echo "[warp] wg-quick not found — install wireguard-tools in the image" >&2
    exit 1
  fi
  if ! setup_warp; then
    echo "[warp] WARP unavailable — refusing to serve without it; exiting so Docker can retry" >&2
    exit 1
  fi
  if [ -f "$DATA_DIR/warp.conf" ]; then
    # Alpine disables IPv6 by default; wg-quick needs it for ::/0 AllowedIPs.
    sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1 || true
    wg-quick up "$DATA_DIR/warp.conf"
    # wg-quick routes public-IP destinations through WARP by default, which
    # breaks return traffic for inbound Docker-published connections. Ensure
    # packets originating from the container's eth0 address still use the
    # main routing table so responses to clients go back through Docker's bridge.
    if command -v ip >/dev/null 2>&1; then
      ETH0_IP=$(ip -4 -o addr show eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
      if [ -n "$ETH0_IP" ]; then
        ip rule add from "$ETH0_IP" lookup main pref 100 2>/dev/null || true
      fi
      ETH0_IP6=$(ip -6 -o addr show eth0 scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
      if [ -n "$ETH0_IP6" ]; then
        ip -6 rule add from "$ETH0_IP6" lookup main pref 100 2>/dev/null || true
      fi
    fi
    echo "[warp] enabled (system wg interface: warp)"
  fi
else
  echo "[warp] off"
fi

cat > "$DATA_DIR/config.json" << CONFIG
{
  "log": {
    "disabled": true
  },
  "dns": {
    "servers": [
      {
        "type": "local",
        "tag": "dns-upstream"
      }
    ],
    "rules": [
      {
        "server": "dns-upstream"
      }
    ],
    "strategy": "prefer_ipv6"
  },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "h2-in",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [
        {
          "password": "$(json_escape "$PASSWORD")"
        }
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "$DATA_DIR/cert.pem",
        "key_path": "$DATA_DIR/key.pem"
      }
    },
    {
      "type": "vless",
      "tag": "vless-reality-in",
      "listen": "::",
      "listen_port": ${VLESS_PORT},
      "users": [
        {
          "name": "default",
          "uuid": "${VLESS_UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "vspo.jp",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "vspo.jp",
            "server_port": 443
          },
          "private_key": "${REALITY_PRIVATE}",
          "short_id": ["${REALITY_SHORT_ID}"]
        }
      }
    },
    {
      "type": "trojan",
      "tag": "trojan-in",
      "listen": "::",
      "listen_port": ${TROJAN_PORT},
      "users": [
        {
          "name": "default",
          "password": "$(json_escape "$PASSWORD")"
        }
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "$DATA_DIR/cert.pem",
        "key_path": "$DATA_DIR/key.pem"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "default_domain_resolver": {
      "server": "dns-upstream",
      "strategy": "prefer_ipv6"
    },
    "final": "direct"
  }
}
CONFIG


echo "Server: ${SERVER}"
echo
echo "hysteria2://${PASSWORD}@${SERVER}:${PORT}?insecure=1&sni=www.alibaba.com#nexus-hy2"
echo "vless://${VLESS_UUID}@${SERVER}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=vspo.jp&fp=chrome&pbk=${REALITY_PUBLIC}&sid=${REALITY_SHORT_ID}&type=tcp#nexus-reality"
echo "trojan://${PASSWORD}@${SERVER}:${TROJAN_PORT}?security=tls&sni=www.alibaba.com&allowInsecure=1#nexus-trojan"

# snell-server is Surge-only and shares PASSWORD as its PSK; start it if present.
if [ -x /usr/local/bin/snell-server ]; then
  cat > "$DATA_DIR/snell-server.conf" << SNELL
[snell-server]
listen = :::${SNELL_PORT}
psk = ${PASSWORD}
ipv6 = true
SNELL
  /usr/local/bin/snell-server -c "$DATA_DIR/snell-server.conf" >> "$LOG_FILE" 2>&1 &
  echo "snell (Surge): nexus = snell, ${SERVER}, ${SNELL_PORT}, psk=${PASSWORD}, version=5"
else
  echo "snell: disabled (snell-server binary not found)"
fi

echo "snell logs: $LOG_FILE (capped at $((LOG_MAX_BYTES / 1024 / 1024))MB)"

rotate_logs
log_rotator &

exec sing-box run -c "$DATA_DIR/config.json"
