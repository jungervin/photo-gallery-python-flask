#!/usr/bin/env bash
set -Eeuo pipefail

NC_ROOT="${NC_ROOT:-/var/www/nextcloud}"
HOMELAB_USER="${HOMELAB_USER:-junge}"
APP_DIR="$NC_ROOT/custom_apps/homelab"
BASE_URL="https://raw.githubusercontent.com/jungervin/photo-gallery-python-flask/homelab-packages/homelab-packages/v0.7.6"
EXPECTED_SHA256="b2ed1177bf9ae19e684346bccbcf20248c867488ae0c90dc6bf546aa3c17d2dd"
PARTS=(part00 part01 part02a part02b part03a part03b part04a part04b part05a part05b)
TMP_DIR="$(mktemp -d)"
BACKUP_DIR="/home/junge/homelab-backup-$(date +%Y%m%d-%H%M%S)"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

if [[ "${EUID}" -ne 0 ]]; then
    echo "Ezt rootként futtasd, öcsém."
    exit 1
fi

for command_name in wget base64 sha256sum unzip runuser php tr; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Hiányzó parancs: $command_name"
        exit 1
    fi
done

if [[ ! -f "$NC_ROOT/occ" ]]; then
    echo "Nem található a Nextcloud occ: $NC_ROOT/occ"
    exit 1
fi

echo "HomeLab v0.7.6 letöltése..."
for part in "${PARTS[@]}"; do
    wget --quiet --show-progress --tries=3 --timeout=30 \
        "$BASE_URL/$part" \
        -O "$TMP_DIR/$part"
done

# A feltöltött darabok önálló base64 blokkok lehetnek. Ezért minden
# részt külön dekódolunk, és a bináris ZIP-részeket fűzzük össze.
ZIP_FILE="$TMP_DIR/homelab-v0.7.6.zip"
: > "$ZIP_FILE"
for part in "${PARTS[@]}"; do
    tr -d '\r\n\t ' < "$TMP_DIR/$part" \
        | base64 --decode >> "$ZIP_FILE"
done

echo "$EXPECTED_SHA256  $ZIP_FILE" | sha256sum --check --strict
unzip -tq "$ZIP_FILE" >/dev/null

echo "Biztonsági mentés: $BACKUP_DIR"
if [[ -d "$APP_DIR" ]]; then
    cp -a "$APP_DIR" "$BACKUP_DIR"
fi

echo "Fájlok telepítése..."
unzip -oq "$ZIP_FILE" -d "$NC_ROOT"
chown -R junge:www-data "$APP_DIR"

echo "React frontend fordítása..."
runuser -u junge -- env HOME=/home/junge bash -c '
    set -Eeuo pipefail
    export NVM_DIR=/home/junge/.nvm
    source "$NVM_DIR/nvm.sh"
    nvm use 22
    cd /var/www/nextcloud/custom_apps/homelab/frontend
    npm run build
'

echo "Nextcloud app frissítése..."
runuser -u www-data -- php "$NC_ROOT/occ" upgrade

echo "A $HOMELAB_USER fotóindexének azonnali frissítése..."
runuser -u www-data -- php "$NC_ROOT/occ" homelab:photos:index --user="$HOMELAB_USER"

echo "Háttérfeladat egyszeri futtatása..."
runuser -u www-data -- php -f "$NC_ROOT/cron.php" || true

echo
echo "HomeLab v0.7.6 telepítve. Böngészőben: Ctrl + Shift + R"
echo "Mentés: $BACKUP_DIR"
