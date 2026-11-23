//
//  KeroSessionRowView.swift
//  PingIsland
//
//  T25「kero 会话清单补全」：kero 独占行的展示。
//
//  为什么单独一个行视图：
//    hook 会话行（InstanceRow）的渲染必须零改动——它是既有稳定路径，
//    任何改动都会波及点击/展开/审批等交互。kero 独占行是"只有 kero 侧
//    才知道"的会话，用一个独立的轻量行承载，避免侵入既有行。
//
//  视觉规范与既有行保持同一套度量：
//    字号走 SessionListCompactMetrics（与 hover 预览面板同源）
//    行距走 SessionListCompactMetrics.rowVerticalPadding
//    时间徽标走 SessionPhaseHelpers.timeBadgeLabel
//

import SwiftUI

/// kero 独占行：展示 kero 侧才知道的会话（本地 / 各主机）
struct KeroSessionRowView: View {

    /// 行数据（由 KeroSessionMerger 产出）
    let row: KeroSessionMerger.Row
    /// 点击回调（外层负责跳转 kero pane）
    let onActivate: () -> Void

    @ObservedObject private var settings = AppSettings.shared
    @State private var isHovered = false

    // ═════════════════════════════════════════════════════════════
    // MARK: - 度量
    // ═════════════════════════════════════════════════════════════

    private var baseFontSize: CGFloat {
        CGFloat(settings.contentFontSize)
    }

    private var isCompactList: Bool {
        settings.compactSessionList
    }

    private var titleFontSize: CGFloat {
        SessionListCompactMetrics.sessionTitleFontSize(base: baseFontSize)
    }

    private var detailFontSize: CGFloat {
        SessionListCompactMetrics.detailFontSize(base: baseFontSize)
    }

    // ═════════════════════════════════════════════════════════════
    // MARK: - 主体
    // ═════════════════════════════════════════════════════════════

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            leadingIcon

            VStack(alignment: .leading, spacing: 2) {
                titleLine
                    .lineLimit(1)
                    .truncationMode(.tail)

                detailLine
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            trailingBadges
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .padding(.vertical, SessionListCompactMetrics.rowVerticalPadding(compactList: isCompactList, singleLine: false))
        .background(rowBackground)
        .contentShape(Rectangle())
        .onTapGesture {
            onActivate()
        }
        .onHover {
            isHovered = $0
        }
    }

    // ═════════════════════════════════════════════════════════════
    // MARK: - 组成
    // ═════════════════════════════════════════════════════════════

    /// 左侧标识：终端图标（kero 行没有 mascot 身份，用中性终端符号）
    private var leadingIcon: some View {
        RoundedRectangle(cornerRadius: SessionListCompactMetrics.avatarCornerRadius(compactList: isCompactList), style: .continuous)
            .fill(Color.white.opacity(0.04))
            .overlay(
                Image(systemName: "terminal")
                    .font(.system(size: max(10, baseFontSize - 2), weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.62))
            )
            .frame(
                width: SessionListCompactMetrics.avatarEdge(compactList: isCompactList, singleLine: false),
                height: SessionListCompactMetrics.avatarEdge(compactList: isCompactList, singleLine: false)
            )
    }

    /// 主标题：会话标题（kero 侧 title/name/dir basename 兜底链的最终结果）
    private var titleLine: some View {
        Text(row.title)
            .font(.system(size: titleFontSize, weight: .bold))
            .foregroundColor(.white)
    }

    /// 详情行：目录 · 状态（缺失项直接省略，不留空占位）
    private var detailLine: some View {
        let parts = [row.dir, row.status].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }

        return Text(parts.joined(separator: " · "))
            .font(.system(size: detailFontSize))
            .foregroundColor(.white.opacity(0.55))
    }

    /// 尾随徽标：来源（kero）· 主机 · 时间
    private var trailingBadges: some View {
        HStack(spacing: SessionListCompactMetrics.badgeSpacing(compactList: isCompactList)) {
            badge("kero", tint: Color.white.opacity(0.1), foreground: Color.white.opacity(0.64))

            if let hostLabel = row.hostLabel {
                badge(hostLabel, tint: Color.white.opacity(0.1), foreground: Color.white.opacity(0.64))
            }

            if let activity = row.activity {
                badge(
                    SessionPhaseHelpers.timeBadgeLabel(for: activity),
                    tint: Color.white.opacity(0.1),
                    foreground: Color.white.opacity(0.64),
                    monospaced: true
                )
            }
        }
    }

    /// 通用徽标
    private func badge(
        _ text: String,
        tint: Color,
        foreground: Color,
        monospaced: Bool = false
    ) -> some View {
        Text(text)
            .font(.system(size: max(9, detailFontSize - 1), weight: .semibold, design: monospaced ? .monospaced : .default))
            .foregroundColor(foreground)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint)
            .clipShape(Capsule())
    }

    /// 行背景：与既有行同一套圆角/描边语言
    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(rowBackgroundColor)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(rowBorderColor, lineWidth: 1)
            )
    }

    private var rowBackgroundColor: Color {
        isHovered ? Color.white.opacity(0.06) : Color.white.opacity(0.03)
    }

    private var rowBorderColor: Color {
        Color.white.opacity(0.06)
    }
}
