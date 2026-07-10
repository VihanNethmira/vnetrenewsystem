#!/bin/bash
set -e

# ─────────────────────────────────────────────
#   CONFIGURATION
#   (kept separate from vnet_ledger so both systems
#    can run side-by-side on the same VPS)
# ─────────────────────────────────────────────
BACKEND_SERVICE="vnet_renewal_backend"
FRONTEND_SERVICE="vnet_renewal_frontend"
FOLDER="Renewal"
WORK_DIR="/root/$FOLDER"
BACKEND_PORT="8001"     # internal only, distinct from ledger's 8888
FRONTEND_PORT="3001"    # internal only
GITHUB_REPO="VihanNethmira/vnetrenewsystem"
GITHUB_API="https://api.github.com/repos/$GITHUB_REPO/releases"
ENV_FILE="/etc/vnet_renewal_backend.env"
NGINX_SITE="vnet_renewal"

# ─────────────────────────────────────────────
#   HELPER FUNCTIONS
# ─────────────────────────────────────────────

print_header() {
    clear
    echo "================================================"
    echo "   VNET SHOP - RENEWAL SYSTEM DEPLOYMENT TOOL"
    echo "   Repo : github.com/$GITHUB_REPO"
    echo "   OS   : Ubuntu  |  Backend: $BACKEND_PORT (internal)  |  Frontend: $FRONTEND_PORT (internal)"
    echo "   NOTE : Runs alongside vnet_ledger on this server."
    echo "================================================"
}

