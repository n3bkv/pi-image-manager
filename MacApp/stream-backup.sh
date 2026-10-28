#!/bin/bash
# Pi Image Manager v0.2.2 — stream Pi filesystem archives to the Mac over SSH.
# Machine-readable PIIM status lines are sent on stdout, binary data only to local files.
# No full backup image is staged on the Pi.
set -euo pipefail
umask 077
[[ $# -eq 6 ]] || { echo 'Usage: stream-backup.sh HOST USER MAC_DEST PRESETS_CSV PATHS_BASE64 FOLDER_BASE' >&2; exit 2; }
host="$1"; user="$2"; dest="$3"; presets="$4"; encoded="$5"; requested_base="$6"
[[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || { echo 'Invalid hostname' >&2; exit 2; }
[[ "$user" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || { echo 'Invalid username' >&2; exit 2; }
# The SwiftUI app represents an empty preset list or empty custom-path list as "-".
# The Pi helper accepts that sentinel; the Mac launcher must accept it too.
if [[ "$presets" != "-" && ! "$presets" =~ ^[a-z,]*$ ]]; then
    echo 'Invalid preset exclusion settings' >&2
    exit 2
fi
if [[ "$encoded" != "-" && ! "$encoded" =~ ^[A-Za-z0-9+/=]*$ ]]; then
    echo 'Invalid custom exclusion settings' >&2
    exit 2
fi
[[ -d "$dest" && -w "$dest" ]] || { echo 'Destination missing or not writable' >&2; exit 2; }
command -v shasum >/dev/null && command -v gzip >/dev/null || { echo 'Missing macOS gzip/shasum' >&2; exit 2; }
ssh_base=(ssh -T -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 \
          -o ServerAliveInterval=20 -o ServerAliveCountMax=3 -- "$user@$host")
[[ ${#requested_base} -le 96 && "$requested_base" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$requested_base" != *..* ]] || { echo 'Invalid recovery folder name' >&2; exit 2; }
base="$requested_base-recovery"
work="$dest/$base.partial"
final="$dest/$base"
[[ ! -e "$work" && ! -e "$final" ]] || { echo 'Backup name collision; retry after a moment' >&2; exit 1; }
mkdir -m 0700 -- "$work"
finish=0
monitor_pid=""
stream_start=0
current_stage=""
active_ssh_pid=""

file_bytes() {
    local file="$1"
    if [[ ! -f "$file" ]]; then printf '0\n'; return; fi
    if [[ "$(uname -s)" == Darwin ]]; then
        stat -f%z "$file"
    else
        stat -c%s "$file"
    fi
}

# Monitor the growing local file without buffering the actual SSH transfer.
# Average MB/s of completed data is shown alongside the last 1-2 second rate.
monitor_file() {
    local stage="$1" file="$2" start="$3"
    local last_time="$start" last_bytes=0
    local now bytes seconds duration speed
    while :; do
        sleep 1
        now="$(date +%s)"
        bytes="$(file_bytes "$file")"
        duration=$((now - last_time))
        (( duration > 0 )) || duration=1
        speed=$(((bytes - last_bytes) / duration))
        (( speed >= 0 )) || speed=0
        seconds=$((now - start))
        printf 'PIIM|TRANSFER|%s|%s|%s|%s\n' "$stage" "$bytes" "$speed" "$seconds"
        last_bytes="$bytes"; last_time="$now"
    done
}

stop_monitor() {
    if [[ -n "$monitor_pid" ]]; then
        kill "$monitor_pid" 2>/dev/null || true
        wait "$monitor_pid" 2>/dev/null || true
        monitor_pid=""
    fi
}

cleanup() {
    stop_monitor
    if [[ -n "$active_ssh_pid" ]]; then
        kill -TERM "$active_ssh_pid" 2>/dev/null || true
        wait "$active_ssh_pid" 2>/dev/null || true
        active_ssh_pid=""
    fi
    if [[ "$finish" == 0 ]]; then
        echo "ERROR: Incomplete archive removed: $work" >&2
        rm -rf -- "$work"
    fi
}
trap cleanup EXIT
trap 'echo "User aborted the streamed backup" >&2; exit 130' INT
trap 'echo "User aborted the streamed backup" >&2; exit 143' TERM

stream_part() {
    local stage="$1" file="$2" command="$3"
    local received now duration rate
    printf 'PIIM|PHASE|%s|running\n' "$stage"
    echo "=== Streaming $stage filesystem over SSH ==="
    stream_start="$(date +%s)"
    monitor_file "$stage" "$file" "$stream_start" &
    monitor_pid=$!
    # If SSH fails, set -e exits and cleanup kills the monitor and removes partial data.
    # Background SSH and wait: Bash can process TERM immediately during wait,
    # allowing cleanup to terminate SSH instead of waiting for an entire archive.
    "${ssh_base[@]}" "$command" > "$file" &
    active_ssh_pid=$!
    wait "$active_ssh_pid"
    active_ssh_pid=""
    stop_monitor
    received="$(file_bytes "$file")"
    now="$(date +%s)"
    duration=$((now - stream_start))
    (( duration > 0 )) || duration=1
    rate=$((received / duration))
    printf 'PIIM|TRANSFER|%s|%s|%s|%s\n' "$stage" "$received" "$rate" "$duration"
    [[ "$received" -gt 0 ]] || { echo "Empty $stage archive" >&2; return 1; }
    gzip -t "$file"
    mv -- "$file" "${file%.partial}"
    printf 'PIIM|PHASE|%s|done\n' "$stage"
}

# Execute a remote text command in a cancellable SSH child.
remote_text() {
    local remote_cmd="$1" local_out="$2"
    "${ssh_base[@]}" "$remote_cmd" > "$local_out" &
    active_ssh_pid=$!
    wait "$active_ssh_pid"
    active_ssh_pid=""
}

printf 'PIIM|PHASE|estimate|running\n'
# A source-side apparent-size estimate, never a predicted gzip output size.
# Requires Pi Image Manager 0.2.0 helper for matching checkpoint telemetry.
remote_text "sudo -n /usr/local/sbin/pi-image-helper estimate-stream $presets $encoded" "$work/estimate.txt" || {
    echo 'Cannot estimate stream size. Install v0.2.0 Pi helper on the Raspberry Pi.' >&2
    exit 1
}
estimate="$(cat "$work/estimate.txt")"
rm -f -- "$work/estimate.txt"
if [[ "$estimate" =~ ^ESTIMATE\|([0-9]+)\|([0-9]+)$ ]]; then
    printf 'PIIM|ESTIMATE|%s|%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
else
    echo "Unexpected Pi size estimate; install the v0.2.0 helper: $estimate" >&2
    exit 1
fi
printf 'PIIM|PHASE|estimate|done\n'
printf 'PIIM|PHASE|layout|running\n'
echo '=== Receiving disk layout ==='
remote_text 'sudo -n /usr/local/sbin/pi-image-helper layout' "$work/disk-layout.txt"
[[ -s "$work/disk-layout.txt" ]] || { echo 'No disk layout received' >&2; exit 1; }
printf 'PIIM|PHASE|layout|done\n'
remote_text "sudo -n /usr/local/sbin/pi-image-helper exclusions $presets $encoded" "$work/exclusions.txt"
[[ -s "$work/exclusions.txt" ]] || { echo 'Exclusions manifest was not created' >&2; exit 1; }
stream_part root "$work/root.tar.gz.partial" "sudo -n /usr/local/sbin/pi-image-helper stream-root $presets $encoded"
stream_part boot "$work/boot.tar.gz.partial" 'sudo -n /usr/local/sbin/pi-image-helper stream-boot'
printf 'PIIM|PHASE|verify|running\n'
printf 'Pi Image Manager Recovery Archive v0.2.0\nHost: %s\nTime (Mac): %s\nPreset exclusions: %s\nExact excludes: exclusions.txt\nFormat: GNU tar+gzip; NOT a flashable .img\nNo filesystem/application snapshot; live database consistency not guaranteed\n' \
  "$host" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$presets" > "$work/README.txt"
(cd "$work" && shasum -a 256 root.tar.gz boot.tar.gz disk-layout.txt README.txt exclusions.txt > SHA256SUMS && shasum -a 256 -c SHA256SUMS)
printf 'PIIM|PHASE|verify|done\n'
mv -- "$work" "$final"
finish=1
trap - EXIT
printf 'PIIM|PHASE|complete|done\n'
printf 'SUCCESS: %s\n' "$final"
du -sh "$final"
