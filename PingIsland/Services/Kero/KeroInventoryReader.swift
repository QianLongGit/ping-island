//
//  KeroInventoryReader.swift
//  PingIsland
//
//  T25「kero 会话清单补全」：kero CLI 调用与 TTL 缓存。
//
//  职责边界（刻意做窄）：
//    1. 定位 kero 二进制（App 包内 → 用户配置目录 → 常见安装路径 → PATH）
//    2. 执行 `kero ls --json -a`（全主机聚合，超时 15s，stderr 丢弃）；
//       超时 / 空聚合 → 降级再跑一次本机清单（`kero ls --json`，5s）
//    3. TTL 缓存（默认 3s）：面板反复打开不重复 exec
//    4. 任何失败（二进制缺失 / 超时 / 解析失败）一律降级为空清单，
//       绝不向 UI 抛错——kero 是可选增强，不是硬依赖
//
//  本类型与全部内部类型显式 nonisolated：工程默认 MainActor 隔离，
//  而子进程执行必须留在后台线程（Service 在 Task.detached 里同步调用）。
//
//  执行器与时钟均可注入，单测不依赖真实 kero 二进制。
//

import Foundation
import os.log

nonisolated final class KeroInventoryReader: @unchecked Sendable {

    // ═════════════════════════════════════════════════════════════
    // MARK: - 注入点
    // ═════════════════════════════════════════════════════════════

    /// 命令执行器：给定可执行文件与参数，返回 stdout 原始字节
    typealias Executor = (_ executable: String, _ arguments: [String], _ timeout: TimeInterval) throws -> Data
    /// 二进制定位器：返回 kero 可执行文件路径（nil 表示未安装）
    typealias BinaryLocator = () -> String?
    /// 时钟（TTL 计算用，测试可固定）
    typealias Clock = () -> Date

    /// 默认 TTL：面板打开时的清单刷新间隔
    static let defaultTTL: TimeInterval = 3
    /// 全主机聚合（-a）超时预算：kero 对每台主机最多等待 10s，
    /// 多主机聚合时 5s 必然截肢——给足 15s 才能等到完整清单
    static let defaultTimeout: TimeInterval = 15
    /// 本机清单（不带 -a）兜底超时：只查本机，无需多主机等待
    static let fallbackTimeout: TimeInterval = 5

    private static let logger = Logger(subsystem: "com.wudanwu.pingisland", category: "KeroInventory")

    // ═════════════════════════════════════════════════════════════
    // MARK: - 状态
    // ═════════════════════════════════════════════════════════════

    private let executor: Executor
    private let locator: BinaryLocator
    private let ttl: TimeInterval
    private let timeout: TimeInterval
    private let now: Clock

    private let lock = NSLock()
    private var cachedInventory: [KeroHostInventory]?
    private var cachedAt: Date?

    // ═════════════════════════════════════════════════════════════
    // MARK: - 初始化
    // ═════════════════════════════════════════════════════════════

    init(
        executor: Executor? = nil,
        locator: BinaryLocator? = nil,
        ttl: TimeInterval = KeroInventoryReader.defaultTTL,
        timeout: TimeInterval = KeroInventoryReader.defaultTimeout,
        now: @escaping Clock = { Date() }
    ) {
        self.locator = locator ?? { KeroInventoryReader.locateBinary() }
        self.executor = executor ?? { executable, arguments, timeout in
            try KeroInventoryReader.runProcess(
                executable: executable,
                arguments: arguments,
                timeout: timeout
            )
        }
        self.ttl = ttl
        self.timeout = timeout
        self.now = now
    }

    // ═════════════════════════════════════════════════════════════
    // MARK: - 读取
    // ═════════════════════════════════════════════════════════════

    /// 读取 kero 会话清单（带 TTL 缓存）
    /// - Parameter forceRefresh: 忽略 TTL 强制重新执行
    /// - Returns: 按主机分组的会话清单；任何失败路径返回空数组
    func readInventory(forceRefresh: Bool = false) -> [KeroHostInventory] {
        // ── TTL 命中：直接回缓存（含失败结果，避免反复 exec 抖动） ──
        if !forceRefresh {
            lock.lock()
            let cached = cachedInventory
            let cachedAt = self.cachedAt
            lock.unlock()

            if let cached, let cachedAt, now().timeIntervalSince(cachedAt) < ttl {
                return cached
            }
        }

        // ── 缓存未命中 / 已过期：真正拉一次 ─────────────────────────
        let inventory = fetchInventory()

        lock.lock()
        cachedInventory = inventory
        cachedAt = now()
        lock.unlock()

        return inventory
    }

    /// 真正执行 kero 命令并解析（两跳策略）
    /// - 第一跳：全主机聚合 `kero ls --json -a`（超时 15s，覆盖 kero
    ///   侧每主机最多 10s 的等待窗口）
    /// - 第二跳：聚合超时 / 失败 / 无任何会话时，降级跑本机清单
    ///   `kero ls --json`（超时 5s）——远程主机失联不应拖垮本机清单
    /// - Note: 任何失败都在此吞掉并降级为空清单——kero 是可选增强，
    ///         缺二进制 / 超时 / 解析失败都不应让面板报错。
    private func fetchInventory() -> [KeroHostInventory] {
        // ── 1. 定位二进制：缺失即静默降级 ──────────────────────────
        guard let binary = locator() else {
            Self.logger.debug("kero 二进制未找到，跳过会话清单补全")
            return []
        }

        // ── 2. 第一跳：全主机聚合，任一主机有会话即采用 ────────────
        if let inventory = runList(binary, arguments: ["ls", "--json", "-a"], timeout: timeout),
           inventory.contains(where: { !$0.sessions.isEmpty }) {
            return inventory
        }

        // ── 3. 第二跳：本机清单兜底（-a 空聚合常见于远程全失联） ───
        if let inventory = runList(binary, arguments: ["ls", "--json"], timeout: Self.fallbackTimeout) {
            return inventory
        }

        return []
    }

    /// 执行一次清单命令并解析；失败返回 nil，由调用方决定是否降级
    private func runList(_ binary: String, arguments: [String], timeout: TimeInterval) -> [KeroHostInventory]? {
        let data: Data
        do {
            data = try executor(binary, arguments, timeout)
        } catch {
            Self.logger.debug("kero ls 失败：\(error.localizedDescription, privacy: .public)")
            return nil
        }

        do {
            let inventory = try KeroInventoryDecoder.decode(data)
            Self.logger.debug("kero 会话清单已刷新：\(inventory.count, privacy: .public) 台主机")
            return inventory
        } catch {
            Self.logger.debug("kero ls 解析失败：\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // ═════════════════════════════════════════════════════════════
    // MARK: - 二进制定位
    // ═════════════════════════════════════════════════════════════

    /// 定位 kero 可执行文件
    /// - 顺序：App 包内（macOS 正式安装）→ Homebrew 路径（/usr/local/bin、
    ///   /opt/homebrew/bin）→ 用户配置目录 → PATH
    static func locateBinary() -> String? {
        let fileManager = FileManager.default
        var candidates: [String] = [
            "/Applications/Kero.app/Contents/MacOS/kero",
            // Homebrew Intel/Apple Silicon 默认路径（CLI 安装器候选集）
            "/usr/local/bin/kero",
            "/opt/homebrew/bin/kero"
        ]

        // 显式写 `Foundation.ProcessInfo`：模块内 ProcessTreeBuilder.swift
        // 定义了同名 struct ProcessInfo（进程树快照），不加限定会被遮蔽
        let home = Foundation.ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        candidates.append("\(home)/.config/kero/bin/kero")

        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }

        return locateBinaryOnPath()
    }

    /// 在 PATH 中查找 kero
    private static func locateBinaryOnPath() -> String? {
        let fileManager = FileManager.default
        // 同上：带模块限定的 Foundation.ProcessInfo，避开同名 struct 遮蔽
        let pathEntries = (Foundation.ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)

        for entry in pathEntries {
            let candidate = "\(entry)/kero"
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    // ═════════════════════════════════════════════════════════════
    // MARK: - 进程执行
    // ═════════════════════════════════════════════════════════════

    /// 执行外部命令并回收 stdout
    /// - Note: stderr 全量丢弃（kero 的告警噪声不应影响面板）
    static func runProcess(executable: String, arguments: [String], timeout: TimeInterval) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw KeroInventoryError.binaryNotFound
        }

        // stderr 并发读空，避免管道写满反压导致死锁
        DispatchQueue.global(qos: .utility).async {
            _ = errorPipe.fileHandleForReading.readDataToEndOfFile()
        }

        // 超时看门狗：到点未退出则终止进程
        let timeoutFlag = TimeoutFlag()
        let watchdog = DispatchWorkItem {
            if process.isRunning {
                timeoutFlag.markTimedOut()
                process.terminate()
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        if timeoutFlag.didTimeOut {
            throw KeroInventoryError.timedOut
        }

        return outputData
    }

    /// 线程安全的超时标记
    private nonisolated final class TimeoutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var timedOut = false

        func markTimedOut() {
            lock.lock()
            timedOut = true
            lock.unlock()
        }

        var didTimeOut: Bool {
            lock.lock()
            defer { lock.unlock() }
            return timedOut
        }
    }
}