select_release() {
    echo ""
    echo "Fetching available releases from GitHub..."

    RELEASE_JSON=$(curl -s "$GITHUB_API")

    mapfile -t TAGS < <(echo "$RELEASE_JSON" | grep -o '"tag_name": *"[^"]*"' | sed 's/"tag_name": *"//;s/"//')
    mapfile -t ZIPS < <(echo "$RELEASE_JSON" | grep -o '"browser_download_url": *"[^"]*\.zip"' | sed 's/"browser_download_url": *"//;s/"//')

    if [ ${#TAGS[@]} -eq 0 ]; then
        echo "ERROR: No releases found for $GITHUB_REPO."
        echo "Publish a release with a .zip asset (containing backend/ and frontend/) first."
        exit 1
    fi

    echo ""
    echo "Available releases:"
    for i in "${!TAGS[@]}"; do
        if [ -n "${ZIPS[$i]}" ]; then
            echo "  $((i+1)). ${TAGS[$i]}  [$(basename "${ZIPS[$i]}") ready]"
        else
            echo "  $((i+1)). ${TAGS[$i]}  (no zip asset)"
        fi
    done
    echo ""
    read -p "Select release [1-${#TAGS[@]}]: " REL_NUM

    if ! [[ "$REL_NUM" =~ ^[0-9]+$ ]] || [ "$REL_NUM" -lt 1 ] || [ "$REL_NUM" -gt ${#TAGS[@]} ]; then
        echo "ERROR: Invalid selection."
        exit 1
    fi

    SELECTED_TAG="${TAGS[$((REL_NUM-1))]}"
    SELECTED_ZIP="${ZIPS[$((REL_NUM-1))]}"

    if [ -z "$SELECTED_ZIP" ]; then
        echo "ERROR: Release '${SELECTED_TAG}' has no .zip asset."
        exit 1
    fi

    echo ""
    echo "  → Release : $SELECTED_TAG"
    echo "  → Asset   : $SELECTED_ZIP"
    echo ""
}

# Read backend config (3x-UI creds, admin token, telegram) and write/update the env file
configure_backend_env() {
    echo ""
    echo "── Backend Configuration (3x-UI / Admin / Telegram) ────"

    if [ -f "$ENV_FILE" ]; then
        CUR_XUI_URL=$(grep -oP '(?<=^XUI_BASE_URL=).*'    "$ENV_FILE" || true)
        CUR_XUI_USER=$(grep -oP '(?<=^XUI_USERNAME=).*'   "$ENV_FILE" || true)
        CUR_XUI_PASS=$(grep -oP '(?<=^XUI_PASSWORD=).*'   "$ENV_FILE" || true)
        CUR_ADMIN_TOKEN=$(grep -oP '(?<=^ADMIN_API_TOKEN=).*' "$ENV_FILE" || true)
        CUR_TG_TOKEN=$(grep -oP '(?<=^TELEGRAM_BOT_TOKEN=).*' "$ENV_FILE" || true)
        CUR_TG_CHAT=$(grep -oP '(?<=^TELEGRAM_CHAT_ID=).*'    "$ENV_FILE" || true)
        # FIX: this was referenced below but never actually read from the file,
        # so every re-run of this function generated a brand new Flask secret
        # key and silently invalidated all existing sessions/cookies.
        CUR_FLASK_SECRET=$(grep -oP '(?<=^FLASK_SECRET_KEY=).*' "$ENV_FILE" || true)
        echo "  (Press Enter on any field to keep its current value)"
    fi

    read -p "  3x-UI panel URL (e.g. https://your-vps-ip:2053) [${CUR_XUI_URL:-none}]: " IN_XUI_URL
    read -p "  3x-UI admin username [${CUR_XUI_USER:-admin}]: " IN_XUI_USER
    read -sp "  3x-UI admin password [keep current if blank]: " IN_XUI_PASS; echo ""
    read -p "  Admin API token for this dashboard [blank = keep/auto-generate]: " IN_ADMIN_TOKEN
    read -p "  Telegram Bot Token (optional, leave blank to skip/keep): " IN_TG_TOKEN
    read -p "  Telegram Chat ID   (optional, leave blank to skip/keep): " IN_TG_CHAT
    read -p "  Max upload size in MB [5]: " IN_MAX_MB

    XUI_BASE_URL="${IN_XUI_URL:-$CUR_XUI_URL}"
    XUI_USERNAME="${IN_XUI_USER:-${CUR_XUI_USER:-admin}}"
    XUI_PASSWORD="${IN_XUI_PASS:-$CUR_XUI_PASS}"
    ADMIN_API_TOKEN="${IN_ADMIN_TOKEN:-${CUR_ADMIN_TOKEN:-$(openssl rand -hex 24)}}"
    TELEGRAM_BOT_TOKEN="${IN_TG_TOKEN:-$CUR_TG_TOKEN}"
    TELEGRAM_CHAT_ID="${IN_TG_CHAT:-$CUR_TG_CHAT}"
    MAX_UPLOAD_MB="${IN_MAX_MB:-5}"
    FLASK_SECRET_KEY="${CUR_FLASK_SECRET:-$(openssl rand -hex 32)}"

    if [ -z "$XUI_BASE_URL" ]; then
        echo "  WARNING: XUI_BASE_URL is empty. The backend will likely fail to reach 3x-UI"
        echo "           and every renewal/panel-dependent request may error out."
    fi

    cat <<EOF | sudo tee "$ENV_FILE" > /dev/null
XUI_BASE_URL=$XUI_BASE_URL
XUI_USERNAME=$XUI_USERNAME
XUI_PASSWORD=$XUI_PASSWORD
XUI_VERIFY_SSL=False
ADMIN_API_TOKEN=$ADMIN_API_TOKEN
FRONTEND_ORIGIN=https://$DOMAIN
TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
TELEGRAM_CHAT_ID=$TELEGRAM_CHAT_ID
MAX_UPLOAD_MB=$MAX_UPLOAD_MB
FLASK_SECRET_KEY=$FLASK_SECRET_KEY
EOF
    sudo chmod 600 "$ENV_FILE"

    echo ""
    echo "  → Admin dashboard token: $ADMIN_API_TOKEN"
    echo "    (enter this on https://$DOMAIN/admin — save it somewhere safe)"
    if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
        echo "  → Telegram notifications configured."
    else
        echo "  → Telegram not configured. Skipping notifications."
    fi
}

install_node_if_needed() {
    if command -v node >/dev/null 2>&1; then
        NODE_MAJOR=$(node -v | sed 's/v//' | cut -d. -f1)
        if [ "$NODE_MAJOR" -ge 18 ]; then
            echo "  → Node.js $(node -v) already installed, skipping."
            return
        fi
    fi
    echo "  → Installing Node.js 20.x (NodeSource)..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
    sudo apt-get install -y nodejs
}

# FIX (new): actually verify the backend is reachable end-to-end through Nginx,
# instead of trusting `systemctl is-active` (which reports "active" even when
# gunicorn is crash-looping, because Restart=always brings it back up instantly
# between checks). Retries for a few seconds since services can be slow to bind.
check_backend_reachable() {
    local url="https://${DOMAIN}:${PORT}/api/health"
    local attempt=1
    local max_attempts=10
    echo "  → Checking backend reachability at $url ..."
    while [ $attempt -le $max_attempts ]; do
        HTTP_CODE=$(curl -sk -o /tmp/backend_health_body -w "%{http_code}" "$url" --max-time 5 || echo "000")
        if [ "$HTTP_CODE" != "000" ] && [ "$HTTP_CODE" -lt 500 ]; then
            echo "  → Backend responded with HTTP $HTTP_CODE (attempt $attempt/$max_attempts)."
            return 0
        fi
        echo "  → Attempt $attempt/$max_attempts: got HTTP ${HTTP_CODE:-no response}, retrying..."
        attempt=$((attempt+1))
        sleep 2
    done
    echo "  → WARNING: backend did not respond successfully after $max_attempts attempts."
    echo "    Last response body:"
    cat /tmp/backend_health_body 2>/dev/null || echo "    (no body / connection failed)"
    return 1
}

# ─────────────────────────────────────────────
#   MAIN MENU
# ─────────────────────────────────────────────

print_header
echo "1. Full Install (Download Release)"
echo "2. Update (Switch / Re-deploy Release)"
echo "3. Update Backend Settings (3x-UI / Admin Token / Telegram)"
echo "4. Uninstall / Remove System"
echo "5. Check Service Status"
echo "6. Exit"
echo ""
read -p "Choose an option (1-6): " MAIN_OPT

# ─────────────────────────────────────────────
#   1 & 2 — INSTALL / UPDATE
# ─────────────────────────────────────────────

if [ "$MAIN_OPT" == "1" ] || [ "$MAIN_OPT" == "2" ]; then

    read -p "Enter Renewal System Domain (e.g., renew.vnet.store): " DOMAIN
    echo "  (Note: 80, 443, 2096, 8443, 5000 are already used by 3x-ui/ledger on this server)"
    read -p "Enter Nginx external port [8444]: " PORT
    PORT="${PORT:-8444}"

    select_release
    configure_backend_env

    # ── Dependencies ──────────────────────────────
    echo "[1/7] Installing system dependencies..."
    sudo apt-get update -qq
    sudo apt-get install -y python3-pip python3-venv nginx certbot python3-certbot-nginx curl unzip rsync openssl
    install_node_if_needed

    # ── Download Release Asset ─────────────────────
    ZIP_PATH="/tmp/${FOLDER}_release.zip"
    EXTRACT_TMP="/tmp/${FOLDER}_extract"

    echo "[2/7] Downloading release asset ($SELECTED_TAG)..."
    curl -fsSL -L -o "$ZIP_PATH" "$SELECTED_ZIP"

    echo "[3/7] Extracting..."
    rm -rf "$EXTRACT_TMP"
    mkdir -p "$EXTRACT_TMP"
    unzip -q "$ZIP_PATH" -d "$EXTRACT_TMP"

    # ── Detect backend & frontend folders regardless of wrapping ──
    APP_FILE=$(find "$EXTRACT_TMP" -name "app.py" | head -n 1)
    if [ -z "$APP_FILE" ]; then
        echo "ERROR: backend/app.py not found inside the release zip."
        exit 1
    fi
    BACKEND_SRC=$(dirname "$APP_FILE")

    FRONTEND_PKG=$(find "$EXTRACT_TMP" -name "package.json" -not -path "*/node_modules/*" | head -n 1)
    if [ -z "$FRONTEND_PKG" ]; then
        echo "ERROR: frontend/package.json not found inside the release zip."
        exit 1
    fi
    FRONTEND_SRC=$(dirname "$FRONTEND_PKG")

    echo "  → backend found at : $BACKEND_SRC"
    echo "  → frontend found at: $FRONTEND_SRC"

    # ── Stop services before touching files ────────
    sudo systemctl stop "$BACKEND_SERVICE" 2>/dev/null || true
    sudo systemctl stop "$FRONTEND_SERVICE" 2>/dev/null || true

    # ── Deploy: sync files, preserve venv / db / node_modules / .next on update ──
    mkdir -p "$WORK_DIR/backend" "$WORK_DIR/frontend"

    rsync -a --delete \
        --exclude='venv/' \
        --exclude='uploads/' \
        --exclude='*.db' \
        --exclude='*.sqlite' \
        --exclude='*.sqlite3' \
        "$BACKEND_SRC/" "$WORK_DIR/backend/"

    rsync -a --delete \
        --exclude='node_modules/' \
        --exclude='.next/' \
        "$FRONTEND_SRC/" "$WORK_DIR/frontend/"

    mkdir -p "$WORK_DIR/backend/uploads"
    echo "  → Files deployed to $WORK_DIR"
    rm -rf "$ZIP_PATH" "$EXTRACT_TMP"

    # ── Python Virtual Environment ─────────────────
    echo "[4/7] Setting up Python environment..."
    python3 -m venv "$WORK_DIR/backend/venv"
    source "$WORK_DIR/backend/venv/bin/activate"

    if [ -f "$WORK_DIR/backend/requirements.txt" ]; then
        pip install -q -r "$WORK_DIR/backend/requirements.txt"
    else
        pip install -q flask flask-sqlalchemy flask-cors requests python-dotenv werkzeug
    fi
    pip install -q gunicorn

    echo "  → Verifying app.py loads..."
    cd "$WORK_DIR/backend"
    # FIX: previously any import error was swallowed with a generic message.
    # Now the real Python traceback is printed so the actual cause (missing
    # dependency, bad import, syntax error, etc.) is visible immediately.
    if ! python3 -c "import app"; then
        echo "ERROR: app.py failed to import. See traceback above for the exact cause."
        deactivate
        exit 1
    fi
    echo "  → app.py OK"
    deactivate

    # ── Frontend build ─────────────────────────────
    echo "[5/7] Building frontend (Next.js)..."
    # NEXT_PUBLIC_* vars are baked in at build time, so write them before building.
    # NOTE: no trailing /api here — the frontend code (page.js, admin/page.js)
    # already appends /api/... itself. Adding it here caused every request to
    # hit /api/api/... (404 -> HTML response -> res.json() throws -> caught
    # as "Could not reach the server.").
    cat <<EOF > "$WORK_DIR/frontend/.env.production"
NEXT_PUBLIC_API_URL=https://$DOMAIN:$PORT
EOF
    cd "$WORK_DIR/frontend"
    npm install --no-audit --no-fund
    npm run build

    # ── Systemd Services ────────────────────────────
    echo "[6/7] Configuring systemd services..."
    cat <<EOF | sudo tee /etc/systemd/system/${BACKEND_SERVICE}.service > /dev/null
[Unit]
Description=Gunicorn - VNET Renewal Backend $SELECTED_TAG
After=network.target

[Service]
User=root
WorkingDirectory=$WORK_DIR/backend
EnvironmentFile=$ENV_FILE
ExecStart=$WORK_DIR/backend/venv/bin/gunicorn --workers 2 --bind 127.0.0.1:$BACKEND_PORT app:app
Restart=always
RestartSec=5
Environment="RELEASE=$SELECTED_TAG"

[Install]
WantedBy=multi-user.target
EOF

    cat <<EOF | sudo tee /etc/systemd/system/${FRONTEND_SERVICE}.service > /dev/null
[Unit]
Description=Next.js - VNET Renewal Frontend $SELECTED_TAG
After=network.target

[Service]
User=root
WorkingDirectory=$WORK_DIR/frontend
ExecStart=$(command -v npm) run start -- -p $FRONTEND_PORT
Restart=always
RestartSec=5
Environment="NODE_ENV=production"
Environment="RELEASE=$SELECTED_TAG"

[Install]
WantedBy=multi-user.target
EOF

    # ── SSL ────────────────────────────────────────
    echo "[7/7] Configuring SSL & Nginx..."

    if [ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
        echo ""
        echo "  ── SSL Certificate (DNS Challenge) ──────────────"
        echo "  Certbot will ask you to add a DNS TXT record."
        echo "  Add it at your DNS provider, then press Enter to continue."
        echo "  This does NOT touch ports 80/443, safe alongside 3x-ui/ledger."
        echo "  ─────────────────────────────────────────────────"
        sudo certbot certonly --manual \
            --preferred-challenges dns \
            -d "$DOMAIN" \
            --agree-tos \
            --register-unsafely-without-email
    else
        echo "  → SSL cert already exists for $DOMAIN, skipping certbot."
    fi

    if [ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
        echo "ERROR: SSL certificate still missing for $DOMAIN after certbot step."
        echo "       Nginx will fail to start without it. Re-run certbot manually, then re-run this script."
        exit 1
    fi

    # ── Nginx Config ───────────────────────────────
    # Frontend (Next.js) serves everything by default;
    # /api/ is proxied straight to the Flask backend (routes already include /api prefix).
    cat <<EOF | sudo tee /etc/nginx/sites-available/${NGINX_SITE} > /dev/null
server {
    listen $PORT ssl;
    server_name $DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    client_max_body_size 50M;

    location /api/ {
        proxy_pass         http://127.0.0.1:$BACKEND_PORT;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_read_timeout 120;
        proxy_intercept_errors off;
    }

    location / {
        proxy_pass         http://127.0.0.1:$FRONTEND_PORT;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_read_timeout 120;
    }
}
EOF

    sudo ln -sf /etc/nginx/sites-available/"$NGINX_SITE" /etc/nginx/sites-enabled/"$NGINX_SITE"
    # NOTE: does not remove /etc/nginx/sites-enabled/default or any ledger config —
    # this is meant to sit alongside the ledger system's nginx site.
    sudo nginx -t

    # ── Start Everything ───────────────────────────
    sudo systemctl daemon-reload
    sudo systemctl enable "$BACKEND_SERVICE" "$FRONTEND_SERVICE"
    sudo systemctl restart "$BACKEND_SERVICE"
    sudo systemctl restart "$FRONTEND_SERVICE"
    sudo systemctl restart nginx

    # ── Firewall ───────────────────────────────────
    sudo ufw allow "$PORT"/tcp 2>/dev/null || true
    sudo ufw reload 2>/dev/null || true

    # ── Final health check ─────────────────────────
    sleep 3
    BACKEND_OK=false; FRONTEND_OK=false
    sudo systemctl is-active --quiet "$BACKEND_SERVICE" && BACKEND_OK=true
    sudo systemctl is-active --quiet "$FRONTEND_SERVICE" && FRONTEND_OK=true

    echo ""
    echo "================================================"
    if $BACKEND_OK && $FRONTEND_OK; then
        # FIX: process being "active" doesn't mean it's actually reachable.
        # Do a real HTTP check through Nginx before declaring success.
        if check_backend_reachable; then
            echo "  SUCCESS: Renewal system $SELECTED_TAG is live!"
            echo "  URL         : https://$DOMAIN:$PORT"
            echo "  Admin panel : https://$DOMAIN:$PORT/admin"
        else
            echo "  WARNING: Services are active, but the backend did not respond over HTTPS."
            echo "  Most likely causes:"
            echo "   - app.py crashing after startup (check: sudo journalctl -u $BACKEND_SERVICE -n 50)"
            echo "   - wrong/missing XUI_BASE_URL causing startup failure"
            echo "   - DNS for $DOMAIN not pointing at this server yet"
            echo "   - firewall/security group blocking port $PORT externally"
        fi
    else
        echo "  WARNING: One or more services may not have started correctly."
        $BACKEND_OK  || echo "   - backend  : run journalctl -u $BACKEND_SERVICE -n 30"
        $FRONTEND_OK || echo "   - frontend : run journalctl -u $FRONTEND_SERVICE -n 30"
    fi
    echo "================================================"

# ─────────────────────────────────────────────
#   3 — UPDATE BACKEND SETTINGS ONLY
# ─────────────────────────────────────────────

elif [ "$MAIN_OPT" == "3" ]; then

    read -p "Enter Renewal System Domain (used for FRONTEND_ORIGIN, e.g., renew.vnet.store): " DOMAIN

    configure_backend_env

    sudo systemctl restart "$BACKEND_SERVICE" 2>/dev/null || true
    sleep 2

    if sudo systemctl is-active --quiet "$BACKEND_SERVICE"; then
        echo ""
        echo "================================================"
        echo "  Backend settings updated & service restarted."
        echo "================================================"
    else
        echo ""
        echo "================================================"
        echo "  WARNING: backend failed to come back up after restart."
        echo "  Check: sudo journalctl -u $BACKEND_SERVICE -n 50"
        echo "================================================"
    fi

# ─────────────────────────────────────────────
#   4 — UNINSTALL
# ─────────────────────────────────────────────

elif [ "$MAIN_OPT" == "4" ]; then
    read -p "Enter the Nginx external port to close [8444]: " UN_PORT
    UN_PORT="${UN_PORT:-8444}"

    echo "Removing VNET Renewal system..."
    sudo systemctl stop "$BACKEND_SERVICE" "$FRONTEND_SERVICE" 2>/dev/null || true
    sudo systemctl disable "$BACKEND_SERVICE" "$FRONTEND_SERVICE" 2>/dev/null || true
    sudo rm -f /etc/systemd/system/"$BACKEND_SERVICE".service
    sudo rm -f /etc/systemd/system/"$FRONTEND_SERVICE".service
    sudo rm -f "$ENV_FILE"
    sudo systemctl daemon-reload

    sudo rm -f /etc/nginx/sites-enabled/"$NGINX_SITE"
    sudo rm -f /etc/nginx/sites-available/"$NGINX_SITE"
    sudo nginx -t && sudo systemctl restart nginx

    sudo ufw delete allow "$UN_PORT"/tcp 2>/dev/null || true
    sudo ufw reload 2>/dev/null || true

    read -p "Delete app files in $WORK_DIR (includes uploads/db)? (y/n): " DEL_FOLD
    if [ "$DEL_FOLD" == "y" ]; then
        sudo rm -rf "$WORK_DIR"
        echo "Folder deleted."
    fi
    echo "Uninstall complete. (vnet_ledger system, if present, was not touched.)"

# ─────────────────────────────────────────────
#   5 — STATUS
# ─────────────────────────────────────────────

elif [ "$MAIN_OPT" == "5" ]; then
    echo ""
    echo "── Backend Service ─────────────────────────────"
    sudo systemctl status "$BACKEND_SERVICE" --no-pager || true
    echo ""
    echo "── Backend Logs (last 20) ──────────────────────"
    sudo journalctl -u "$BACKEND_SERVICE" -n 20 --no-pager || true
    echo ""
    echo "── Frontend Service ────────────────────────────"
    sudo systemctl status "$FRONTEND_SERVICE" --no-pager || true
    echo ""
    echo "── Frontend Logs (last 20) ─────────────────────"
    sudo journalctl -u "$FRONTEND_SERVICE" -n 20 --no-pager || true
    echo ""
    echo "── Backend Env (secrets redacted) ──────────────"
    if [ -f "$ENV_FILE" ]; then
        grep -vE 'PASSWORD|TOKEN|SECRET' "$ENV_FILE" || true
    else
        echo "  (no env file found)"
    fi
    echo ""
    echo "── Nginx ───────────────────────────────────────"
    sudo systemctl status nginx --no-pager || true
    echo ""
    echo "── Firewall ────────────────────────────────────"
    sudo ufw status | grep ALLOW || echo "(UFW not active or no rules)"
    echo "────────────────────────────────────────────────"

else
    echo "Exiting."
    exit 0
fi
