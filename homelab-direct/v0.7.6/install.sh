#!/usr/bin/env bash
set -Eeuo pipefail

NC_ROOT="${NC_ROOT:-/var/www/nextcloud}"
HOMELAB_USER="${HOMELAB_USER:-junge}"
APP_DIR="$NC_ROOT/custom_apps/homelab"
BASE_URL="https://raw.githubusercontent.com/jungervin/photo-gallery-python-flask/homelab-binary2/homelab-direct/v0.7.6"
PATCH_SHA256="34ff06e812123296faff6299bb070f2209894a851b80a56a5f878bb8c16e21fe"
PARTS=(patch00 patch01 patch02 patch03 patch04 patch05 patch06)
TMP_DIR="$(mktemp -d)"
PATCH_FILE="$TMP_DIR/homelab-v0.7.6.patch"
BACKUP_DIR="/home/junge/homelab-backup-$(date +%Y%m%d-%H%M%S)"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

if [[ "$EUID" -ne 0 ]]; then
    echo "Ezt rootként futtasd."
    exit 1
fi

for cmd in wget sha256sum patch runuser php; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "Hiányzó parancs: $cmd"; exit 1; }
done

[[ -f "$NC_ROOT/occ" ]] || { echo "Nem található: $NC_ROOT/occ"; exit 1; }
[[ -d "$APP_DIR" ]] || { echo "Nem található HomeLab app: $APP_DIR"; exit 1; }

echo "HomeLab v0.7.6 javítás letöltése..."
: > "$PATCH_FILE"
for part in "${PARTS[@]}"; do
    wget --quiet --show-progress --tries=3 --timeout=30 \
        "$BASE_URL/$part" -O "$TMP_DIR/$part"
    cat "$TMP_DIR/$part" >> "$PATCH_FILE"
done

echo "$PATCH_SHA256  $PATCH_FILE" | sha256sum --check --strict

echo "Biztonsági mentés: $BACKUP_DIR"
cp -a "$APP_DIR" "$BACKUP_DIR"

cd "$APP_DIR"
if patch --dry-run --batch --forward -p1 < "$PATCH_FILE" >/dev/null; then
    echo "Javítás alkalmazása..."
    patch --batch --forward -p1 < "$PATCH_FILE"
else
    CURRENT_VERSION="$(sed -n 's:.*<version>\(.*\)</version>.*:\1:p' "$APP_DIR/appinfo/info.xml" | head -n1)"
    if [[ "$CURRENT_VERSION" == "0.7.6" ]]; then
        echo "A forrás már 0.7.6-os; a patch alkalmazását kihagyom."
    else
        echo "A patch nem alkalmazható tisztán. A mentés itt van: $BACKUP_DIR"
        exit 1
    fi
fi

chown -R junge:www-data "$APP_DIR"

for php_file in \
    "$APP_DIR/appinfo/routes.php" \
    "$APP_DIR/lib/AppInfo/Application.php" \
    "$APP_DIR/lib/Controller/PhotoController.php" \
    "$APP_DIR/lib/Listener/PhotoFileChangedListener.php" \
    "$APP_DIR/lib/Service/PhotoIndexService.php"; do
    php -l "$php_file" >/dev/null
done

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

echo "Fotóindex frissítése: $HOMELAB_USER"
runuser -u www-data -- php "$NC_ROOT/occ" homelab:photos:index --user="$HOMELAB_USER"

echo
echo "HomeLab v0.7.6 telepítve. Böngészőben: Ctrl + Shift + R"
echo "Mentés: $BACKUP_DIR"
