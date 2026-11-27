//
//  DetachedIslandMouseRouting.swift
//  PingIsland
//
//  悬浮胶囊的鼠标路由规则（T30）。
//
//  规则来自用户原话「主动弹出来的这个，不要抢占焦点」：自动弹出的面板
//  出现时对鼠标透明（点击、滚轮直接落到下面的窗口），指针在面板内移动
//  后才接受点击，指针离开后退回透明；宠物可见形象始终接受鼠标；用户
//  主动展开的面板出现即可点击。
//
//  判定写成纯函数：不依赖窗口、不依赖事件，行为级测试可以直接断言
//  「这一刻该接受还是该穿透」。
//

import CoreGraphics

/// 气泡展示来源：决定面板出现时是否已就绪（是否立即接受点击）
enum DetachedIslandBubblePresentationSource {
    /// 用户主动展开（点宠物 / 点完成气泡进对话）：出现即可点击
    case userInitiated
    /// 自动触发展示（完成气泡 / 审批追问自动展开）：指针在面板内移动后才接受点击
    case automatic
    /// 悬停展开的预览：同自动展示，且指针离开宠物与面板后自动收起
    case hoverExpanded
}

/// 鼠标路由判定
enum DetachedIslandMouseRouting {
    /// 面板「已发生移动」的判定阈值（pt）
    ///
    /// 面板刚出现时指针恰好停在面板内，这次点击必须穿透到下面的窗口；
    /// 指针真的动过之后才算就绪。阈值取几 pt：太小会被手抖误触发，
    /// 太大又会让「移进面板」显得迟钝。
    static let autoPanelMovementThreshold: CGFloat = 4

    /// 自动展示的面板是否已就绪
    ///
    /// - Parameters:
    ///   - pointerLocation: 当前指针位置（AppKit 屏幕坐标）
    ///   - movementBaseline: 未就绪期间的移动基准位置；nil 表示尚无基准
    ///   - movementThreshold: 触发就绪所需的位移（pt）
    static func isAutoPanelReady(
        pointerLocation: CGPoint,
        movementBaseline: CGPoint?,
        movementThreshold: CGFloat = autoPanelMovementThreshold
    ) -> Bool {
        guard let movementBaseline else { return false }
        let deltaX = pointerLocation.x - movementBaseline.x
        let deltaY = pointerLocation.y - movementBaseline.y
        return hypot(deltaX, deltaY) >= movementThreshold
    }

    /// 当前指针位置是否接受鼠标
    ///
    /// - Parameters:
    ///   - point: 指针位置（AppKit 屏幕坐标）
    ///   - petVisibleRect: 宠物可见形象矩形（始终接受鼠标）
    ///   - bubbleRect: 面板矩形；nil 或空矩形表示当前没有面板
    ///   - bubbleInteractive: 面板是否处于「就绪」态（接受点击）
    static func acceptsMouse(
        at point: CGPoint,
        petVisibleRect: CGRect,
        bubbleRect: CGRect?,
        bubbleInteractive: Bool
    ) -> Bool {
        if petVisibleRect.contains(point) {
            return true
        }

        if bubbleInteractive,
           let bubbleRect,
           !bubbleRect.isNull,
           bubbleRect.contains(point) {
            return true
        }

        return false
    }
}
