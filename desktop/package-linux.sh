#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

name="bullshit-notch-linux-x86_64"
dist="$root/dist"
stage="$dist/$name"
mkdir -p "$stage"

cargo build --manifest-path desktop/Cargo.toml --release

bin="desktop/target/release/bullshit-notch-desktop"
if [[ ! -x "$bin" ]]; then
  bin="desktop/target/release/bullshit_notch_desktop"
fi
install -m 0755 "$bin" "$stage/bullshit-notch"
cp desktop/README.md "$stage/README.md" 2>/dev/null || true
cat > "$stage/README.txt" <<'EOF'
BullshitNotch desktop (Linux)

Force X11/XWayland (already set at runtime). Demo:

  ./bullshit-notch --demo
  ./bullshit-notch --open --demo

Needs a session bus for MPRIS + tray (StatusNotifierItem).
EOF

mkdir -p "$dist"
tar -C "$dist" -czf "$dist/${name}.tar.gz" "$name"
echo "wrote $dist/${name}.tar.gz"
