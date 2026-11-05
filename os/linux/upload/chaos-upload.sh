#!/bin/sh
# Day moi file .chau trong outbox len Google Drive; chi xoa ban tren board khi rclone
# xac nhan da tai len thanh cong (rclone move). Mang rot thi file nam lai cho lan sau.
set -eu

OUTBOX="${CHAOS_OUTBOX:-/var/lib/chaos/outbox}"
REMOTE="${CHAOS_REMOTE:-gdrive:PBL5/dht22}"
CONF="${RCLONE_CONFIG:-/etc/chaos/rclone.conf}"

[ -d "$OUTBOX" ] || exit 0
exec rclone --config "$CONF" move "$OUTBOX" "$REMOTE" \
    --include "*.chau" --min-age 10s \
    --retries 3 --low-level-retries 5 --log-level INFO
