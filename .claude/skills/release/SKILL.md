---
name: release
description: Use when 改动 ping-island 功能后需要完整发布——重打 Mac DMG、本机交叉编译 Linux bridge（glibc 快验 + musl 双 arch 静态）、按 App 端资产契约打 4 个 zip、创建双 tag GitHub release 并上传全部资产、curl 下载链端到端验证、刷新本机 ~/.ping-island 部署。触发词：发布、发版、release、出新包、DMG、bridge 编译、musl、上传资产、打 tag。
---

# ping-island 发布技能

一键完成整套发布：**Mac DMG 重打 → Linux bridge 双 arch 编译 → 资产打包 → tag/release 创建上传 → 下载链验证 → 本机部署刷新 → 用户收尾清单**。

所有命令与坑位均经 2026-11-21/22 全链实战验证（v0.33.0 / v0.33.0-kero.1 双 tag 发布）。

## 流程总览

| 步骤 | 动作 | 产物 | 关键验证点 |
|---|---|---|---|
| 0 | 前置检查 | — | 版本号/工具链/gh/ssh 全部就位 |
| 1 | Mac DMG（构建机） | `PingIsland-$VER-release-unsigned.dmg` + `.zip` | EXIT_0、产物大小、sha256 |
| 2 | Linux bridge 编译（本机） | glibc 快验版 + musl 双 arch 静态版 | EXIT_0、`file` 断言静态链接 |
| 3 | 资产打包 | 4 个 bridge zip | 内层文件名精确=资产名 |
| 4 | tag 与 release | 双 tag × 6 资产 | `gh release view` 资产计数 |
| 5 | 下载链验证 | sha256 逐字节比对 + 冒烟 | curl 下载 sha 吻合、冒烟 JSON 断言 |
| 6 | 本机部署刷新 | `~/.ping-island/bin/PingIslandBridge` | `file` 断言 statically linked |
| 7 | 用户收尾清单 | 输出给用户的提示 | — |

**硬约束**：全程禁 `git commit / branch / push`（发布只打 tag 与上传资产，不动分支）；大文件操作一律走 `$HOME` 勿走 `/tmp`（见坑位表 #3）。

---

## 第 0 步：前置检查

```bash
REPO=/home/ql/Development/Project/my-vibeisland/ping-island

# ① 版本号（tag 名与 DMG 名的唯一来源；即 CFBundleShortVersionString 的源）
VER=$(rg -o 'MARKETING_VERSION = [0-9.]+' "$REPO/PingIsland.xcodeproj/project.pbxproj" | head -1 | rg -o '[0-9.]+')
echo "VER=$VER"    # 预期 0.33.0（pbxproj 内 4 处同值；后续步骤沿用此 $VER）
rg -n "MARKETING_VERSION" "$REPO/PingIsland.xcodeproj/project.pbxproj"
# 4 处值不一致 = 版本号漂移，先修再发布

# ② gh 本机可用（构建机 token 已失效——一切 release 操作只在本机跑 gh）
gh auth status && echo GH_OK

# ③ 构建机免密
ssh -p 10024 -o BatchMode=yes -o ConnectTimeout=5 dev@43.133.240.214 'echo SSH_OK'

# ④ 本机 Swift 工具链 + 静态 SDK + sqlite 注入件
~/.local/opt/swift/usr/bin/swift --version          # 预期 Swift 6.1 RELEASE
ls ~/.swiftpm/swift-sdks/                            # 预期 swift-6.1-RELEASE_static-linux-0.0.1.artifactbundle
ls ~/.local/opt/compat-libs/ ~/.local/opt/sqlite-dev/musl-x86_64/ ~/.local/opt/sqlite-dev/musl-aarch64/
# 预期 compat-libs 含 libxml2.so.2 等；musl-<arch>/ 各含 libsqlite3.a
# ⚠️ 还须确认 musl 静态库已 cp 进 SDK sysroot（ld.lld 不吃 LIBRARY_PATH，见坑位 #2）：
find ~/.swiftpm/swift-sdks -path "*musl-1.2.5.sdk/*/usr/lib/libsqlite3.a" | wc -l
# 预期：2（双 arch 各一）
```

任一项缺失 → 按 `references/toolchain-setup.md` 自建环境后再继续。内存紧张（<4G 可用）时构建命令保持 `--jobs 4` 防 OOM。

## 第 1 步：Mac DMG（构建机出包）

