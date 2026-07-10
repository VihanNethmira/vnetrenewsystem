#!/bin/bash
set -e

# --- CONFIGURATION ---
WORK_DIR="/root/vnet"
BACKEND_DIR="$WORK_DIR/backend"
FRONTEND_DIR="$WORK_DIR/frontend"

# ─────────────────────────────────────────────
#   HELPER FUNCTIONS
# ─────────────────────────────────────────────

print_header() {
    clear
    echo "================================================"
    echo "   VNET VPN RENEWAL - AUTO DEPLOYMENT TOOL"
    echo "   Frontend : Next.js (Port 3000)"
    echo "   Backend  : Flask   (Port 5000)"
    echo "================================================"
}

configure_env() {
    echo ""
    echo "── Environment Configuration ────────────────────"
    read -p "Enter Domain Name (e.g., renew.vnet.com): " DOMAIN
    read -p "Enter 3x-UI Panel URL (e.g., http://1.1.1.1:2053): " XUI_BASE_URL
    read -p "Enter 3x-UI Username: " XUI_USERNAME
    read -p "Enter 3x-UI Password: " XUI_PASSWORD
    read -p "Enter Telegram Bot Token: " TELEGRAM_BOT_TOKEN
    read -p "Enter Telegram Chat ID: " TELEGRAM_CHAT_ID

    # Create Backend .env
    cat <<EOF > "$BACKEND_DIR/.env"
XUI_BASE_URL=$XUI_BASE_URL
XUI_USERNAME=$XUI_USERNAME
XUI_PASSWORD=$XUI_PASSWORD
XUI_VERIFY_SSL=False
ADMIN_API_TOKEN=vnet_admin_secret_123
FRONTEND_ORIGIN=https://$DOMAIN
TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
TELEGRAM_CHAT_ID=$TELEGRAM_CHAT_ID
EOF

    # Create Frontend .env
    cat <<EOF > "$FRONTEND_DIR/.env"
NEXT_PUBLIC_API_URL=https://$DOMAIN
EOF
    echo "  → Environment variables saved!"
}

# ─────────────────────────────────────────────
#   MAIN MENU
# ─────────────────────────────────────────────

print_header
echo "1. Full Install & Deploy"
echo "2. Update / Re-Build (After uploading new files)"
echo "3. Check System Status"
echo "4. Exit"
echo ""
read -p "Choose an option (1-4): " MAIN_OPT

if [ "$MAIN_OPT" == "1" ]; then
    if [ ! -d "$BACKEND_DIR" ] || [ ! -d "$FRONTEND_DIR" ]; then
        echo "ERROR: Please upload 'backend' and 'frontend' folders to $WORK_DIR first."
        exit 1
    fi

    configure_env

    echo "[1/6] Installing system dependencies..."
    sudo apt update -qq
    sudo apt install -y python3-pip python3-venv nodejs npm nginx certbot python3-certbot-nginx curl
    sudo npm install -g pm2

    echo "[2/6] Setting up Backend (Flask)..."
    cd "$BACKEND_DIR"
    python3 -m venv venv
    source venv/bin/activate
    pip install -q -r requirements.txt
    pip install -q gunicorn
    pm2 delete vnet-backend 2>/dev/null || true
    pm2 start "gunicorn -w 2 -b 127.0.0.1:5000 app:app" --name "vnet-backend"

    echo "[3/6] Setting up Frontend (Next.js)..."
    cd "$FRONTEND_DIR"
    npm install
    npm run build
    pm2 delete vnet-frontend 2>/dev/null || true
    pm2 start npm --name "vnet-frontend" -- start

    echo "[4/6] Saving PM2 to auto-start on reboot..."
    pm2 save
    env PATH=$PATH:/usr/bin /usr/local/lib/node_modules/pm2/bin/pm2 startup systemd -u root --hp /root || true

    echo "[5/6] Configuring Nginx Reverse Proxy..."
    cat <<EOF | sudo tee /etc/nginx/sites-available/vnet_renewal > /dev/null
server {
    listen 80;
    server_name $DOMAIN;
    client_max_body_size 50M;

    # Route API requests to Python Backend
    location /api/ {
        proxy_pass http://127.0.0.1:5000/api/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # Route normal requests to Next.js Frontend
    location / {
        proxy_pass http://127.0.0.1:3000/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

    sudo ln -sf /etc/nginx/sites-available/vnet_renewal /etc/nginx/sites-enabled/vnet_renewal
    sudo rm -f /etc/nginx/sites-enabled/default
    sudo systemctl restart nginx

    echo "[6/6] Securing with Free SSL (Certbot)..."
    sudo certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email || echo "SSL setup failed. Check your DNS records."

    echo ""
    echo "================================================"
    echo "  SUCCESS: VNET Renewal System is LIVE!"
    echo "  Customer URL : https://$DOMAIN"
    echo "  Admin URL    : https://$DOMAIN/admin"
    echo "  Admin Token  : vnet_admin_secret_123"
    echo "================================================"

elif [ "$MAIN_OPT" == "2" ]; then
    echo "Updating system..."
    
    cd "$BACKEND_DIR"
    source venv/bin/activate
    pip install -q -r requirements.txt
    pm2 restart vnet-backend

    cd "$FRONTEND_DIR"
    npm install
    npm run build
    pm2 restart vnet-frontend

    echo "Update complete! Services restarted."

elif [ "$MAIN_OPT" == "3" ]; then
    echo ""
    pm2 status
    echo ""
    sudo systemctl status nginx --no-pager | grep Active
    echo ""
else
    echo "Exiting."
    exit 0
fi