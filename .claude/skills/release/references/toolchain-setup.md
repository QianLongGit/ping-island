# 工具链自建参考（首次 / 换机时用）

日常发布不读本文——SKILL.md 第 0 步检查全过即可跳过。仅在工具链缺失时按此重建。
以下全部路径经 2026-11-22 实机验证（Ubuntu 26.04 x86_64）。

目标布局（SKILL.md 与构建脚本依赖的绝对路径）：

```
~/.local/opt/swift/                          # Swift 6.1 工具链（usr/bin/swift 等）
~/.local/opt/compat-libs/                    # libxml2.so.2 + libicu74 soname 组（LD_LIBRARY_PATH）
~/.local/opt/sqlite-dev/                     # sqlite 注入件全集（modulemap ×2 + 头/库 ×3 套）
~/.swiftpm/swift-sdks/swift-6.1-RELEASE_static-linux-0.0.1.artifactbundle/
```

## §1 Swift 6.1 工具链

Ubuntu 26.04 无官方 tarball，用 24.04 版可直接跑（实测）：

```bash
mkdir -p ~/swift-dl ~/.local/opt && cd ~/swift-dl
# URL 模式（以 swift.org 下载页为准）：
#   https://download.swift.org/swift-6.1-release/ubuntu2404/swift-6.1-RELEASE/swift-6.1-RELEASE-ubuntu24.04.tar.gz
# ⚠️ 840MB 级大文件：勿放 /tmp（tmpfs）；勿信单次 curl 的 exit 0——曾出现 gzip EOF 损坏的"假成功"
curl -L -C - --retry 8 --retry-all-errors -o swift.tar.gz "<URL>"
tar -C ~/.local/opt --strip-components 1 -xzf swift.tar.gz && mv ~/.local/opt/usr ~/.local/opt/swift
# 更稳妥的解包名：tar -C ~/.local/opt/ 先解出 swift-6.1-RELEASE-ubuntu24.04/ 再 mv 为 swift/
~/.local/opt/swift/usr/bin/swift --version   # 预期：Swift version 6.1 (swift-6.1-RELEASE)
```

## §2 兼容库 compat-libs

Ubuntu 26.04 的 soname 比 Swift 6.1 工具链预期的旧（libxml2 26.04 是 soname 16，工具链要 .so.2）。从 24.04 deb 抽取：

```bash
mkdir -p ~/.local/opt/compat-libs && cd ~/.local/opt/compat-libs
# libxml2（自 24.04 的 libxml2_2.9.14+dfsg-1.3ubuntu3.10_amd64.deb，手动下载后）：
dpkg -x libxml2_*.deb x/ && cp x/usr/lib/x86_64-linux-gnu/libxml2.so.2 .
# libicu74 全家：抽取 .so.74* 后为需要的旧 soname（如 libicudata.so.74 等）建 symlink
```

用法：`export LD_LIBRARY_PATH="$HOME/.local/opt/compat-libs"`（构建脚本已内置）。验证：`LD_LIBRARY_PATH=~/.local/opt/compat-libs ldd ~/.local/opt/swift/usr/bin/swift-frontend | grep "not found"` → 空。

## §3 sqlite-dev（glibc 侧 + 源码）

```bash
mkdir -p ~/.local/opt/sqlite-dev && cd ~/.local/opt/sqlite-dev
# ① glibc 头+库（apt download 免 root）：
apt download libsqlite3-dev && dpkg -x libsqlite3-dev_*.deb extracted/
# ② amalgamation 源码（musl 自编用 + musl modulemap 的 header 指向它）：
#   https://sqlite.org/2025/sqlite-amalgamation-3500400.zip → 解压为 sqlite-amalgamation-3500400/
# ③ glibc modulemap（module.modulemap）：
cat > module.modulemap <<'EOF'
module SQLite3 [system] {
    header "/home/ql/.local/opt/sqlite-dev/extracted/usr/include/sqlite3.h"
    link "sqlite3"
    export *
}
EOF
# ④ musl modulemap（module-musl.modulemap）：
cat > module-musl.modulemap <<'EOF'
module SQLite3 [system] {
    header "/home/ql/.local/opt/sqlite-dev/sqlite-amalgamation-3500400/sqlite3.h"
    link "sqlite3"
    export *
}
EOF
```

⚠️ modulemap 内**只允许 `link` 指令**；`link_directory` 此 clang 不支持。

## §4 静态 SDK（musl 双 arch）

```bash
# 从 swift.org 下载 static-linux SDK 0.0.1 artifactbundle tarball（数百 MB，走 $HOME 勿走 /tmp）
~/.local/opt/swift/usr/bin/swift sdk install ~/swift-dl/swift-6.1-RELEASE_static-linux-0.0.1.artifactbundle.tar.gz
# 装完位于 ~/.swiftpm/swift-sdks/，含双 sysroot：
#   .../swift-linux-musl/musl-1.2.5.sdk/{x86_64,aarch64}/
swift sdk list   # 预期见 x86_64-swift-linux-musl / aarch64-swift-linux-musl
```

## §5 musl sqlite 静态库自编 + 注入 sysroot

SDK 不带 sqlite，且 **ld.lld 不吃 LIBRARY_PATH**，静态库必须放进 sysroot：

```bash
SDK=~/.swiftpm/swift-sdks/swift-6.1-RELEASE_static-linux-0.0.1.artifactbundle/swift-6.1-RELEASE_static-linux-0.0.1/swift-linux-musl/musl-1.2.5.sdk
CLANG=$SDK/<arch>/usr/lib/swift_static/clang     # SDK 内置 clang（按 arch 取）
SRC=~/.local/opt/sqlite-dev/sqlite-amalgamation-3500400
mkdir -p ~/.local/opt/sqlite-dev/musl-<arch> && cd ~/.local/opt/sqlite-dev/musl-<arch>

for arch in x86_64 aarch64; do
  $SDK/$arch/usr/lib/swift_static/clang \
    --target=${arch}-unknown-linux-musl --sysroot="$SDK/$arch" \
    -I"$SRC" -c "$SRC/sqlite3.c" -o sqlite3.o
  ar rcs libsqlite3.a sqlite3.o
  # ⚠️ 关键一步：cp 进 sysroot（swift build 链接期靠 sysroot 找到它）
  cp libsqlite3.a "$SDK/$arch/usr/lib/libsqlite3.a"
done
```

验证：`find ~/.swiftpm/swift-sdks -path "*musl-1.2.5.sdk/*/usr/lib/libsqlite3.a" | wc -l` → **2**（SKILL.md 第 0 步④同款检查）。参考大小：x86_64 ≈1.6MB / aarch64 ≈1.55MB。

## 自建完成判据

SKILL.md 第 0 步四项检查全部通过即自建完成，回到主流程。
