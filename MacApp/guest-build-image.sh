#!/usr/bin/env bash
# Runs as root INSIDE a dedicated Lima Ubuntu Linux virtual machine on the Mac.
# Rebuild a Pi OS (MBR/FAT32 boot/ext4 root) flashable image from streamed GNU tar archives.
set -Eeuo pipefail
umask 077
export DEBIAN_FRONTEND=noninteractive
[[ $# -eq 2 && $(id -u) -eq 0 ]] || { echo 'Linux builder must run as root with archive and output arguments' >&2; exit 2; }
archive="$1"; output="$2"
[[ -f "$archive/root.tar.gz" && -f "$archive/boot.tar.gz" && -f "$archive/disk-layout.txt" ]] || { echo 'Missing archive files in Linux VM' >&2; exit 2; }
[[ "$output" == *.img && ! -e "$output" && ! -e "$output.partial" ]] || { echo 'Output image already exists or invalid extension' >&2; exit 2; }
# Reject unexpected source filesystem types; this builder only supports the user's Pi OS ext4 root + FAT boot layout.
grep -Eq '(^|[[:space:]])ext4([[:space:]]|$)|TYPE="ext4"|root-fstype: ext4' "$archive/disk-layout.txt" || {
    echo 'Expected an ext4 root filesystem in disk layout; unsupported source' >&2; exit 2;
}
grep -Eq '(^|[[:space:]])vfat([[:space:]]|$)|TYPE="vfat"|boot-fstype: vfat' "$archive/disk-layout.txt" || {
    echo 'Expected a vfat boot filesystem in disk layout; unsupported source' >&2; exit 2;
}
for tool in parted mkfs.vfat mkfs.ext4 losetup blkid fsck.vfat e2fsck; do
    if ! command -v "$tool" >/dev/null; then
        echo '=== Installing Linux image-building utilities ==='
        apt-get update -qq
        apt-get install -y -qq parted dosfstools e2fsprogs util-linux
        break
    fi
done
work="$(mktemp -d /var/tmp/piim-image-XXXXXX)"
loop=""
boot_mounted=0
root_mounted=0
cleanup() {
    local rc=$?
    trap - EXIT
    if (( boot_mounted )); then umount "$work/mount/boot/firmware" || true; fi
    if (( root_mounted )); then umount "$work/mount" || true; fi
    if [[ -n "$loop" ]]; then losetup -d "$loop" || true; fi
    rm -rf -- "$work"
    if (( rc != 0 )); then rm -f -- "$output.partial"; fi
    exit "$rc"
}
trap cleanup EXIT
mkdir -p "$work/root" "$work/mount"
printf '%s\n' '=== Restoring root archive into private Linux workspace ==='
tar --extract --gzip --file "$archive/root.tar.gz" --directory "$work/root" \
    --numeric-owner --same-owner --acls --xattrs --xattrs-include='*' --delay-directory-restore
# Basic Pi OS bootability validation BEFORE partitioning.
[[ -f "$work/root/etc/fstab" && -d "$work/root/usr" ]] || { echo 'Root filesystem archive is missing essential paths' >&2; exit 1; }
[[ -e "$archive/boot.tar.gz" ]] || exit 1
root_kib="$(du -sxk "$work/root" | awk '{print $1}')"
# 30% headroom plus 1 GiB, minimum 4 GiB. Sizes in MiB.
root_mib=$(( (root_kib * 13 + 10239) / 10240 + 1024 ))
(( root_mib >= 4096 )) || root_mib=4096
# FAT boot starts at 4 MiB, ends at 516 MiB; root spans remainder.
image_mib=$((516 + root_mib))
free_mib="$(df -Pm "$work" | awk 'NR==2 {print $4}')"
# Workspace has extracted files AND must have space to create the full image.
(( free_mib >= image_mib + 1024 )) || {
    echo "Insufficient Linux VM disk space: ${free_mib} MiB available, need at least $((image_mib + 1024)) MiB" >&2
    echo 'Increase VM disk allocation or reduce archive contents before conversion.' >&2
    exit 1
}
echo "Root archive extracted: ${root_kib} KiB; allocating ${image_mib} MiB disk image"
img="$work/pi.img"
truncate -s "${image_mib}M" "$img"
parted -s "$img" mklabel msdos
parted -s "$img" unit MiB mkpart primary fat32 4 516
parted -s "$img" unit MiB mkpart primary ext4 516 100%
# Linux loop disk is fully contained in the Mac's isolated image-building VM.
loop="$(losetup --find --show --partscan "$img")"
udevadm settle || true
for i in 1 2 3 4 5; do
    [[ -b "${loop}p1" && -b "${loop}p2" ]] && break
    sleep 1
done
[[ -b "${loop}p1" && -b "${loop}p2" ]] || { echo 'Linux loop partition devices missing' >&2; exit 1; }
mkfs.vfat -F 32 -n bootfs "${loop}p1" >/dev/null
mkfs.ext4 -F -q -L rootfs "${loop}p2"
mount "${loop}p2" "$work/mount"
root_mounted=1
# Moving the restored tree onto the image preserves Linux ownership/ACLs/xattrs.
cp -a "$work/root/." "$work/mount/"
mkdir -p "$work/mount/boot/firmware"
mount "${loop}p1" "$work/mount/boot/firmware"
boot_mounted=1
printf '%s\n' '=== Restoring Raspberry Pi firmware/boot files ==='
tar --extract --gzip --file "$archive/boot.tar.gz" --directory "$work/mount/boot/firmware" \
    --no-same-owner --no-same-permissions
[[ -s "$work/mount/boot/firmware/cmdline.txt" && -f "$work/mount/boot/firmware/config.txt" ]] || {
    echo 'Boot archive lacks expected Pi OS config.txt or cmdline.txt' >&2; exit 1;
}
boot_id="$(blkid -s PARTUUID -o value "${loop}p1")"
root_id="$(blkid -s PARTUUID -o value "${loop}p2")"
[[ -n "$boot_id" && -n "$root_id" ]] || { echo 'No partition UUIDs generated' >&2; exit 1; }
printf '=== Updating boot identifiers: boot %s, root %s ===\n' "$boot_id" "$root_id"
python3 - "$work/mount/etc/fstab" "$work/mount/boot/firmware/cmdline.txt" "$boot_id" "$root_id" <<'PY'
import pathlib, re, sys
fstab, cmdline = map(pathlib.Path, sys.argv[1:3]); boot_id, root_id = sys.argv[3:]
text = fstab.read_text()
seen = set()
new = []
for line in text.splitlines(keepends=True):
    if line.lstrip().startswith('#') or not line.strip():
        new.append(line); continue
    p = line.split()
    if len(p) >= 4 and p[1] in ('/', '/boot/firmware'):
        assert p[1] not in seen, f'duplicate fstab mount: {p[1]}'
        seen.add(p[1]); p[0] = 'PARTUUID=' + (root_id if p[1] == '/' else boot_id)
        new.append('\t'.join(p) + '\n')
    else: new.append(line)
assert seen == {'/', '/boot/firmware'}, 'missing root/boot entries in fstab'
fstab.write_text(''.join(new))
line = cmdline.read_text().strip()
assert len(re.findall(r'(?<!\S)root=\S+', line)) == 1, 'expected one root= option in cmdline.txt'
line = re.sub(r'(?<!\S)root=\S+', 'root=PARTUUID=' + root_id, line)
cmdline.write_text(line + '\n')
PY
mkdir -p "$work/mount"/{dev,proc,sys,run,tmp,mnt,media}
chmod 1777 "$work/mount/tmp"
sync
umount "$work/mount/boot/firmware"; boot_mounted=0
umount "$work/mount"; root_mounted=0
printf '%s\n' '=== Checking FAT32 and ext4 filesystems ==='
fsck.vfat -n "${loop}p1"
e2fsck -fn "${loop}p2"
losetup -d "$loop"; loop=""
printf '%s\n' '=== Transferring generated image to Mac backup folder ==='
cp --sparse=always "$img" "$output.partial"
sync -f "$output.partial"
source_sha="$(sha256sum "$img" | awk '{print $1}')"
target_sha="$(sha256sum "$output.partial" | awk '{print $1}')"
[[ "$source_sha" == "$target_sha" ]] || { echo 'Mac output checksum mismatch; partial file removed' >&2; exit 1; }
mv -- "$output.partial" "$output"
printf 'IMAGE_OK|%s|%s\n' "$output" "$source_sha"
