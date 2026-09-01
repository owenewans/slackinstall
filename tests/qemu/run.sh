#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/../.." && pwd)
CACHE_DIR=${SLACKINSTALL_QEMU_DIR:-"$HOME/.cache/slackinstall-qemu"}
ISO=${SLACKWARE_ISO:-}
ISO_MD5=f8418ef0ec2c0a205adf5dbc2f2a1971
HTTP_PORT=${SLACKINSTALL_QEMU_PORT:-18099}
DISK_SIZE=${SLACKINSTALL_QEMU_DISK_SIZE:-8G}
QEMU_BIN=${QEMU_BIN:-qemu-system-x86_64}

if [ -z "$ISO" ]; then
    printf '%s\n' "usage: SLACKWARE_ISO=/path/to/slackware64-15.0-install-dvd.iso tests/qemu/run.sh" >&2
    exit 2
fi
if [ ! -f "$ISO" ]; then
    printf 'error: ISO not found: %s\n' "$ISO" >&2
    exit 2
fi

for command in zig qemu-img xorriso expect python3 md5sum grep mktemp "$QEMU_BIN"; do
    if ! command -v "$command" >/dev/null 2>&1; then
        printf 'error: required command not found: %s\n' "$command" >&2
        exit 2
    fi
done

checksum=$(md5sum "$ISO")
checksum=${checksum%% *}
if [ "$checksum" != "$ISO_MD5" ]; then
    printf 'error: Slackware ISO MD5 mismatch: expected %s, got %s\n' "$ISO_MD5" "$checksum" >&2
    exit 1
fi

mkdir -p "$CACHE_DIR"
RUN_DIR=$(mktemp -d "$CACHE_DIR/run.XXXXXX")
MIRROR="$CACHE_DIR/mirror"
MIRROR_ROOT="$MIRROR/slackware64-15.0/slackware64"
PACKAGE_NAMES="$RUN_DIR/minimal-packages.txt"
PAYLOAD_DIR="$RUN_DIR/payload"
PAYLOAD_ISO="$RUN_DIR/payload.iso"
DISK_IMAGE="$RUN_DIR/disk.qcow2"
INSTALL_LOG="$RUN_DIR/install-console.log"
BOOT_LOG="$RUN_DIR/boot-console.log"

mkdir -p "$MIRROR_ROOT" "$PAYLOAD_DIR"

printf '%s\n' '==> running unit tests and building baseline x86_64 installer'
(
    cd "$REPO_ROOT"
    zig build test
    zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe
)
BINARY="$REPO_ROOT/zig-out/bin/slackinstall"

"$BINARY" profile minimal | while IFS= read -r line; do
    case "$line" in
        ''|'#'*) ;;
        *) printf '%s\n' "$line" ;;
    esac
done > "$PACKAGE_NAMES"

expected=$(wc -l < "$PACKAGE_NAMES")
resolved=0
tab=$(printf '\t')
while IFS="$tab" read -r name relative; do
    if ! grep -Fqx "$name" "$PACKAGE_NAMES"; then
        continue
    fi
    resolved=$((resolved + 1))
    destination="$MIRROR_ROOT/$relative"
    if [ -f "$destination" ]; then
        continue
    fi
    mkdir -p "$(dirname "$destination")"
    printf '==> caching %s\n' "$name"
    xorriso -osirrox on -indev "$ISO" \
        -extract "/slackware64/$relative" "$destination"
done < "$REPO_ROOT/src/data/pkgindex.tsv"

if [ "$resolved" -ne "$expected" ]; then
    printf 'error: resolved %s of %s minimal packages in pkgindex\n' "$resolved" "$expected" >&2
    exit 1
fi

cp "$BINARY" "$PAYLOAD_DIR/slackinstall"
chmod 755 "$PAYLOAD_DIR/slackinstall"
cat > "$PAYLOAD_DIR/test-config.json" <<EOF
{
  "disk": "/dev/vda",
  "hostname": "qemu-test",
  "profile": "minimal",
  "dns_mode": "plain",
  "dns_servers": ["9.9.9.9"],
  "package_mirror": "http://10.0.2.2:$HTTP_PORT/slackware64-15.0/slackware64",
  "swap_mb": 256,
  "root_password": "slackinstall-test"
}
EOF

xorriso -as mkisofs -quiet -J -R -o "$PAYLOAD_ISO" "$PAYLOAD_DIR"
qemu-img create -f qcow2 "$DISK_IMAGE" "$DISK_SIZE"

python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 --directory "$MIRROR" \
    >"$RUN_DIR/http.log" 2>&1 &
HTTP_PID=$!
cleanup() {
    if kill -0 "$HTTP_PID" >/dev/null 2>&1; then
        kill "$HTTP_PID" >/dev/null 2>&1 || true
        wait "$HTTP_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT HUP INT TERM
sleep 1
if ! kill -0 "$HTTP_PID" >/dev/null 2>&1; then
    printf 'error: local package mirror failed to start; see %s/http.log\n' "$RUN_DIR" >&2
    exit 1
fi

if [ -z "${QEMU_ACCEL:-}" ]; then
    if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
        QEMU_ACCEL=kvm
    else
        QEMU_ACCEL=tcg
    fi
fi
case "$QEMU_ACCEL" in
    kvm|tcg) ;;
    *) printf 'error: QEMU_ACCEL must be kvm or tcg\n' >&2; exit 2 ;;
esac

export SLACKWARE_ISO="$ISO"
export PAYLOAD_ISO DISK_IMAGE INSTALL_LOG BOOT_LOG QEMU_BIN QEMU_ACCEL

printf '==> installing minimal profile in QEMU (%s acceleration)\n' "$QEMU_ACCEL"
expect "$SCRIPT_DIR/install.exp"
printf '%s\n' '==> booting installed system and running strict checks'
expect "$SCRIPT_DIR/boot.exp"
printf '==> QEMU smoke test passed; logs and disk are in %s\n' "$RUN_DIR"
