#!/bin/bash
# Convert a Pi Image Manager streamed recovery folder to a partitioned flashable image.
# Runs Linux tools inside a dedicated Lima VM on this Mac; never stages an image on the Pi.
set -Eeuo pipefail
umask 077
[[ $# == 3 || $# == 4 ]] || { echo 'Usage: build-image-mac.sh RECOVERY_FOLDER OUTPUT_FOLDER GUEST_BUILDER_SCRIPT [FILENAME.img]' >&2; exit 2; }
archive_arg="$1"; dest_arg="$2"; guest_script="$3"
[[ -f "$guest_script" ]] || { echo 'Missing bundled Linux image builder script' >&2; exit 2; }
[[ -d "$archive_arg" && -d "$dest_arg" ]] || { echo 'Recovery and output directories must exist' >&2; exit 2; }
archive="$(cd "$archive_arg" && pwd -P)"
dest="$(cd "$dest_arg" && pwd -P)"
# Lima only gets access to the chosen output folder, avoiding broad home-directory access.
case "$archive" in "$dest"/*) ;; *) echo 'The recovery folder must be INSIDE the chosen Mac backup folder for the isolated Linux VM.' >&2; exit 2;; esac
for f in root.tar.gz boot.tar.gz disk-layout.txt SHA256SUMS README.txt; do
    [[ -f "$archive/$f" && ! -L "$archive/$f" ]] || { echo "Missing or unsafe archive component: $f" >&2; exit 2; }
done
command -v shasum >/dev/null || { echo 'Missing shasum' >&2; exit 2; }
command -v gzip >/dev/null || { echo 'Missing gzip' >&2; exit 2; }
limactl="$(command -v limactl || true)"
for candidate in /opt/homebrew/bin/limactl /usr/local/bin/limactl; do
    [[ -n "$limactl" ]] || { [[ ! -x "$candidate" ]] || limactl="$candidate"; }
done
[[ -n "$limactl" && -x "$limactl" ]] || { echo 'Lima is required for image conversion. Install it on Mac with: brew install lima' >&2; exit 2; }

printf '%s\n' 'PIIM|PHASE|conversion|running'
printf '%s\n' '=== Checking saved archive checksums and gzip streams ==='
(cd "$archive" && shasum -a 256 -c SHA256SUMS)
gzip -t "$archive/root.tar.gz"
gzip -t "$archive/boot.tar.gz"
# Only standard single-device Pi OS layout is supported for reconstruction.
grep -q 'sfdisk partition layout:' "$archive/disk-layout.txt" || { echo 'Unsupported or missing original disk-layout metadata' >&2; exit 2; }
archive_name="${archive##*/}"
[[ "$archive_name" == *-recovery ]] || { echo 'Recovery folder should end in -recovery' >&2; exit 2; }
image_name="${4:-${archive_name%-recovery}.img}"
[[ ${#image_name} -le 120 && "$image_name" != *..* && "$image_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.img$ ]] || { echo 'Unsafe image filename' >&2; exit 2; }
[[ ! -e "$dest/$image_name" && ! -e "$dest/$image_name.partial" ]] || { echo "Output exists: $dest/$image_name" >&2; exit 2; }
# Separate VM per destination, so an existing VM can never silently mount a different path.
folder_id="$(printf '%s' "$dest" | shasum -a 256 | awk '{print substr($1,1,10)}')"
instance="piim-${folder_id}"
if ! "$limactl" list --format '{{.Name}}' | grep -Fqx "$instance"; then
    echo "=== Creating dedicated image-builder Linux VM ($instance) ==="
    # Ubuntu/aarch64 on Apple Silicon; 64GiB virtual disk is sparse but needs real free space as used.
    "$limactl" start -y --name "$instance" --cpus 2 --memory 4 --disk 64 \
      --containerd none --mount-only "$dest:w" template:default
else
    echo "=== Starting existing Linux image-builder VM ($instance) ==="
    "$limactl" start -y "$instance"
fi
"$limactl" shell "$instance" test -f "$archive/root.tar.gz" || {
    echo "Linux VM could not read the archive under $dest. Check Lima folder mounts." >&2; exit 1;
}
printf '%s\n' '=== Building bootable FAT32 + ext4 image in Mac Linux VM ==='
"$limactl" shell "$instance" sudo -n bash -s -- "$archive" "$dest/$image_name" < "$guest_script"
[[ -s "$dest/$image_name" && ! -e "$dest/$image_name.partial" ]] || { echo 'Image builder returned without a complete image' >&2; exit 1; }
printf '%s\n' 'PIIM|PHASE|conversion|done'
printf 'SUCCESS: Bootable image candidate saved at %s\n' "$dest/$image_name"
shasum -a 256 "$dest/$image_name"
echo 'IMPORTANT: Boot the image on a spare Pi SD card/SSD and verify applications and databases.'
