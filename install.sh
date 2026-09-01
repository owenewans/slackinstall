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
    i386|i486|i586|i686) TARGET=x86-linux-musl ;;
    *) printf 'error: unsupported architecture: %s\n' "$(uname -m)" >&2; exit 1 ;;
esac

ASSET="slackinstall-$TARGET"

# A user-supplied download base is used as-is, with no automatic fallback,
# since they've explicitly chosen where to fetch from. Otherwise GitHub
# Releases is the default source, with an automatic retry through a small
# live pass-through proxy if that fails - some environments (e.g. BusyBox
# wget's minimal TLS client in a bare Slackware live install) can fail to
# fetch from GitHub's release CDN for reasons a shell script can't work
# around directly (TLS version/cipher support, TLS fingerprint filtering,
# etc.), so this self-heals without the caller needing to know about it or
# pass any extra flags. The proxy fetches live from GitHub on every request
# (see https://github.com/owenewans/slackinstall/blob/master/readme.md) so
# it can't serve a stale binary.
MIRROR_BASE=${SLACKINSTALL_MIRROR_BASE:-http://src.owenewans.org/gh-release}
if [ -n "${SLACKINSTALL_DOWNLOAD_BASE:-}" ]; then
    PRIMARY_BASE=${SLACKINSTALL_DOWNLOAD_BASE%/}
    FALLBACK_BASE=""
elif [ "$VERSION" = latest ]; then
    PRIMARY_BASE="https://github.com/$REPOSITORY/releases/latest/download"
    FALLBACK_BASE="$MIRROR_BASE/latest"
else
    PRIMARY_BASE="https://github.com/$REPOSITORY/releases/download/$VERSION"
    FALLBACK_BASE="$MIRROR_BASE/$VERSION"
fi

TEMP_DIR=$(mktemp -d)
cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT HUP INT TERM

fetch() {
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

download() {
    name=$1
    destination=$2
    if fetch "$PRIMARY_BASE/$name" "$destination"; then
        return 0
    fi
    if [ -n "$FALLBACK_BASE" ]; then
        printf 'primary download of %s failed, retrying via mirror\n' "$name" >&2
        fetch "$FALLBACK_BASE/$name" "$destination"
        return $?
    fi
    return 1
}

printf 'downloading %s (%s)\n' "$ASSET" "$VERSION"
download "$ASSET" "$TEMP_DIR/$ASSET" || { printf 'error: failed to download %s\n' "$ASSET" >&2; exit 1; }
download "$ASSET.sha256" "$TEMP_DIR/$ASSET.sha256" || { printf 'error: failed to download %s.sha256\n' "$ASSET" >&2; exit 1; }

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
