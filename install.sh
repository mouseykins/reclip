#!/usr/bin/env bash
# Reclip installer for macOS
# Installs Homebrew (if missing), dependencies, and the latest Reclip release.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/mouseykins/reclip/main/install.sh | bash

set -euo pipefail

REPO="mouseykins/reclip"
APP_NAME="Reclip"
INSTALL_DIR="/Applications"

bold() { printf "\033[1m%s\033[0m\n" "$*"; }
info() { printf "  %s\n" "$*"; }
warn() { printf "\033[33m  %s\033[0m\n" "$*"; }
err()  { printf "\033[31m  %s\033[0m\n" "$*" >&2; }
ok()   { printf "\033[32m  ✓ %s\033[0m\n" "$*"; }

bold "Reclip installer"
echo

# --- 1. Detect or install Homebrew -----------------------------------------
if command -v brew >/dev/null 2>&1; then
    ok "Homebrew is installed ($(brew --prefix))"
else
    warn "Homebrew not found — installing now..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # Add brew to PATH for the rest of this session
    if [[ -x /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -x /usr/local/bin/brew ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
    ok "Homebrew installed"
fi
echo

# --- 2. Install dependencies -----------------------------------------------
bold "Installing dependencies (yt-dlp, ffmpeg, deno)"
brew install yt-dlp ffmpeg deno
echo
ok "Dependencies installed"
echo

# --- 3. Download latest Reclip release -------------------------------------
bold "Downloading latest ${APP_NAME}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

LATEST_JSON=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest")
ZIP_URL=$(printf '%s' "$LATEST_JSON" \
    | grep -o '"browser_download_url": *"[^"]*\.zip"' \
    | head -1 \
    | sed 's/.*"\(https:[^"]*\)".*/\1/')

if [[ -z "$ZIP_URL" ]]; then
    err "Could not find a .zip asset in the latest release."
    err "Check https://github.com/${REPO}/releases for manual download."
    exit 1
fi

info "Source: $ZIP_URL"
curl -fL -o "$TMP/Reclip.zip" "$ZIP_URL"

# --- 4. Install to /Applications -------------------------------------------
bold "Installing to ${INSTALL_DIR}"
unzip -q "$TMP/Reclip.zip" -d "$TMP"

APP_IN_ZIP=$(find "$TMP" -maxdepth 2 -name "${APP_NAME}.app" -type d | head -1)
if [[ -z "$APP_IN_ZIP" ]]; then
    err "Could not find ${APP_NAME}.app inside the release archive."
    exit 1
fi

# Replace existing install
if [[ -d "${INSTALL_DIR}/${APP_NAME}.app" ]]; then
    info "Removing previous ${APP_NAME}.app..."
    rm -rf "${INSTALL_DIR}/${APP_NAME}.app"
fi

cp -R "$APP_IN_ZIP" "${INSTALL_DIR}/"

# Remove the quarantine xattr so Gatekeeper doesn't block first launch
if xattr -l "${INSTALL_DIR}/${APP_NAME}.app" 2>/dev/null | grep -q com.apple.quarantine; then
    xattr -dr com.apple.quarantine "${INSTALL_DIR}/${APP_NAME}.app" || true
fi
ok "Installed ${APP_NAME}.app at ${INSTALL_DIR}/${APP_NAME}.app"
echo

# --- 5. Launch -------------------------------------------------------------
bold "Done!"
info "Launching ${APP_NAME}..."
open "${INSTALL_DIR}/${APP_NAME}.app"
