#!/usr/bin/env bash
# Patch nginx.conf on VPS: add /api/ proxy block
set -e
VPS_IP="5.175.188.152"
SSH_KEY="$HOME/.ssh/id_ed25519_vitaly"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=30"
NGINX_CONF="/opt/remnawave/nginx.conf"

# Backup
ssh $SSH_OPTS -i "$SSH_KEY" "root@$VPS_IP" \
  "cp $NGINX_CONF ${NGINX_CONF}.bak.\$(date +%Y%m%d%H%M%S)"

# Upload the patch script to VPS and run it there
ssh $SSH_OPTS -i "$SSH_KEY" "root@$VPS_IP" 'bash -s' << 'REMOTE_SCRIPT'
set -e
CONF="/opt/remnawave/nginx.conf"

# Find the line with the static HTML regex
LINE=$(grep -n 'location ~ ^/(docs|cabinet' "$CONF" | head -1 | cut -d: -f1)
echo "Inserting /api/ proxy before line $LINE"

# Use awk to insert before that line
awk -v target="$LINE" '
NR == target {
    print "    # Web cabinet API - proxy to bot on port 12223"
    print "    location /api/ {"
    print "        proxy_pass http://127.0.0.1:12223;"
    print "        proxy_set_header Host $host;"
    print "        proxy_set_header X-Real-IP $remote_addr;"
    print "        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;"
    print "        proxy_set_header X-Forwarded-Proto $scheme;"
    print "    }"
}
{ print }
' "$CONF" > /tmp/nginx_patched.conf

mv /tmp/nginx_patched.conf "$CONF"
echo "Patched. Verifying..."
grep -A6 'location /api/' "$CONF"
REMOTE_SCRIPT
