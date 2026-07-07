#!/bin/bash
#
# faceformacOS installer — builds and installs the face-unlock stack:
#
#   /usr/local/bin/faceunlock-{enroll,verify,autofill}   CLIs
#   /usr/local/share/faceunlock/FaceEmbedding.mlmodelc   Core ML model
#   /usr/local/lib/pam/pam_faceunlock.so.2               PAM module
#   /etc/pam.d/sudo_local (or sudo)                      auth wiring
#
# Face auth is wired as `sufficient` with attempts=2: two camera attempts,
# then normal password auth. Every /etc/pam.d file touched is backed up first.
#
# Usage:
#   sudo ./scripts/install.sh [options]
#
# Options:
#   --screensaver     also wire the lock screen (/etc/pam.d/screensaver) —
#                     Howdy-style, read the README caveats first
#   --attempts <1-5>  face attempts before password fallback (default 2)
#   --timeout <1-60>  seconds per attempt (default 10)
#   --yes             don't ask for confirmation
#   --uninstall       remove PAM wiring and installed files
#   --help            show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

BIN_DIR="/usr/local/bin"
SHARE_DIR="/usr/local/share/faceunlock"
PAM_LIB_DIR="/usr/local/lib/pam"
PAM_MODULE_INSTALLED="$PAM_LIB_DIR/pam_faceunlock.so.2"

PAM_SUDO="/etc/pam.d/sudo"
PAM_SUDO_LOCAL="/etc/pam.d/sudo_local"
PAM_SUDO_LOCAL_TEMPLATE="/etc/pam.d/sudo_local.template"
PAM_SCREENSAVER="/etc/pam.d/screensaver"
PAM_MARKER="pam_faceunlock.so"

MODEL_NAME="FaceEmbedding.mlmodelc"
MODEL_SOURCE="$REPO_ROOT/FaceGate/ML/$MODEL_NAME"

ATTEMPTS=2
TIMEOUT=10
WIRE_SCREENSAVER=0
ASSUME_YES=0
UNINSTALL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}→${NC} $*"; }
ok()    { echo -e "${GREEN}✓${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC} $*"; }
fail()  { echo -e "${RED}✗ $*${NC}" >&2; exit 1; }

usage() {
    sed -n '2,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --screensaver) WIRE_SCREENSAVER=1 ;;
        --attempts)
            shift; [ $# -gt 0 ] || fail "--attempts needs a value"
            ATTEMPTS="$1"
            [[ "$ATTEMPTS" =~ ^[1-5]$ ]] || fail "--attempts must be 1..5"
            ;;
        --timeout)
            shift; [ $# -gt 0 ] || fail "--timeout needs a value"
            TIMEOUT="$1"
            [[ "$TIMEOUT" =~ ^[0-9]+$ ]] && [ "$TIMEOUT" -ge 1 ] && [ "$TIMEOUT" -le 60 ] \
                || fail "--timeout must be 1..60 seconds"
            ;;
        --yes|-y) ASSUME_YES=1 ;;
        --uninstall) UNINSTALL=1 ;;
        --help|-h) usage ;;
        *) fail "unknown option '$1' (see --help)" ;;
    esac
    shift
done

PAM_LINE="auth       sufficient     pam_faceunlock.so attempts=$ATTEMPTS timeout=$TIMEOUT"

[ "$(uname -s)" = "Darwin" ] || fail "faceformacOS only installs on macOS"
[ "$(id -u)" -eq 0 ] || fail "run with sudo: sudo ./scripts/install.sh"

BUILD_USER="${SUDO_USER:-}"

confirm() {
    local prompt="$1"
    [ "$ASSUME_YES" -eq 1 ] && return 0
    if [ ! -t 0 ] && [ ! -r /dev/tty ]; then
        fail "no terminal to confirm '$prompt' — re-run with --yes"
    fi
    read -r -p "$prompt (y/N) " reply < /dev/tty
    [[ "$reply" =~ ^[Yy]$ ]]
}

backup_file() {
    local target="$1"
    [ -f "$target" ] || return 0
    local backup="${target}.faceunlock-bak.$(date +%Y%m%d%H%M%S)"
    cp -p "$target" "$backup"
    ok "backed up $target → $backup"
}

