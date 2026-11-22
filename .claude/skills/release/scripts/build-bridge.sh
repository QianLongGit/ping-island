#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# PingIslandBridge Linux 构建脚本 v2（T8 真机验收修复）
# 变更：去掉 -Xclang-linker（SwiftPM ArgumentParser 冲突致 -c 解析失败），
#       链接路径改经 LIBRARY_PATH，sqlite3 经 modulemap link 指令自动链接。
# 环境：Ubuntu 26.04 + Swift 6.1 (24.04 工具链) + 用户目录兼容库
# ╓ 产物：Prototype/.build/release/PingIslandBridge
# ═══════════════════════════════════════════════════════════════════
set -o pipefail

export PATH="$HOME/.local/opt/swift/usr/bin:$PATH"
export LD_LIBRARY_PATH="$HOME/.local/opt/compat-libs"
export LIBRARY_PATH="$HOME/.local/opt/sqlite-dev/extracted/usr/lib/x86_64-linux-gnu"

REPO=/home/ql/Development/Project/my-vibeisland/ping-island
cd "$REPO" || exit 64

T0=$(date +%s)
swift build -c release \
  --package-path Prototype \
  --product PingIslandBridge \
  --jobs 4 \
  -Xcc "-fmodule-map-file=$HOME/.local/opt/sqlite-dev/module.modulemap" \
  -Xcc "-I$HOME/.local/opt/sqlite-dev/extracted/usr/include" \
  2>&1 | tee /tmp/bridge-build.log | tail -40
RC=${PIPESTATUS[0]}
echo "EXIT_$RC ELAPSED_$(( $(date +%s) - T0 ))s" | tee -a /tmp/bridge-build.log
exit "$RC"