⚠️ **构建机源码树是单写者串行资源**：`rsync --delete` 时刻必须互斥，若有其他任务正持机器，等它让出。

```bash
REPO=/home/ql/Development/Project/my-vibeisland/ping-island

# ① 同步源码（排除 .git/build/DerivedData，不依赖 git 状态）
rsync -az --delete --exclude .git --exclude build --exclude DerivedData \
  -e "ssh -p 10024" "$REPO/" dev@43.133.240.214:Development/ping-island/

# ② 出包（约 3 分钟）
ssh -p 10024 dev@43.133.240.214 'cd ~/Development/ping-island && ./scripts/package-unsigned.sh'
# 预期 EXIT_0。⚠️ styled DMG 的 AppleScript 在无头 SSH 下报 -1712 并自动降级 plain DMG——正常，非失败

# ③ 拉回本机并记录 sha256（放 $HOME，勿放 /tmp）
mkdir -p ~/pi-release-assets && scp -P 10024 \
  "dev@43.133.240.214:Development/ping-island/releases/unsigned/PingIsland-$VER-release-unsigned.dmg" \
  "dev@43.133.240.214:Development/ping-island/releases/unsigned/PingIsland-$VER-release-unsigned.zip" \
  ~/pi-release-assets/
sha256sum ~/pi-release-assets/PingIsland-$VER-release-unsigned.dmg ~/pi-release-assets/PingIsland-$VER-release-unsigned.zip
```

验证点：EXIT_0 + 两个产物存在（DMG 约 15MB 量级）+ sha256 已记录（第 5 步比对用）。

## 第 2 步：Linux bridge 编译（本机）

### sqlite 注入法（本节是全流程最核心的坑）

IslandShared `import SQLite3`，但本机无 libsqlite3-dev、musl SDK 也不带 sqlite。解法（已固化为技能脚本）：

1. **外部 modulemap**（`~/.local/opt/sqlite-dev/module*.modulemap`）内含 `link "sqlite3"` 指令 → swift build 自动链接；
2. **`-Xcc -fmodule-map-file=<modulemap 路径>`** 让 clang 找到模块；
3. glibc 版链接路径走 **LIBRARY_PATH** 环境变量；musl 版静态库**已 cp 进 SDK sysroot `usr/lib/`**（ld.lld 不吃 LIBRARY_PATH）。

⚠️ **严禁 `-Xclang-linker` 参数组**：与 SwiftPM ArgumentParser 冲突 → `EXIT_64 "Missing value for '-c'"`。此路已实测死，勿再试。modulemap 的 `link_directory` 指令此 clang 亦不支持。

### glibc 动态版（仅本机快验，不可分发）

```bash
bash /home/ql/Development/Project/my-vibeisland/ping-island/.claude/skills/release/scripts/build-bridge.sh
# 预期：EXIT_0 ELAPSED_~16s，产物 Prototype/.build/release/PingIslandBridge（约 2.5MB）
# 用途：改动后快速验证功能（冒烟），15 秒级反馈；不要打包它进 release
```

### musl 真静态版（分发用，双 arch）

```bash
SKILL=/home/ql/Development/Project/my-vibeisland/ping-island/.claude/skills/release
bash "$SKILL/scripts/build-bridge-musl.sh" x86_64    # 预期 EXIT_0 ~22s
bash "$SKILL/scripts/build-bridge-musl.sh" aarch64   # 预期 EXIT_0 ~23s
```

产物（各约 141-148MB，带 debug_info，对齐官方发行形态）：

- `Prototype/.build/x86_64-swift-linux-musl/release/PingIslandBridge`
- `Prototype/.build/aarch64-swift-linux-musl/release/PingIslandBridge`

验证点：

```bash
REPO=/home/ql/Development/Project/my-vibeisland/ping-island
file "$REPO/Prototype/.build/x86_64-swift-linux-musl/release/PingIslandBridge"
# 预期：...x86-64 ... statically linked
file "$REPO/Prototype/.build/aarch64-swift-linux-musl/release/PingIslandBridge"
# 预期：...ARM aarch64 ... statically linked
```

⚠️ **勿用 grep/strings 检验功能**：Swift SmallString 内联会让 `grep KERO_PANE` 0 命中，功能实际在（aarch64/x86_64 双双实证过）。功能验证以第 5 步运行时冒烟为准。

## 第 3 步：资产打包契约

App 端消费逻辑（资产名与内层文件名在此定死）：

