//
//  FocusTrace.swift
//  PingIsland
//
//  激活溯源：谁把 Ping Island 拉到前台、哪个窗口成为 key。
//
//  用户原话（2026-11-27）：「主动弹出来的这个，不要抢占焦点」。
//  静态阅读只能证明「自动链路没有显式 activate」，无法证明运行时
//  是谁激活的；这里把「激活事件 + 触发时调用栈」落到统一日志，
//  下一次复现时直接看栈就能定位到具体调用点，不用再靠推测。
//
//  读取方式：
//      log show --predicate 'subsystem == "com.wudanwu.pingisland" AND category == "FocusTrace"'
//
//  格式说明：统一日志对单条消息有 1024 字节上限（实测超长会被截断并
//  追加 …），因此调用栈逐帧单独成行，12 帧不会被砍成前几帧。
//

import AppKit
import os.log

@MainActor
enum FocusTrace {
    private static let logger = Logger(
        subsystem: "com.wudanwu.pingisland",
        category: "FocusTrace"
    )

    /// 栈帧条数上限：足够定位到调用点，又不至于刷屏
    private static let stackFrameLimit = 12

    /// 记录一次「应用被激活」：事件类型 + 触发栈
    static func activation(source: String) {
        logger.notice(
            "app.activated source=\(source, privacy: .public) event=\(currentEventType(), privacy: .public)"
        )
        logStack(prefix: "app.activated.stack")
    }

    /// 记录一次「窗口成为 key」
    static func becameKey(window: String) {
        logger.notice(
            "window.becameKey window=\(window, privacy: .public) event=\(currentEventType(), privacy: .public)"
        )
        logStack(prefix: "window.becameKey.stack")
    }

    /// 显式激活调用点的来源标记（NSApp.activate 调用点各打一行）
    static func source(_ marker: String) {
        logger.notice("activate.source marker=\(marker, privacy: .public)")
    }

    private static func currentEventType() -> String {
        guard let event = NSApp.currentEvent else { return "none" }
        return describe(event.type)
    }

    /// 事件类型的可读名（NSEvent.EventType 是 OptionSet，直接打印只有数字）
    private static func describe(_ type: NSEvent.EventType) -> String {
        switch type {
        case .leftMouseDown: return "leftMouseDown"
        case .leftMouseUp: return "leftMouseUp"
        case .leftMouseDragged: return "leftMouseDragged"
        case .rightMouseDown: return "rightMouseDown"
        case .rightMouseUp: return "rightMouseUp"
        case .otherMouseDown: return "otherMouseDown"
        case .mouseMoved: return "mouseMoved"
        case .keyDown: return "keyDown"
        case .keyUp: return "keyUp"
        case .scrollWheel: return "scrollWheel"
        case .appKitDefined: return "appKitDefined"
        case .systemDefined: return "systemDefined"
        default: return "type\(type.rawValue)"
        }
    }

    private static func logStack(prefix: String) {
        for (index, frame) in Thread.callStackSymbols.prefix(stackFrameLimit).enumerated() {
            logger.notice(
                "\(prefix, privacy: .public)[\(index, privacy: .public)]=\(frame, privacy: .public)"
            )
        }
    }
}
