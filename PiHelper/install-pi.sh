#!/usr/bin/env bash
# One-time setup; no SMB/CIFS share, Mac SSH server, or passwords required.
set -Eeuo pipefail
[[ $(id -u) -eq 0 ]] || { echo 'Run as root: sudo ./install-pi.sh pi' >&2; exit 1; }
USER_NAME="${1:-pi}"
[[ "$USER_NAME" =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo 'Invalid username' >&2; exit 1; }
id "$USER_NAME" >/dev/null 2>&1 || { echo "No user: $USER_NAME" >&2; exit 1; }
BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Replacing the installed helper during a running backup could mix protocols.
if ps -eo args | grep -E '[s]udo -n /usr/local/sbin/pi-image-helper (create|stream-root|stream-boot|send|meta)' | grep -q .; then
  echo 'An existing Pi Image Manager backup is active. Finish or abort it before upgrading.' >&2
  exit 1
fi
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y git rsync gdisk parted dosfstools e2fsprogs f2fs-tools util-linux
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
git clone --depth 1 https://github.com/seamusdemora/RonR-RPi-image-utils.git "$TMP/image-utils"
install -o root -g root -m 0755 "$TMP/image-utils/image-backup" /usr/local/sbin/image-backup
install -o root -g root -m 0755 "$BASE/pi-image-helper" /usr/local/sbin/pi-image-helper
# Preserve staged images from an interrupted transfer. Don't delete this folder during upgrades.
install -d -o root -g root -m 0700 /mnt/pi-image-stage
RULE="$(mktemp)"
trap 'rm -rf "$TMP" "$RULE"' EXIT
printf '%s ALL=(root) NOPASSWD: /usr/local/sbin/pi-image-helper\n' "$USER_NAME" >"$RULE"
chmod 0440 "$RULE"
visudo -cf "$RULE"
install -o root -g root -m 0440 "$RULE" /etc/sudoers.d/pi-image-manager
visudo -cf /etc/sudoers.d/pi-image-manager
printf '\nInstalled. No network share required.\n'
printf 'Test: sudo -n /usr/local/sbin/pi-image-helper status\n'
printf 'Staging folder: /mnt/pi-image-stage (root-owned).\n'
printf 'Full .img backups stage there; direct streaming recovery archives do not use it.\n'
