#!/bin/bash
# faceformacOS uninstaller.
#
#   sudo ./scripts/uninstall.sh [--purge]
#
# Removes the PAM wiring first (so auth can never dangle on a missing
# module), then the module and binaries. --purge also deletes the invoking
# user's enrollment/vault data in ~/Library/Application Support/FaceUnlock.
set -euo pipefail

BIN_DIR=/usr/local/bin
MODULE=/usr/local/lib/pam/pam_faceunlock.so
PURGE=0

for arg in "$@"; do
    case "$arg" in
        --purge) PURGE=1 ;;
        -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo: sudo $0 $*" >&2
    exit 1
fi

# 1. Strip our line from every pam.d file that has it.
for file in /etc/pam.d/sudo_local /etc/pam.d/sudo /etc/pam.d/screensaver /etc/pam.d/login; do
    [[ -f "$file" ]] || continue
    grep -q "pam_faceunlock.so" "$file" || continue
    cp "$file" "$file.faceunlock-backup.$(date +%Y%m%d%H%M%S)"
    tmp="$(mktemp)"
    grep -v "pam_faceunlock.so" "$file" > "$tmp" || true
    if [[ ! -s "$tmp" && -s "$file" ]]; then
        # A pam.d file reduced to nothing means it only contained our line
        # (sudo_local case) — keep a comment so the file stays valid.
        printf '# sudo_local: local config file which survives system update\n' > "$tmp"
    fi
    mode="$(stat -f '%Lp' "$file")"
    chown root:wheel "$tmp"
    chmod "$mode" "$tmp"
    mv "$tmp" "$file"
    echo "removed pam_faceunlock from $file"
done

# 2. Module + binaries.
rm -f "$MODULE"
for tool in faceunlock-enroll faceunlock-verify faceunlock-autofill; do
    rm -f "$BIN_DIR/$tool"
done
echo "removed module and binaries"

# 3. User data (opt-in).
if [[ $PURGE -eq 1 ]]; then
    REAL_USER="${SUDO_USER:-}"
    if [[ -n "$REAL_USER" && "$REAL_USER" != "root" ]]; then
        REAL_HOME="$(dscl . -read "/Users/$REAL_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
        [[ -n "$REAL_HOME" ]] || REAL_HOME="/Users/$REAL_USER"
        rm -rf "$REAL_HOME/Library/Application Support/FaceUnlock"
        echo "purged $REAL_HOME/Library/Application Support/FaceUnlock"
        echo "note: Keychain items under service com.faceformacos.FaceUnlock"
        echo "      can be removed with Keychain Access.app if desired."
    else
        echo "--purge: could not determine invoking user — skipping data removal" >&2
    fi
fi

echo "done."
