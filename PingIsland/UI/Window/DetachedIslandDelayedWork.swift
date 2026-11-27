//
//  DetachedIslandDelayedWork.swift
//  PingIsland
//
//  可注入的延时任务执行器。
//
//  悬停驻留（0.6s）与悬停离开宽限（1.5s）是两处「时间即行为」的判定：
//  真机手感由它们决定，测试里必须能确定性地推进时钟，否则断言只能靠
//  真实等待 + 猜余量。生产实现走主队列定时器，测试实现注入手动时钟，
//  两条路径共用同一套协议，行为差异只在「谁来计时」。
//

import Foundation

/// 延时任务取消令牌：调度器返回，调用方据此撤销尚未执行的任务
@MainActor
final class DetachedIslandDelayedWorkToken {
    private var cancelAction: (@MainActor () -> Void)?

    init(cancelAction: (@MainActor () -> Void)? = nil) {
        self.cancelAction = cancelAction
    }

    func cancel() {
        let action = cancelAction
        cancelAction = nil
        action?()
    }
}

/// 延时任务调度器（可注入）
@MainActor
protocol DetachedIslandDelayedWorkScheduling: AnyObject {
    /// 在 delay 秒后执行 work；返回令牌用于取消
    func schedule(
        after delay: TimeInterval,
        work: @escaping @MainActor () -> Void
    ) -> DetachedIslandDelayedWorkToken
}

/// 生产实现：主队列定时器（与既有 DispatchWorkItem 行为一致）
@MainActor
final class MainQueueDelayedWorkScheduler: DetachedIslandDelayedWorkScheduling {
    func schedule(
        after delay: TimeInterval,
        work: @escaping @MainActor () -> Void
    ) -> DetachedIslandDelayedWorkToken {
        let item = DispatchWorkItem { work() }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return DetachedIslandDelayedWorkToken { item.cancel() }
    }
}
