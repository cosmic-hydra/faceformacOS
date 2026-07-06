#!/bin/bash
# faceformacOS installer.
#
#   sudo ./scripts/install.sh [--enable-sudo] [--enable-screensaver] [--liveness]
#
# Steps:
#   1. Build the CLIs (swift build -c release) and the PAM module (clang),
#      as the invoking user — never as root.
#   2. Install binaries to /usr/local/bin and the module to /usr/local/lib/pam
#      (/usr/lib/pam is on the SIP-sealed system volume — do NOT touch it).
#   3. Copy the Core ML model into the invoking user's
#      ~/Library/Application Support/FaceUnlock/model.mlmodelc
#   4. Optionally wire /etc/pam.d — every touched file is backed up first,
#      and the module is added as `sufficient`, so password auth ALWAYS
#      still works. Keep a root shell open and test `sudo -k; sudo true`
#      in a NEW terminal before you rely on it.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR=/usr/local/bin
PAM_DIR=/usr/local/lib/pam
MODULE="$PAM_DIR/pam_faceunlock.so"
PAM_ARGS=""
ENABLE_SUDO=0
ENABLE_SCREENSAVER=0

for arg in "$@"; do
    case "$arg" in
        --enable-sudo)         ENABLE_SUDO=1 ;;
        --enable-screensaver)  ENABLE_SCREENSAVER=1 ;;
        --liveness)            PAM_ARGS=" require_liveness" ;;
        -h|--help)
            sed -n '2,16p' "$0"; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo: sudo $0 $*" >&2
    exit 1
fi
if [[ "$(uname)" != "Darwin" ]]; then
    echo "This installer only runs on macOS." >&2
    exit 1
fi

REAL_USER="${SUDO_USER:-$(stat -f '%Su' /dev/console)}"
if [[ -z "$REAL_USER" || "$REAL_USER" == "root" ]]; then
    echo "Could not determine the non-root invoking user (run via sudo)." >&2
    exit 1
fi
REAL_HOME="$(dscl . -read "/Users/$REAL_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
[[ -n "$REAL_HOME" ]] || REAL_HOME="/Users/$REAL_USER"

echo "==> Building (as $REAL_USER)…"
sudo -u "$REAL_USER" -H bash -c "cd '$REPO_ROOT' && swift build -c release"
sudo -u "$REAL_USER" -H bash -c "cd '$REPO_ROOT/pam' && make"

RELEASE_DIR="$(sudo -u "$REAL_USER" -H bash -c "cd '$REPO_ROOT' && swift build -c release --show-bin-path")"
for tool in faceunlock-enroll faceunlock-verify faceunlock-autofill; do
    [[ -x "$RELEASE_DIR/$tool" ]] || { echo "build artifact missing: $tool" >&2; exit 1; }
done

echo "==> Installing binaries to $BIN_DIR…"
install -d -o root -g wheel -m 755 "$BIN_DIR"
for tool in faceunlock-enroll faceunlock-verify faceunlock-autofill; do
    install -o root -g wheel -m 755 "$RELEASE_DIR/$tool" "$BIN_DIR/$tool"
done

echo "==> Installing PAM module to $MODULE…"
install -d -o root -g wheel -m 755 "$PAM_DIR"
install -o root -g wheel -m 444 "$REPO_ROOT/pam/pam_faceunlock.so" "$MODULE"

echo "==> Installing the Core ML model for $REAL_USER…"
MODEL_SRC="$REPO_ROOT/FaceGate/ML/FaceEmbedding.mlmodelc"
MODEL_DST="$REAL_HOME/Library/Application Support/FaceUnlock/model.mlmodelc"
if [[ -d "$MODEL_SRC" ]]; then
    sudo -u "$REAL_USER" -H mkdir -p "$(dirname "$MODEL_DST")"
    sudo -u "$REAL_USER" -H chmod 700 "$(dirname "$MODEL_DST")"
    sudo -u "$REAL_USER" -H rm -rf "$MODEL_DST"
    sudo -u "$REAL_USER" -H cp -R "$MODEL_SRC" "$MODEL_DST"
else
    echo "    (model not found at $MODEL_SRC — faceunlock-enroll --model can install one later)"
