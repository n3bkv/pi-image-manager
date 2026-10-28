#!/usr/bin/env bash
# Non-destructive test of shell, helper exclusions, and mocked SSH streaming.
set -Eeuo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
for file in "$repo"/MacApp/*.sh "$repo"/PiHelper/*.sh; do bash -n "$file"; done

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -m 0700 "$tmp/stage"
printf '#!/bin/sh\nexit 0\n' > "$tmp/engine"
chmod +x "$tmp/engine"
sed -e "s|STAGE=/mnt/pi-image-stage|STAGE=$tmp/stage|" \
    -e "s|ENGINE=/usr/local/sbin/image-backup|ENGINE=$tmp/engine|" \
    -e "s|LOCK=/run/pi-image-manager.lock|LOCK=$tmp/lock|" \
    "$repo/PiHelper/pi-image-helper" > "$tmp/helper"
chmod +x "$tmp/helper"
"$tmp/helper" status | grep -q '|0.2.0$'
"$tmp/helper" exclusions journal,apt - | grep -qx '/var/log/journal'
payload="$(printf '%s' '/srv/My Recordings' | base64 | tr -d '\n')"
"$tmp/helper" exclusions journal "$payload" | grep -qx '/srv/My Recordings'
protected="$(printf '%s' '/etc' | base64 | tr -d '\n')"
if "$tmp/helper" exclusions journal "$protected" >/dev/null 2>&1; then
    echo 'ERROR: helper accepted exclusion of /etc' >&2
    exit 1
fi
if "$tmp/helper" exclusions malicious - >/dev/null 2>&1; then
    echo 'ERROR: helper accepted unsupported preset' >&2
    exit 1
fi

# Check that tar excludes one literal directory and leaves adjacent data.
mkdir -p "$tmp/src/foo" "$tmp/src/bar"
echo secret > "$tmp/src/foo/secret"
echo preserve > "$tmp/src/bar/data"
tar -cf "$tmp/filtered.tar" --no-wildcards --anchored --exclude='./foo' -C "$tmp/src" .
if tar -tf "$tmp/filtered.tar" | grep -q 'foo/secret'; then
    echo 'ERROR: tar did not exclude desired path' >&2; exit 1
fi
tar -tf "$tmp/filtered.tar" | grep -q 'bar/data'

mkdir -p "$tmp/bin" "$tmp/out" "$tmp/archive-root" "$tmp/archive-boot"
echo root > "$tmp/archive-root/file"
echo boot > "$tmp/archive-boot/cmdline.txt"
tar -C "$tmp/archive-root" -czf "$tmp/root.tgz" .
tar -C "$tmp/archive-boot" -czf "$tmp/boot.tgz" .
cat > "$tmp/bin/ssh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
args="$*"
case "$args" in
    *'estimate-stream'*) echo 'ESTIMATE|1048576|1048576' ;;
    *' layout'*) echo '# sfdisk partition layout:' ;;
    *' exclusions '*) echo /var/swap; echo /var/log/journal; echo '/srv/My Recordings' ;;
    *'stream-root'*) cat "$PIIM_TEST_ROOT_TGZ" ;;
    *'stream-boot'*) cat "$PIIM_TEST_BOOT_TGZ" ;;
    *) echo "Unknown mocked SSH: $args" >&2; exit 1 ;;
esac
MOCK
chmod +x "$tmp/bin/ssh"
export PIIM_TEST_ROOT_TGZ="$tmp/root.tgz" PIIM_TEST_BOOT_TGZ="$tmp/boot.tgz"
PATH="$tmp/bin:$PATH" bash "$repo/MacApp/stream-backup.sh" raspberrypi.local pi "$tmp/out" journal "$payload" "test-normal-20261024" > "$tmp/run.log"
grep -q 'PIIM|PHASE|complete|done' "$tmp/run.log"
# Regression: an empty custom exclusion list ("-") must be accepted.
PATH="$tmp/bin:$PATH" bash "$repo/MacApp/stream-backup.sh" testpi-two.local pi "$tmp/out" journal,apt,usercache - "test-empty-custom" > "$tmp/run-no-custom.log"
grep -q 'PIIM|PHASE|complete|done' "$tmp/run-no-custom.log"
# Regression: an empty preset list and empty custom list must also work.
PATH="$tmp/bin:$PATH" bash "$repo/MacApp/stream-backup.sh" testpi-three.local pi "$tmp/out" - - "test-empty-all" > "$tmp/run-all-default.log"
grep -q 'PIIM|PHASE|complete|done' "$tmp/run-all-default.log"
# Reject invalid base64 payloads; never invoke SSH for them.
if PATH="$tmp/bin:$PATH" bash "$repo/MacApp/stream-backup.sh" raspberrypi.local pi "$tmp/out" journal 'bad*payload' 'test-invalid-base64' > /dev/null 2>&1; then
    echo 'ERROR: accepted malformed encoded exclusion settings' >&2
    exit 1
fi
# Custom names must flow through unchanged (apart from the mandatory -recovery suffix).
backup="$tmp/out/test-normal-20261024-recovery"
[[ -d "$tmp/out/test-empty-custom-recovery" ]]
[[ -d "$tmp/out/test-empty-all-recovery" ]]
# Prevent collisions and unsafe folder names without touching completed archives.
if PATH="$tmp/bin:$PATH" bash "$repo/MacApp/stream-backup.sh" testpi-two.local pi "$tmp/out" - - test-empty-custom > /dev/null 2>&1; then
    echo 'ERROR: existing backup was overwritten' >&2
    exit 1
fi
if PATH="$tmp/bin:$PATH" bash "$repo/MacApp/stream-backup.sh" testpi-two.local pi "$tmp/out" - - ../escape > /dev/null 2>&1; then
    echo 'ERROR: traversal name was accepted' >&2
    exit 1
fi
if PATH="$tmp/bin:$PATH" bash "$repo/MacApp/stream-backup.sh" testpi-two.local pi "$tmp/out" - - 'bad name' > /dev/null 2>&1; then
    echo 'ERROR: space-containing unsafe name was accepted' >&2
    exit 1
fi
# The image converter must validate user-selected output names before starting Lima.
if bash "$repo/MacApp/build-image-mac.sh" "$backup" "$tmp/out" "$repo/MacApp/guest-build-image.sh" ../escape.img > /dev/null 2>&1; then
    echo 'ERROR: invalid image name accepted' >&2
    exit 1
fi
[[ -n "$backup" ]]
[[ -s "$backup/exclusions.txt" ]]
(cd "$backup" && shasum -a 256 -c SHA256SUMS >/dev/null)
[[ ! -e "$backup.partial" ]]
printf 'PASS: syntax, helper validation, custom names, collision protection, archive SHA-256\n'
