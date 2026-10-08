#!/usr/bin/env bash
#
# build-install.sh — build the gnatcode native binary and install it globally via npm.
#
# This produces a self-contained, fast-starting `gnatcode` executable (no Bun
# required at runtime) and installs it with `npm install -g`.
#
# Usage:
#   ./script/build-install.sh              # build for this platform, install globally
#   ./script/build-install.sh --no-install # build only, don't install
#   ./script/build-install.sh --uninstall  # remove the global install
#
# Environment overrides:
#   GNATCODE_NAME     command/binary name to install (default: gnatcode)
#   GNATCODE_PREFIX   npm global prefix to install into (default: npm's configured prefix)
#
set -euo pipefail

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_PATH/.." && pwd)"
PKG_DIR="$REPO_DIR/packages/opencode"
NAME="${GNATCODE_NAME:-gnatcode}"
STAGE_DIR="$PKG_DIR/dist/gnatcode-pkg"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m warn:\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--uninstall" ]]; then
  info "Uninstalling global package: $NAME"
  npm uninstall -g "$NAME" || warn "nothing to uninstall"
  info "Done."
  exit 0
fi

NO_INSTALL=0
[[ "${1:-}" == "--no-install" ]] && NO_INSTALL=1

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
[[ -d "$PKG_DIR" ]] || fail "could not find $PKG_DIR — is this a gnatcode checkout?"

BUN_BIN="$(command -v bun || true)"
if [[ -z "$BUN_BIN" ]]; then
  for candidate in "$HOME/.node_modules/bin/bun" /opt/homebrew/bin/bun /usr/local/bin/bun; do
    [[ -x "$candidate" ]] && BUN_BIN="$candidate" && break
  done
fi
[[ -n "$BUN_BIN" && -x "$BUN_BIN" ]] || fail "bun not found. Install it first: npm install -g bun"

command -v npm >/dev/null || fail "npm not found"
info "Repository: $REPO_DIR"
info "Using bun:  $BUN_BIN ($("$BUN_BIN" --version))"
info "npm:        $(npm --version)"

[[ -d "$REPO_DIR/node_modules" ]] || {
  info "Installing dependencies (bun install --ignore-scripts)"
  ( cd "$REPO_DIR" && "$BUN_BIN" install --ignore-scripts )
}

# ---------------------------------------------------------------------------
# Build the native binary for this platform only.
# ---------------------------------------------------------------------------
info "Building native binary (single platform)"
( cd "$PKG_DIR" && "$BUN_BIN" run script/build.ts --single --skip-install )

detect_target() {
  case "$(uname -s)" in
    Darwin) echo "darwin" ;;
    Linux) echo "linux" ;;
    MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
    *) fail "unsupported OS: $(uname -s)" ;;
  esac
}
detect_arch() {
  case "$(uname -m)" in
    arm64|aarch64) echo "arm64" ;;
    x86_64|amd64) echo "x64" ;;
    *) fail "unsupported arch: $(uname -m)" ;;
  esac
}

TARGET_OS="$(detect_target)"
TARGET_ARCH="$(detect_arch)"
# The build always names its output after the package name ("opencode"),
# independent of the command name we install under.
DIST_NAME="opencode-$TARGET_OS-$TARGET_ARCH"
BINARY_BASENAME="$NAME"
[[ "$TARGET_OS" == "windows" ]] && BINARY_BASENAME="$NAME.exe"
SRC_BINARY="$PKG_DIR/dist/$DIST_NAME/bin/opencode"

[[ -f "$SRC_BINARY" ]] || fail "build produced no binary at $SRC_BINARY (looked for $DIST_NAME)"

# ---------------------------------------------------------------------------
# Stage a minimal npm package around the compiled binary.
# ---------------------------------------------------------------------------
info "Staging package in $STAGE_DIR"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR/bin"
cp "$SRC_BINARY" "$STAGE_DIR/bin/$BINARY_BASENAME"
chmod +x "$STAGE_DIR/bin/$BINARY_BASENAME"
[[ -f "$REPO_DIR/LICENSE" ]] && cp "$REPO_DIR/LICENSE" "$STAGE_DIR/LICENSE"

VERSION="$(cd "$PKG_DIR" && "$BUN_BIN" -e 'import("./package.json").then(p=>console.log(p.default.version))' 2>/dev/null || echo "0.0.0-local")"

cat > "$STAGE_DIR/package.json" <<EOF
{
  "name": "$NAME",
  "version": "$VERSION",
  "description": "gnatcode — the AI coding agent for the terminal (local build)",
  "bin": {
    "$NAME": "bin/$BINARY_BASENAME"
  },
  "license": "MIT",
  "os": ["$TARGET_OS"],
  "cpu": ["$TARGET_ARCH"],
  "preferUnplugged": true
}
EOF

info "Built: $STAGE_DIR/bin/$BINARY_BASENAME ($(du -h "$STAGE_DIR/bin/$BINARY_BASENAME" | cut -f1))"

# ---------------------------------------------------------------------------
# Install globally.
# ---------------------------------------------------------------------------
if [[ "$NO_INSTALL" == "1" ]]; then
  info "Skipping install (--no-install). To install manually:"
  echo "    npm install -g \"$STAGE_DIR\""
  exit 0
fi

info "Installing globally via npm"
NPM_FLAGS=(-g)
[[ -n "${GNATCODE_PREFIX:-}" ]] && NPM_FLAGS+=(--prefix "$GNATCODE_PREFIX")
npm install "${NPM_FLAGS[@]}" "$STAGE_DIR"

PREFIX="$(npm config get prefix)"
info "Installed. Command should be on PATH:"
if command -v "$NAME" >/dev/null 2>&1; then
  RESOLVED="$(command -v "$NAME")"
  echo "    $RESOLVED"
  "$NAME" --version 2>/dev/null | tail -1 | sed 's/^/    version: /' || true
  NPM_BIN="$PREFIX/bin/$NAME"
  if [[ "$RESOLVED" != "$NPM_BIN" && -e "$NPM_BIN" ]]; then
    warn "another '$NAME' earlier on PATH shadows this install:"
    warn "  using:     $RESOLVED"
    warn "  npm put:   $NPM_BIN"
    warn "Remove the other copy (or reorder PATH) if you want the npm build active."
  fi
else
  warn "'$NAME' not found on PATH. npm global bin is usually: $PREFIX/bin"
  warn "Add it to PATH, then try again: export PATH=\"$PREFIX/bin:\$PATH\""
fi

cat <<EOF

$(info "Done")

  Run:  $NAME
  Or:   $NAME --help

  Binary: $STAGE_DIR/bin/$BINARY_BASENAME
  Remove: $REPO_DIR/script/build-install.sh --uninstall

EOF
