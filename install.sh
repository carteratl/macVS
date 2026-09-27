#!/bin/bash
# install.sh - install macvs outside of TCC-protected folders and put it on your PATH.
#
#   ./install.sh              install/upgrade to $MACVS_PREFIX (default ~/.macvs/app)
#   ./install.sh --uninstall  remove the installed copy and the PATH symlink (VM data stays)
#
# Why copy instead of symlinking the clone? launchd jobs cannot execute files in
# ~/Documents, ~/Desktop, ~/Downloads (or iCloud Drive): macOS privacy controls (TCC)
# return "Operation not permitted". Installing a copy under ~/.macvs sidesteps that no
# matter where you keep the repository. Re-run this script after `git pull`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACVS_HOME="${MACVS_HOME:-$HOME/.macvs}"
MACVS_PREFIX="${MACVS_PREFIX:-$MACVS_HOME/app}"

say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

pick_bindir() {
  local d
  for d in "${MACVS_INSTALL_BIN:-}" /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin"; do
    [ -n "$d" ] || continue
    if [ -d "$d" ] && [ -w "$d" ]; then echo "$d"; return 0; fi
  done
  mkdir -p "$HOME/.local/bin"; echo "$HOME/.local/bin"
}

if [ "${1:-}" = "--uninstall" ]; then
  for d in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin" "${MACVS_INSTALL_BIN:-}"; do
    [ -n "$d" ] && [ -L "$d/macvs" ] && rm -f "$d/macvs" && say "removed $d/macvs"
  done
  if [ -d "$MACVS_PREFIX" ]; then rm -rf "$MACVS_PREFIX"; say "removed $MACVS_PREFIX"; fi
  say "macvs removed. VM data in $MACVS_HOME/vms was left untouched."
  exit 0
fi

[ "$(uname -s)" = Darwin ] || die "macvs runs on macOS only"
[ "$(uname -m)" = arm64 ]  || die "macvs needs Apple Silicon (arm64)"
command -v brew >/dev/null 2>&1 || die "Homebrew is required: https://brew.sh"

if ! command -v qemu-system-aarch64 >/dev/null 2>&1; then
  say "QEMU is not installed; installing with Homebrew"
  brew install qemu
fi

case "$MACVS_PREFIX" in
  "$HOME"/Documents*|"$HOME"/Desktop*|"$HOME"/Downloads*|"$HOME"/Library/Mobile\ Documents*)
    die "MACVS_PREFIX=$MACVS_PREFIX is inside a TCC-protected folder; launchd could not run it" ;;
esac

# Install a fresh copy (old copy replaced atomically).
say "installing macvs to $MACVS_PREFIX"
mkdir -p "$MACVS_HOME"
tmp="$MACVS_PREFIX.new.$$"
rm -rf "$tmp"; mkdir -p "$tmp"
cp -R "$ROOT/bin" "$ROOT/lib" "$ROOT/share" "$tmp/"
cp "$ROOT/README.md" "$tmp/"
chmod 755 "$tmp/bin/macvs"
rm -rf "$MACVS_PREFIX.old"
[ -d "$MACVS_PREFIX" ] && mv "$MACVS_PREFIX" "$MACVS_PREFIX.old"
mv "$tmp" "$MACVS_PREFIX"
rm -rf "$MACVS_PREFIX.old"

BINDIR="$(pick_bindir)"
ln -sfn "$MACVS_PREFIX/bin/macvs" "$BINDIR/macvs"
say "linked $BINDIR/macvs -> $MACVS_PREFIX/bin/macvs"

if [ ! -f "$MACVS_HOME/config" ]; then
  cp "$ROOT/share/macvs/macvs.conf.example" "$MACVS_HOME/config"
  say "wrote default config to $MACVS_HOME/config"
fi

case ":$PATH:" in
  *":$BINDIR:"*) ;;
  *) say "NOTE: add $BINDIR to your PATH, e.g.:  echo 'export PATH=\"$BINDIR:\$PATH\"' >> ~/.zshrc" ;;
esac

echo
"$BINDIR/macvs" doctor
echo
say "Next: macvs create myserver --start"
