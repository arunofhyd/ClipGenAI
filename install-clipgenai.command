#!/usr/bin/env bash
# =============================================================================
#  ClipGenAI — Builder & Installer
#  Built by Arun Thomas · https://github.com/arunofhyd/ClipGenAI
#
#  Builds the app LOCALLY on your Mac so Gatekeeper trusts it automatically.
# =============================================================================

set -e

APP_NAME="ClipGenAI"
BUNDLE_NAME="ClipGenAI.app"
DEST_APP="/Applications/$BUNDLE_NAME"
REPO_RAW="https://raw.githubusercontent.com/arunofhyd/ClipGenAI/main"

# ── Terminal Styling (Strict ShellCheck SC2059 compliance) ──
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
CYAN='\033[38;5;45m'; GREEN='\033[38;5;35m'; YELLOW='\033[38;5;220m'; RED='\033[38;5;196m'; GREY='\033[38;5;245m'

line() { printf '%b\n' "${DIM}────────────────────────────────────────────────────────────${NC}"; }
step() { printf '%b▸%b %b%s%b\n' "${CYAN}${BOLD}" "${NC}" "${BOLD}" "$1" "${NC}"; }
ok()   { printf '  %b✓%b %s\n' "${GREEN}" "${NC}" "$1"; }
warn() { printf '  %b!%b %s\n' "${YELLOW}" "${NC}" "$1"; }
fail() { printf '  %b✗ %s%b\n' "${RED}" "$1" "${NC}"; }

if [ "$CI" != "true" ]; then clear; fi

printf "\n"
printf '%b\n' "${CYAN}${BOLD}   ${APP_NAME}${NC}"
printf '%b\n' "${GREY}   AI LLM Floating Clipboard HUD for macOS${NC}"
printf '%b\n\n' "${GREY}   Built with ❤️ by Arun Thomas · https://github.com/arunofhyd/ClipGenAI${NC}"
line
printf "\n"

# ── Step 1: Check Xcode Command Line Tools ──
step "Checking build tools..."
if ! command -v swiftc >/dev/null 2>&1; then
    warn "Xcode Command Line Tools are needed to compile the native Swift binary."
    xcode-select --install >/dev/null 2>&1 || true
    printf '%b\n' "  ${YELLOW}When the Command Line Tools installation finishes, rerun this script.${NC}"
    exit 1
fi
ok "Swift compiler available ($(swiftc --version | head -n1))"

# ── Step 2: Source Setup ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
WORK_DIR=""

if [ -f "$SCRIPT_DIR/ClipGenAI.swift" ] && [ -f "$SCRIPT_DIR/build_app.sh" ]; then
    step "Building from local repository..."
    SRC_DIR="$SCRIPT_DIR"
else
    step "Downloading latest source from GitHub..."
    WORK_DIR="$(mktemp -d /tmp/clipgenai_build_XXXXXX)"
    SRC_DIR="$WORK_DIR"
    curl -fsSL "$REPO_RAW/ClipGenAI.swift" -o "$SRC_DIR/ClipGenAI.swift"
    curl -fsSL "$REPO_RAW/Info.plist" -o "$SRC_DIR/Info.plist"
    curl -fsSL "$REPO_RAW/version.json" -o "$SRC_DIR/version.json" 2>/dev/null || true
    curl -fsSL "$REPO_RAW/AppIcon.icns" -o "$SRC_DIR/AppIcon.icns" 2>/dev/null || true
    curl -fsSL "$REPO_RAW/AppIcon.png" -o "$SRC_DIR/AppIcon.png" 2>/dev/null || true
    curl -fsSL "$REPO_RAW/build_app.sh" -o "$SRC_DIR/build_app.sh"
    chmod +x "$SRC_DIR/build_app.sh"
fi

# ── Step 3: Compile and Package App ──
step "Compiling native app bundle..."
(cd "$SRC_DIR" && ./build_app.sh)
ok "Built ${BUNDLE_NAME} successfully"

# ── Step 4: Install to /Applications ──
step "Installing to /Applications..."
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.5
rm -rf "$DEST_APP" 2>/dev/null || true
cp -R "$SRC_DIR/$BUNDLE_NAME" "$DEST_APP"
ok "Installed to $DEST_APP"

# Clean up temp files if created
if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
    rm -rf "$WORK_DIR"
fi

# ── Step 5: Launch App (Skip if in CI) ──
if [ "$CI" != "true" ]; then
    step "Launching ${APP_NAME}..."
    open "$DEST_APP"
    ok "${APP_NAME} is now running!"
fi

line
printf "\n"
printf '%b\n' "${GREEN}${BOLD}   ✨ Installation Complete!${NC}"
printf '%b\n' "${GREY}   ClipGenAI is active in your menu bar (✨).${NC}"
printf '%b\n' "${GREY}   Configure your Gemini API key in Settings, then copy any text to see it in action!${NC}\n\n"