# Rewrite a pam.d file atomically, preserving root:wheel 444.
write_pam_file() {
    local target="$1" content="$2"
    local tmp
    tmp="$(mktemp "${target}.faceunlock.XXXXXX")"
    printf '%s\n' "$content" > "$tmp"
    chown root:wheel "$tmp"
    chmod 444 "$tmp"
    mv -f "$tmp" "$target"
}

# Remove any pam_faceunlock lines, then insert $PAM_LINE before the first
# active (non-comment, non-blank) line so `sufficient` is evaluated first.
wire_pam_file() {
    local target="$1"
    local current stripped wired

    current="$(cat "$target")"
    stripped="$(printf '%s\n' "$current" | grep -v "$PAM_MARKER" || true)"
    wired="$(printf '%s\n' "$stripped" | awk -v line="$PAM_LINE" '
        !inserted && $0 !~ /^#/ && NF > 0 { print line; inserted = 1 }
        { print }
        END { if (!inserted) print line }
    ')"

    backup_file "$target"
    write_pam_file "$target" "$wired"
    ok "wired face auth into $target"
}

unwire_pam_file() {
    local target="$1"
    [ -f "$target" ] || return 0
    grep -q "$PAM_MARKER" "$target" || return 0
    backup_file "$target"
    write_pam_file "$target" "$(grep -v "$PAM_MARKER" "$target" || true)"
    ok "removed face auth from $target"
}

uninstall() {
    echo ""
    warn "Uninstalling faceformacOS face auth"
    confirm "Remove PAM wiring and installed binaries?" || { echo "Cancelled."; exit 0; }

    unwire_pam_file "$PAM_SUDO_LOCAL"
    unwire_pam_file "$PAM_SUDO"
    unwire_pam_file "$PAM_SCREENSAVER"

    rm -f "$PAM_MODULE_INSTALLED"
    rm -f "$BIN_DIR/faceunlock-enroll" "$BIN_DIR/faceunlock-verify" "$BIN_DIR/faceunlock-autofill"
    rm -rf "$SHARE_DIR"
    ok "removed installed files"

    echo ""
    warn "Per-user enrollment data (~/Library/Application Support/faceunlock) and"
    warn "Keychain keys were left in place. Remove them per user with:"
    echo "    faceunlock-enroll --remove   (before uninstalling, while the CLI exists)"
    echo "    security delete-generic-password -s com.faceformacos.faceunlock"
    echo ""
    ok "Uninstall complete — password auth is unaffected."
    exit 0
}

[ "$UNINSTALL" -eq 1 ] && uninstall

echo ""
echo -e "${BLUE}faceformacOS installer${NC} — face unlock with $ATTEMPTS attempt(s), then password"
echo ""

# ── Preflight ────────────────────────────────────────────────────────────────
command -v swift >/dev/null 2>&1 || fail "Swift toolchain not found — install Xcode Command Line Tools: xcode-select --install"
command -v make  >/dev/null 2>&1 || fail "make not found — install Xcode Command Line Tools"
[ -d "$MODEL_SOURCE" ] || fail "bundled model missing at $MODEL_SOURCE"

warn "Editing /etc/pam.d can lock you out if done wrong. This installer wires"
warn "face auth as 'sufficient' (password always remains a fallback) and backs"
warn "up every file it touches. Keep this shell open and test sudo in a NEW"
warn "terminal before relying on it."
echo ""
confirm "Proceed with install?" || { echo "Cancelled."; exit 0; }
echo ""

# ── Build ────────────────────────────────────────────────────────────────────
info "Building Swift package (release)…"
if [ -n "$BUILD_USER" ]; then
    sudo -u "$BUILD_USER" -H swift build -c release --package-path "$REPO_ROOT"
else
    warn "SUDO_USER not set — building as root (build artifacts will be root-owned)"
    swift build -c release --package-path "$REPO_ROOT"
fi
ok "Swift build complete"

info "Building PAM module…"
if [ -n "$BUILD_USER" ]; then
    sudo -u "$BUILD_USER" make -C "$REPO_ROOT/pam"