fi

PAM_LINE="auth       sufficient     $MODULE$PAM_ARGS"

backup() {
    local file="$1"
    cp "$file" "$file.faceunlock-backup.$(date +%Y%m%d%H%M%S)"
}

# Insert $PAM_LINE as the first auth rule of a pam.d file, preserving perms.
patch_pam_file() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        echo "    $file does not exist — skipping" >&2
        return
    fi
    if grep -q "pam_faceunlock.so" "$file"; then
        echo "    $file already contains pam_faceunlock — skipping"
        return
    fi
    backup "$file"
    local tmp
    tmp="$(mktemp)"
    awk -v line="$PAM_LINE" '
        !inserted && $1 == "auth" { print line; inserted = 1 }
        { print }
        END { if (!inserted) print line }
    ' "$file" > "$tmp"
    # Refuse to install a file that somehow lost the original rules.
    if ! grep -q "pam_faceunlock.so" "$tmp" || \
       [[ "$(grep -c . "$tmp")" -le "$(grep -c . "$file")" ]]; then
        echo "    patch of $file failed sanity check — leaving it untouched" >&2
        rm -f "$tmp"
        return 1
    fi
    local mode
    mode="$(stat -f '%Lp' "$file")"
    chown root:wheel "$tmp"
    chmod "$mode" "$tmp"
    mv "$tmp" "$file"
    echo "    patched $file"
}

if [[ $ENABLE_SUDO -eq 1 ]]; then
    echo "==> Enabling face unlock for sudo…"
    if grep -q "sudo_local" /etc/pam.d/sudo 2>/dev/null; then
        # Modern macOS: /etc/pam.d/sudo_local survives OS updates.
        if [[ ! -f /etc/pam.d/sudo_local ]]; then
            if [[ -f /etc/pam.d/sudo_local.template ]]; then
                cp /etc/pam.d/sudo_local.template /etc/pam.d/sudo_local
            else
                printf '# sudo_local: local config file which survives system update\n' > /etc/pam.d/sudo_local
            fi
            chown root:wheel /etc/pam.d/sudo_local
            chmod 444 /etc/pam.d/sudo_local
        fi
        if grep -q "pam_faceunlock.so" /etc/pam.d/sudo_local; then
            echo "    /etc/pam.d/sudo_local already contains pam_faceunlock — skipping"
        else
            backup /etc/pam.d/sudo_local
            tmp="$(mktemp)"
            { printf '%s\n' "$PAM_LINE"; cat /etc/pam.d/sudo_local; } > "$tmp"
            mode="$(stat -f '%Lp' /etc/pam.d/sudo_local)"
            chown root:wheel "$tmp"
            chmod "$mode" "$tmp"
            mv "$tmp" /etc/pam.d/sudo_local
            echo "    patched /etc/pam.d/sudo_local"
        fi
    else
        patch_pam_file /etc/pam.d/sudo
    fi
    echo "    IMPORTANT: keep this root shell open and test in a NEW terminal:"
    echo "        sudo -k; sudo true"
fi

if [[ $ENABLE_SCREENSAVER -eq 1 ]]; then
    echo "==> Enabling face unlock for the screensaver (experimental)…"
    patch_pam_file /etc/pam.d/screensaver || true
    echo "    Note: camera access from the lock-screen context is not"
    echo "    guaranteed on all macOS versions — test before relying on it."
fi

SUDO_HINT=""
if [[ $ENABLE_SUDO -eq 0 ]]; then
    SUDO_HINT="
To wire up sudo later:  sudo ./scripts/install.sh --enable-sudo
(or add this line yourself to /etc/pam.d/sudo_local):"
fi

cat <<EOF

Installed. Next steps (as $REAL_USER, in a normal terminal):

  1. Enroll your face:      faceunlock-enroll --user $REAL_USER --frames 9
  2. Test verification:     faceunlock-verify --user $REAL_USER --timeout 10
  3. Store a credential:    faceunlock-autofill set --label github
$SUDO_HINT
  PAM line: $PAM_LINE

Uninstall any time with: sudo ./scripts/uninstall.sh
EOF
