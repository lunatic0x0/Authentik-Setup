#!/usr/bin/env bash
# bootstrap.sh — generates a .env for the local Authentik stack on macOS.
# Idempotent: re-running won't clobber an existing .env unless --force is passed.

set -euo pipefail

cd "$(dirname "$0")"

FORCE=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    -h|--help)
      cat <<EOF
Usage: ./bootstrap.sh [--force]
  --force   Overwrite an existing .env file
EOF
      exit 0 ;;
  esac
done

if [[ -f .env && $FORCE -eq 0 ]]; then
  echo "[!] .env already exists. Pass --force to regenerate."
  exit 1
fi

# Sanity check: docker present
if ! command -v docker >/dev/null 2>&1; then
  echo "[!] docker not found. Install Docker Desktop or OrbStack first."
  exit 1
fi

# openssl ships with macOS — generate two strong secrets
SECRET_KEY="$(openssl rand -base64 60 | tr -d '\n')"
PG_PASS="$(openssl rand -base64 36 | tr -d '\n=+/')"

cat > .env <<EOF
# ---- generated $(date -u +%Y-%m-%dT%H:%M:%SZ) ----
# Image tag — bump when newer Authentik releases ship.
# See: https://github.com/goauthentik/authentik/releases
AUTHENTIK_TAG=2024.10

# Postgres credentials (used by both Authentik and the Postgres container)
PG_USER=authentik
PG_DB=authentik
PG_PASS=${PG_PASS}

# Authentik global secret — rotates session tokens, signs cookies, etc.
AUTHENTIK_SECRET_KEY=${SECRET_KEY}

# Local listener ports — change if 9000/9443 collide on your laptop
COMPOSE_PORT_HTTP=9000
COMPOSE_PORT_HTTPS=9443

# Logging — "debug" is noisy but useful when you're writing detections.
# Options: trace | debug | info | warning | error
AUTHENTIK_LOG_LEVEL=info
EOF

chmod 600 .env
echo "[+] .env written."
echo "[+] Next steps:"
echo "    docker compose pull"
echo "    docker compose up -d"
echo "    open http://localhost:9000/if/flow/initial-setup/"
