#!/bin/sh
# Synchronize certificates into existing single-file Docker bind mounts.
set -eu
case "${RENEWED_LINEAGE:-}" in
  /etc/letsencrypt/live/sub.zxc1x1.ru|/etc/letsencrypt/live/cdn.zxc1x1.ru|/etc/letsencrypt/live/panel.zxc1x1.ru)
    name="${RENEWED_LINEAGE##*/}"
    dest="/opt/remnawave/nginx/ssl/$name"
    test -d "$dest"
    openssl x509 -in "$RENEWED_LINEAGE/fullchain.pem" -noout -checkend 86400
    # cp overwrites the existing inode; atomic rename would stale the bind mount.
    cp "$RENEWED_LINEAGE/fullchain.pem" "$dest/fullchain.pem"
    cp "$RENEWED_LINEAGE/privkey.pem" "$dest/privkey.pem"
    chmod 600 "$dest/privkey.pem"
    docker exec remnawave-nginx nginx -t
    docker exec remnawave-nginx nginx -s reload
    ;;
esac