- `RemoteConnectorManager.swift:1787-1801`：主选 `PingIslandBridge-linux-musl-<arch>`，legacy 兜底 `PingIslandBridge-linux-<arch>`（arch ∈ {x86_64, aarch64}，arm64 会规范化为 aarch64）；
- 解压后按 `lastPathComponent == "PingIslandBridge-linux-musl-<arch>"` **精确匹配**内层文件名；
- `RemoteConnectorManager.swift:3021`：下载 URL = `releases/download/v<运行时版本>/<资产名>` —— **tag 名必须与 App 的 CFBundleShortVersionString 精确一致**（第 4 步的根因）。

```bash
REPO=/home/ql/Development/Project/my-vibeisland/ping-island
STAGE=~/pi-bridge-assets    # ⚠️ 必须在 $HOME 下，勿用 /tmp（坑位 #3）
mkdir -p "$STAGE" && cd "$STAGE"

# 4 个资产 = 2 arch × (musl 主名 + legacy 兜底名)；内层文件名 = zip 名去 .zip；顶层单文件无目录前缀
for arch in x86_64 aarch64; do
  for stem in "PingIslandBridge-linux-musl-$arch" "PingIslandBridge-linux-$arch"; do
    cp "$REPO/Prototype/.build/${arch}-swift-linux-musl/release/PingIslandBridge" "$stem"
    zip -j "$stem.zip" "$stem"
  done
done

# 验证：内层名精确匹配 + 顶层单文件 + 记录 sha256（发布记录的唯一事实源）
for z in *.zip; do unzip -l "$z"; done
sha256sum *.zip
```

验证点：每个 zip 列表恰 1 个条目、文件名=zip 名去后缀；musl 名与 legacy 名的 zip sha256 两两相同（同一二进制双名分发）。

⚠️ **sha256 以最终上传集为唯一事实源**：中间打包产物/旧报告里的 sha 表可能过时（实战中 t8fix 报告的 /tmp zip 表是旧动态版，误导过一轮）。任何不一致，以实际推上 release 的资产为准。

## 第 4 步：tag 与 release（本机 gh）

**双 tag 策略**：

- `v<精确版本>`（如 `v0.33.0`）——**App bootstrap 的真实拉取路径**（按运行时版本号拼 URL，缺失此 tag = 远端 Linux 机器永远下不到新 bridge）；
- 人类可读变体 tag（如 `v0.33.0-kero.1`）——标记 fork 特色发布线。

版本号变更时：先改 `PingIsland.xcodeproj/project.pbxproj` 的 `MARKETING_VERSION`（4 处），tag 名与 DMG 名随之而变。

```bash
cd /home/ql/Development/Project/my-vibeisland/ping-island
VER=0.33.0                          # ← 第 0 步读出的版本号
TAG_MAIN="v$VER"                    # App 拉取路径
TAG_HUMAN="v$VER-kero.1"            # 人类可读变体（后缀按需递增）

# ⓪ release notes（若 ~/pi-release-notes.md 不存在，先生成——双语简介：本次改动亮点/资产清单/未签名提示）
# ⚠️ 换版本发布前先删旧 notes 文件，否则会原样复用上一版（标题仍是旧 TAG_HUMAN）
[ -f ~/pi-release-notes.md ] || cat > ~/pi-release-notes.md <<EOF
# PingIsland $TAG_HUMAN

- 说明：本 fork 发布版（未签名，安装需在系统设置放行）
- 资产：Mac DMG/ZIP + Linux bridge musl 双 arch（musl 主名 + legacy 兜底名）
EOF

# ① 创建（note 逻辑同 tag；--title 用人类可读名）
gh release create "$TAG_MAIN" --title "PingIsland $TAG_HUMAN" --notes-file ~/pi-release-notes.md
gh release create "$TAG_HUMAN" --title "PingIsland $TAG_HUMAN" --notes-file ~/pi-release-notes.md

# ② 双 tag 各上传 6 资产（DMG + zip + 4 个 bridge zip）
for TAG in "$TAG_MAIN" "$TAG_HUMAN"; do
  gh release upload "$TAG" --clobber \
    ~/pi-release-assets/PingIsland-$VER-release-unsigned.dmg \
    ~/pi-release-assets/PingIsland-$VER-release-unsigned.zip \
    ~/pi-bridge-assets/PingIslandBridge-linux-musl-x86_64.zip \
    ~/pi-bridge-assets/PingIslandBridge-linux-x86_64.zip \
    ~/pi-bridge-assets/PingIslandBridge-linux-musl-aarch64.zip \
    ~/pi-bridge-assets/PingIslandBridge-linux-aarch64.zip
done
```

