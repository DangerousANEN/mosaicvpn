#!/usr/bin/env bash
# Deploy web cabinet API to VPS (5.175.188.152)
# Run from mosaicvpn/ root on Windows: bash scripts/deploy_web_cabinet.sh
set -euo pipefail

VPS_IP="5.175.188.152"
SSH_KEY="$HOME/.ssh/id_ed25519_vitaly"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=60 -o ConnectionAttempts=5"
LANDING_DIR="/etc/letsencrypt/landing"
BOT_DIR="/opt/mosaic-bot"
NGINX_CONF="/opt/remnawave/nginx.conf"

echo "=== 1/6: Uploading bot.py ==="
scp $SSH_OPTS -i "$SSH_KEY" bot/bot.py "root@$VPS_IP:$BOT_DIR/"
echo "OK"

echo "=== 2/6: Uploading cabinet.html ==="
scp $SSH_OPTS -i "$SSH_KEY" site/cabinet.html "root@$VPS_IP:$LANDING_DIR/"
echo "OK"

echo "=== 3/6: Adding /api/ proxy to nginx.conf ==="
# Check if /api/ proxy already exists
HAS_API=$(ssh $SSH_OPTS -i "$SSH_KEY" "root@$VPS_IP" "grep -c 'location /api/' $NGINX_CONF || true")
if [ "$HAS_API" = "0" ]; then
  # Insert /api/ proxy block before the existing static HTML regex
  ssh $SSH_OPTS -i "$SSH_KEY" "root@$VPS_IP" "
    # Backup
    cp $NGINX_CONF ${NGINX_CONF}.bak.$(date +%Y%m%d%H%M%S)
    # Insert /api/ location block before the regex location for static HTML
    sed -i '/location ~ \^\/(docs|cabinet|/i\\
    # Web cabinet API — proxy to bot on port 12223\\
    location /api/ {\\
        proxy_pass http://127.0.0.1:12223;\\
        proxy_set_header Host \$host;\\
        proxy_set_header X-Real-IP \$remote_addr;\\
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;\\
        proxy_set_header X-Forwarded-Proto \$scheme;\\
    }\\
' $NGINX_CONF
    echo 'Added /api/ proxy'
  "
else
  echo "/api/ proxy already exists — skipping"
fi

echo "=== 4/6: Restarting bot ==="
ssh $SSH_OPTS -i "$SSH_KEY" "root@$VPS_IP" "
  cd $BOT_DIR
  # Kill old bot process
  pkill -f 'python3 bot.py' || true
  sleep 2
  # Start new bot process
  nohup python3 bot.py > bot.log 2>&1 &
  sleep 3
  # Verify it's running
  if pgrep -f 'python3 bot.py' > /dev/null; then
    echo 'Bot started OK'
  else
    echo 'ERROR: Bot failed to start'
    tail -20 bot.log
    exit 1
  fi
"

echo "=== 5/6: Reloading nginx ==="
ssh $SSH_OPTS -i "$SSH_KEY" "root@$VPS_IP" "
  docker exec remnawave-nginx nginx -t && \
  docker restart remnawave-nginx && \
  sleep 5 && \
  docker exec remnawave-nginx nginx -T | grep 'location /api/'
"

echo "=== 6/6: Verifying endpoints ==="
echo "Testing /api/session OPTIONS..."
curl -s -o /dev/null -w "  OPTIONS /api/session -> %{http_code}\n" \
  -X OPTIONS https://sub.zxc1x1.ru/api/session \
  -H "Origin: https://sub.zxc1x1.ru"

echo "Testing /api/billing/profile (no token)..."
curl -s -w "  GET /api/billing/profile -> %{http_code}\n" \
  https://sub.zxc1x1.ru/api/billing/profile

echo "Testing cabinet.html..."
curl -s -o /dev/null -w "  GET /cabinet.html -> %{http_code}\n" \
  https://sub.zxc1x1.ru/cabinet.html

echo ""
echo "=== DONE ==="
echo "If all endpoints returned expected codes, the web cabinet is live."
echo "  - OPTIONS should return 204"
echo "  - GET /api/billing/profile without token should return 401"
echo "  - cabinet.html should return 200"