else
    make -C "$REPO_ROOT/pam"
fi
ok "PAM module built"

RELEASE_DIR="$REPO_ROOT/.build/release"
for tool in faceunlock-enroll faceunlock-verify faceunlock-autofill; do
    [ -x "$RELEASE_DIR/$tool" ] || fail "expected build product missing: $RELEASE_DIR/$tool"
done

# ── Install files ────────────────────────────────────────────────────────────
info "Installing CLIs to $BIN_DIR…"
install -d -m 755 "$BIN_DIR"
for tool in faceunlock-enroll faceunlock-verify faceunlock-autofill; do
    install -m 755 -o root -g wheel "$RELEASE_DIR/$tool" "$BIN_DIR/$tool"
done
ok "CLIs installed"

info "Installing Core ML model to $SHARE_DIR…"
install -d -m 755 -o root -g wheel "$SHARE_DIR"
rm -rf "${SHARE_DIR:?}/$MODEL_NAME"
cp -R "$MODEL_SOURCE" "$SHARE_DIR/$MODEL_NAME"
chown -R root:wheel "$SHARE_DIR/$MODEL_NAME"
chmod -R a+rX,go-w "$SHARE_DIR/$MODEL_NAME"
ok "Model installed"

info "Installing PAM module to $PAM_MODULE_INSTALLED…"
install -d -m 755 -o root -g wheel "$PAM_LIB_DIR"
install -m 444 -o root -g wheel "$REPO_ROOT/pam/pam_faceunlock.so" "$PAM_MODULE_INSTALLED"
ok "PAM module installed"

# ── Wire PAM: sudo ───────────────────────────────────────────────────────────
# macOS 14+ ships an `include sudo_local` hook precisely so third-party auth
# survives OS updates — prefer it; fall back to editing /etc/pam.d/sudo.
if grep -Eq '^[^#]*include[[:space:]]+sudo_local' "$PAM_SUDO" 2>/dev/null; then
    if [ ! -f "$PAM_SUDO_LOCAL" ]; then
        if [ -f "$PAM_SUDO_LOCAL_TEMPLATE" ]; then
            cp "$PAM_SUDO_LOCAL_TEMPLATE" "$PAM_SUDO_LOCAL"
        else
            write_pam_file "$PAM_SUDO_LOCAL" "# sudo_local: local config file which survives system updates"
        fi
        chown root:wheel "$PAM_SUDO_LOCAL"
        chmod 444 "$PAM_SUDO_LOCAL"
    fi
    wire_pam_file "$PAM_SUDO_LOCAL"
else
    warn "$PAM_SUDO does not include sudo_local (macOS < 14?) — editing it directly"
    wire_pam_file "$PAM_SUDO"
fi

# ── Wire PAM: screensaver (opt-in) ───────────────────────────────────────────
if [ "$WIRE_SCREENSAVER" -eq 1 ]; then
    if [ -f "$PAM_SCREENSAVER" ]; then
        warn "Wiring the lock screen is Howdy-style and has caveats (camera access"
        warn "in a locked session is not guaranteed on every macOS version)."
        if confirm "Wire $PAM_SCREENSAVER too?"; then
            wire_pam_file "$PAM_SCREENSAVER"
        else
            warn "skipped screensaver wiring"
        fi
    else
        warn "$PAM_SCREENSAVER not found — skipping screensaver wiring"
    fi
fi

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
ok "Install complete."
echo ""
echo "Next steps:"
echo "  1. Enroll your face (as your normal user, NOT root):"
echo "       faceunlock-enroll"
echo "  2. Test recognition ($ATTEMPTS attempts, then it gives up):"
echo "       faceunlock-verify"
echo "  3. KEEP THIS SHELL OPEN, then in a NEW terminal test:"
echo "       sudo -k true    # should offer face auth, then password"
echo ""
echo "The first camera use will trigger a macOS permission prompt for your"
echo "terminal app — grant it in System Settings → Privacy & Security → Camera."
echo ""
echo "Uninstall anytime with: sudo ./scripts/install.sh --uninstall"
