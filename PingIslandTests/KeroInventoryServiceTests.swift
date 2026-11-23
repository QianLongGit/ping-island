//
//  KeroInventoryServiceTests.swift
//  PingIslandTests
//
//  T25「kero 会话清单补全」的服务层契约测试。
//
//  覆盖 KeroInventoryService（@MainActor 发布层）的三件事：
//    1. 面板打开时的刷新会把清单发布到 inventory（UI 真正读的字段）
//    2. 读取失败时保持空清单（kero 是可选增强，不是硬依赖）
//    3. 并发触发刷新只执行一次（面板反复打开不重复 exec）
//
//  全部通过注入的执行器闭包驱动，不依赖真实 kero 二进制。
//

import XCTest
@testable import Ping_Island

final class KeroInventoryServiceTests: XCTestCase {

    // ═════════════════════════════════════════════════════════════════
    // MARK: - 夹具
    // ═════════════════════════════════════════════════════════════════

    /// 线程安全的执行计数（执行器跑在后台线程）
    private nonisolated final class ExecCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }
    }

    private static let payload = """
    [
      {
        "host": "local",
        "sessions": [
          {
            "id": "s1",
            "title": "Claude Code",
            "dir": "/tmp/a",
            "status": "working",
            "pid": 42,
            "tty": "/dev/pts/0",
            "activity": 1795419601031,
            "agentSession": { "agent": "claude", "id": "uuid-1" },
            "panes": [
              {
                "id": "p1",
                "title": "Claude Code",
                "dir": "/tmp/a",
                "agent": "claude",
                "status": "working",
                "pid": 42,
                "tty": "/dev/pts/0",
                "activity": 1795419601031,
                "agentSession": { "agent": "claude", "id": "uuid-1" }
              }
            ]
          }
        ]
      }
    ]
    """

    @MainActor
    private func makeService(
        executor: @escaping KeroInventoryReader.Executor
    ) -> KeroInventoryService {
        let reader = KeroInventoryReader(
            executor: executor,
            locator: { "/usr/local/bin/kero" },
            ttl: 3,
            timeout: 5,
            now: { Date() }
        )
        return KeroInventoryService(reader: reader)
    }

    // ═════════════════════════════════════════════════════════════════
    // MARK: - 用例
    // ═════════════════════════════════════════════════════════════════

    @MainActor
    func testRefreshPublishesDecodedInventory() async {
        let service = makeService(executor: { _, _, _ in
            Data(Self.payload.utf8)
        })

        XCTAssertTrue(service.inventory.isEmpty, "刷新前清单为空")

        service.refreshIfNeeded(force: true)
        await service.currentRefresh?.value

        XCTAssertEqual(service.inventory.count, 1, "刷新后应发布 1 台主机的清单")
        XCTAssertEqual(service.inventory.first?.host, "local")
        XCTAssertEqual(service.inventory.first?.sessions.first?.id, "s1")
        XCTAssertFalse(service.isRefreshing, "刷新结束后 isRefreshing 应复位")
        XCTAssertNil(service.currentRefresh, "刷新结束后不应残留任务")
    }

    @MainActor
    func testRefreshKeepsEmptyInventoryWhenReaderDegrades() async {
        struct Boom: Error {}
        let service = makeService(executor: { _, _, _ in throw Boom() })

        service.refreshIfNeeded(force: true)
        await service.currentRefresh?.value

        XCTAssertTrue(service.inventory.isEmpty, "读取失败应保持空清单，不得把错误抛给 UI")
        XCTAssertFalse(service.isRefreshing)
        XCTAssertNil(service.currentRefresh)
    }

    @MainActor
    func testOverlappingRefreshRequestsShareOneExecution() async {
        let counter = ExecCounter()
        let service = makeService(executor: { _, _, _ in
            counter.increment()
            return Data(Self.payload.utf8)
        })

        // 第一次刷新尚未完成时再次触发 → 应被并发去重挡掉
        service.refreshIfNeeded(force: true)
        service.refreshIfNeeded(force: true)
        await service.currentRefresh?.value

        XCTAssertEqual(counter.count, 1, "并发触发刷新只应执行一次 kero 命令")
    }
}
