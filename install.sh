#!/bin/sh
set -eu

REPOSITORY=owenewans/slackinstall
VERSION=${SLACKINSTALL_VERSION:-latest}
INSTALL_DIR=${SLACKINSTALL_INSTALL_DIR:-/usr/local/bin}

case "$(uname -s)" in
    Linux) ;;
    *) printf 'error: slackinstall release binaries support Linux only\n' >&2; exit 1 ;;
esac

case "$(uname -m)" in
    x86_64|amd64) TARGET=x86_64-linux-musl ;;
    *) printf 'error: unsupported architecture: %s\n' "$(uname -m)" >&2; exit 1 ;;
esac

ASSET="slackinstall-$TARGET"
if [ -n "${SLACKINSTALL_DOWNLOAD_BASE:-}" ]; then
    BASE_URL=${SLACKINSTALL_DOWNLOAD_BASE%/}
elif [ "$VERSION" = latest ]; then
    BASE_URL="https://github.com/$REPOSITORY/releases/latest/download"
else
    BASE_URL="https://github.com/$REPOSITORY/releases/download/$VERSION"
fi

TEMP_DIR=$(mktemp -d)
cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT HUP INT TERM

download() {
    url=$1
    destination=$2
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$destination"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$destination" "$url"
    else
        printf 'error: curl or wget is required\n' >&2
        exit 1
    fi
}

printf 'downloading %s (%s)\n' "$ASSET" "$VERSION"
download "$BASE_URL/$ASSET" "$TEMP_DIR/$ASSET"
download "$BASE_URL/$ASSET.sha256" "$TEMP_DIR/$ASSET.sha256"

if command -v sha256sum >/dev/null 2>&1; then
    (cd "$TEMP_DIR" && sha256sum -c "$ASSET.sha256")
elif command -v shasum >/dev/null 2>&1; then
    (cd "$TEMP_DIR" && shasum -a 256 -c "$ASSET.sha256")
else
    printf 'error: sha256sum or shasum is required to verify the release\n' >&2
    exit 1
fi

install_binary() {
    mkdir -p "$INSTALL_DIR"
    install -m 755 "$TEMP_DIR/$ASSET" "$INSTALL_DIR/slackinstall"
}

if [ "$(id -u)" -eq 0 ] || { [ -d "$INSTALL_DIR" ] && [ -w "$INSTALL_DIR" ]; }; then
    install_binary
elif command -v sudo >/dev/null 2>&1; then
    sudo mkdir -p "$INSTALL_DIR"
    sudo install -m 755 "$TEMP_DIR/$ASSET" "$INSTALL_DIR/slackinstall"
else
    printf 'error: cannot write to %s and sudo is unavailable\n' "$INSTALL_DIR" >&2
    exit 1
fi

printf 'installed slackinstall to %s/slackinstall\n' "$INSTALL_DIR"
