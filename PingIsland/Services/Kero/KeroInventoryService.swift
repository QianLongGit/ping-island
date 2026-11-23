//
//  KeroInventoryService.swift
//  PingIsland
//
//  T25「kero 会话清单补全」：把 kero 清单接入面板数据层。
//
//  职责边界（刻意做窄）：
//    1. 面板打开时拉一次清单（TTL 由 Reader 控制，重复打开不重复 exec）
//    2. 结果发布到 @Published，供 SessionListView 消费
//    3. 失败一律降级为空清单——kero 是可选增强，不是硬依赖
//
//  刻意不做：后台常驻轮询。清单只在面板可见时才有价值，
//  面板关闭后不刷新（避免常驻 fork kero 进程）。
//

import Combine
import Foundation

@MainActor
final class KeroInventoryService: ObservableObject {

    /// 全局单例（面板视图直接持有）
    static let shared = KeroInventoryService()

    /// kero 侧会话清单（按主机分组）
    @Published private(set) var inventory: [KeroHostInventory] = []

    /// 是否有刷新正在进行（避免并发重复拉取）
    @Published private(set) var isRefreshing = false

    private let reader: KeroInventoryReader
    private var refreshTask: Task<Void, Never>?

    /// 进行中的刷新任务（nil 表示当前没有刷新在跑）
    /// - Note: 供调用方等待本次刷新结束（面板无需等待，仅测试/诊断用）
    var currentRefresh: Task<Void, Never>? { refreshTask }

    init(reader: KeroInventoryReader = KeroInventoryReader()) {
        self.reader = reader
    }

    // ═════════════════════════════════════════════════════════════
    // MARK: - 刷新
    // ═════════════════════════════════════════════════════════════

    /// 拉取清单（TTL 未过期时直接命中缓存，不重复 exec）
    /// - Parameter force: 忽略 TTL 强制刷新
    func refreshIfNeeded(force: Bool = false) {
        guard refreshTask == nil else { return }
        isRefreshing = true

        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh(force: force)
        }
    }

    /// 真正拉一次清单并发布（挂起直到完成）
    /// - Note: 拉取动作放在后台线程，避免阻塞面板首帧
    private func performRefresh(force: Bool) async {
        let reader = self.reader
        let result = await Task.detached(priority: .utility) {
            reader.readInventory(forceRefresh: force)
        }.value

        inventory = result
        isRefreshing = false
        refreshTask = nil
    }
}