验证点：`gh release view "$TAG_MAIN" --json assets -q '.assets | length'` → **6**（双 tag 各验一次）。

## 第 5 步：验证（证据优先，三层）

```bash
VER=0.33.0; TAG_MAIN="v$VER"

# ① 资产清单：双 tag 各 6 资产
gh release view "$TAG_MAIN" --json assets -q '.assets[].name'

# ② 下载链端到端：curl 公网下载主路径资产 → sha256 与本地构建逐字节比对
curl -sL -o ~/verify-bridge.zip \
  "https://github.com/QianLongGit/ping-island/releases/download/$TAG_MAIN/PingIslandBridge-linux-musl-x86_64.zip"
sha256sum ~/verify-bridge.zip ~/pi-bridge-assets/PingIslandBridge-linux-musl-x86_64.zip
# 预期：两行 sha256 完全一致

# ③ bridge 冒烟（socket 监听出站 JSON，验证终端识别逻辑）
# ⚠️ bridge 必须带 --source <provider> 参数（claude/codex/copilot/kimi/gemini/omp）：
#    缺参数报 "PingIslandBridge error: ... BridgeError error 0"（=invalidArguments）退出，
#    listener 收不到任何连接（已实测踩过）
cd /tmp && rm -f smoke.sock
python3 - <<'EOF' &
import socket, os
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind("/tmp/smoke.sock"); s.listen(2)
for _ in range(2):                      # 依次接收两条连接：kero 组 + 对照组
    conn, _ = s.accept()
    data = conn.recv(65536)
    print("SMOKE_JSON>>>", data.decode("utf-8", "replace")[:2000])
    conn.close()
os.unlink("/tmp/smoke.sock")
EOF
LISTENER=$!
sleep 0.5
# kero 判别：KERO_PANE 存在 + TERM_PROGRAM=ghostty → 必须识别为 kero
echo '{"session_id":"smoke-test","hook_event_name":"UserPromptSubmit","cwd":"/tmp"}' | \
  env ISLAND_SOCKET_PATH=/tmp/smoke.sock KERO_PANE=test123 TERM_PROGRAM=ghostty \
  ~/pi-bridge-assets/PingIslandBridge-linux-musl-x86_64 --source claude
# 对照组：剥掉 KERO_PANE → 必须保持 ghostty，不得误报 kero
# ⚠️ -u 是必须的：测试 shell 自身可能跑在 kero 里，KERO_PANE 经 env 继承穿透（env 前缀只添加不删除）
echo '{"session_id":"smoke-test","hook_event_name":"UserPromptSubmit","cwd":"/tmp"}' | \
  env -u KERO_PANE ISLAND_SOCKET_PATH=/tmp/smoke.sock TERM_PROGRAM=ghostty \
  ~/pi-bridge-assets/PingIslandBridge-linux-musl-x86_64 --source claude
wait $LISTENER
```

⚠️ **环境泄漏**：测试 shell 自身可能运行于 kero（env 继承 `KERO_PANE`），对照组命令已内建 `env -u KERO_PANE`。判读标准（实测字段位于出站 JSON 的 `metadata` 镜像，snake_case；`terminalContext` 嵌套对象内为驼峰同名值）：

- 第一条出站 JSON 含 `"terminal_program":"kero"` 与 `"terminal_bundle_id":"sh.kero"`；
- 对照组含 `"terminal_program":"ghostty"` / `"terminal_bundle_id":"com.mitchellh.ghostty"`，无 kero 误报。

## 第 6 步：本机部署刷新

```bash
REPO=/home/ql/Development/Project/my-vibeisland/ping-island
# ⚠️ 只替换二进制，保留同目录 wrapper 脚本 ping-island-bridge（设置 PING_ISLAND_BRIDGE_CONFIG）
cp "$REPO/Prototype/.build/x86_64-swift-linux-musl/release/PingIslandBridge" \
   ~/.ping-island/bin/PingIslandBridge
chmod 755 ~/.ping-island/bin/PingIslandBridge
file ~/.ping-island/bin/PingIslandBridge    # 预期：statically linked（动态版=误部署，禁止）
```

