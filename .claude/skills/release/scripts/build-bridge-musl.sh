#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# PingIslandBridge musl 交叉构建脚本（T8 双 arch 补齐）
# 用法: build-bridge-musl.sh <aarch64|x86_64>
# 产物: Prototype/.build/<triple>/release/PingIslandBridge（真 musl 静态）
# ═══════════════════════════════════════════════════════════════════
set -o pipefail
ARCH="${1:?usage: $0 <aarch64|x86_64>}"

export PATH="$HOME/.local/opt/swift/usr/bin:$PATH"
export LD_LIBRARY_PATH="$HOME/.local/opt/compat-libs"
export LIBRARY_PATH="$HOME/.local/opt/sqlite-dev/musl-$ARCH"

REPO=/home/ql/Development/Project/my-vibeisland/ping-island
cd "$REPO" || exit 64

T0=$(date +%s)
swift build -c release \
  --package-path Prototype \
  --product PingIslandBridge \
  --jobs 4 \
  --swift-sdk "${ARCH}-swift-linux-musl" \
  -Xcc "-fmodule-map-file=$HOME/.local/opt/sqlite-dev/module-musl.modulemap" \
  -Xcc "-I$HOME/.local/opt/sqlite-dev/sqlite-amalgamation-3500400" \
  2>&1 | tail -30
RC=${PIPESTATUS[0]}
echo "EXIT_$RC ARCH_$ARCH ELAPSED_$(( $(date +%s) - T0 ))s"
exit "$RC"