Mac 侧可选防回退 override（App 优先取此文件，跳过 release 下载）：`~/.ping-island/custom-bridges/PingIslandBridge-linux-musl-x86_64`（逻辑见 `RemoteConnectorManager.swift:1803-1813`）。无常驻 bridge 进程（hook 每事件 exec 新实例），替换后无需重启。

## 第 7 步：用户收尾清单（原样输出给用户）

发布完成后，向用户输出以下人工步骤（不可自动化）：

1. 安装新 DMG（`~/pi-release-assets/PingIsland-$VER-release-unsigned.dmg`，未签名版需在系统设置里放行）；
2. ⚠️ **在 App 设置里手动重装 hook**——hook 模板无版本指纹、不会自动重装；不重装则拿不到新增环境变量透传（如 KERO_PANE），新功能静默失效；
3. 远端 Linux 机器若已装旧 bridge：新版经 release URL 自动下载校验后替换；若 checksum 恰与旧版一致会跳过（罕见，仅同源重编时），必要时手动重装远端 hook；
4. 真机验收：点击会话列表项，确认跳转/识别行为符合本次发布预期。

## 常见错误速查表

| # | 症状 | 根因 | 解法 |
|---|---|---|---|
| 1 | `swift build` EXIT_64 `Missing value for '-c'` | 用了 `-Xclang-linker` 参数组，与 ArgumentParser 冲突 | 严禁该参数组；用 modulemap `link` 指令 + LIBRARY_PATH / sysroot cp（第 2 步） |
| 2 | musl 链接报找不到 `-lsqlite3` | ld.lld 不吃 LIBRARY_PATH | 把 `libsqlite3.a` cp 进 SDK sysroot `usr/lib/`（toolchain-setup.md §4） |
| 3 | 命令挂死 / 输出捕获失败 / `EDQUOT` | `/tmp` 是 tmpfs（3.7G），大文件堆满 | 大文件操作一律走 `$HOME`；盘点输出写 home 文件用 Read 读 |
| 4 | zip 上传后 App 远端装不上 / 解压失败 | 内层文件名 ≠ 资产名，或 zip 内带目录前缀 | 内层名=zip 名去 `.zip`，用 `zip -j` 顶层单文件（第 3 步） |
| 5 | 远端机器一直用旧 bridge | 缺 `v<精确版本>` tag，或 App 版本与 tag 不一致 | 双 tag 必建；tag 名=App 运行时版本精确拼接（第 4 步） |
| 6 | 产物 `grep KERO_PANE` 0 命中 | Swift SmallString 内联 | 非缺陷；以运行时冒烟为决定性证据（第 5 步） |
| 7 | 冒烟对照组误报 kero | 测试 shell 自身运行在 kero，env 泄漏 | 对照组显式 `env -u KERO_PANE`（第 5 步） |
| 8 | DMG 出包报 AppleScript -1712 | 无头 SSH 无法跑 styled DMG 脚本 | 正常，脚本自动降级 plain DMG，照常取产物 |
| 9 | rsync/构建互相踩、测试跑在混合状态 | 构建机源码树是单写者串行资源 | rsync `--delete` 时刻互斥，等前序任务让出（第 1 步） |
| 10 | 不同记录里同一资产 sha256 不一致 | 中间产物过时（旧动态版曾被误打包） | 以最终上传集为唯一事实源，重算 `sha256sum`（第 3 步） |
| 11 | 用户装了新 DMG 但新环境变量不生效 | hook 模板无指纹不自动重装 | 收尾清单第 2 条：设置里手动重装 hook（第 7 步） |
| 12 | 冒烟时 bridge 报 `BridgeError error 0`、listener 零连接 | 缺 `--source <provider>` 参数（error 0=invalidArguments，非连接错误） | 命令补 `--source claude`（第 5 步命令已含） |

## 交叉引用

- 环境自建（首次/换机）：`references/toolchain-setup.md`
- 构建脚本：`scripts/build-bridge.sh`（glibc）、`scripts/build-bridge-musl.sh`（musl 双 arch）
- 历史实战记录：`.superpowers/sdd/2026-11-21-kero-jump-integration/`（progress.md 账本、task-t8fix-report.md 编译细节、task-fork-release-report.md 仓库/资产约定）
- App 端消费源码：`PingIsland/Services/Remote/RemoteConnectorManager.swift:1787-1813`（资产名/override）、`:3021`（下载 URL）
