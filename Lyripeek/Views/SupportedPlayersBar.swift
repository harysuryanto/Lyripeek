//
//  SupportedPlayersBar.swift
//  Lyripeek
//
//  Created by Hary Suryanto on 26/06/26.
//

import SwiftUI

/// Compact bar that lists every registered `PlayerSource` plus a note about
/// Control Center compatibility. Shown at the top of the popover so the user
/// can see what apps are supported even when only one is currently playing.
struct SupportedPlayersBar: View {
    @EnvironmentObject private var nowPlayingService: NowPlayingService

    private let rowHeight: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "headphones")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Supported Players")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer(minLength: 0)
            }

            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(displayedSources, id: \.id) { item in
                    PlayerChip(
                        name: item.name,
                        bundleID: item.bundleID,
                        isActive: item.isActive
                    )
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    /// The system source is shown last with a generic name and a note that
    /// "any Control Center app works" — it's the catch-all.
    private var displayedSources: [SourceItem] {
        let activeBundleID = nowPlayingService.sourceBundleIdentifier
        let activeSource = nowPlayingService.sourceDescription

        var items: [SourceItem] = []
        for source in nowPlayingService.allSources {
            let isActive: Bool
            if source.bundleIdentifier == nil {
                // System source — only "active" when the active publisher
                // doesn't match any known source.
                isActive = activeBundleID == nil
                    && !activeSource.isEmpty
                    && activeSource != "Now Playing"
                    || (activeBundleID == nil && !activeSource.isEmpty)
            } else {
                isActive = activeBundleID == source.bundleIdentifier
            }
            items.append(SourceItem(
                id: source.bundleIdentifier ?? source.displayName,
                name: source.displayName,
                bundleID: source.bundleIdentifier,
                isActive: isActive
            ))
        }
        return items
    }

    private struct SourceItem: Identifiable {
        let id: String
        let name: String
        let bundleID: String?
        let isActive: Bool
    }
}

// MARK: - Chip

private struct PlayerChip: View {
    let name: String
    let bundleID: String?
    let isActive: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary.opacity(0.55))

            Text(name)
                .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? .primary : .secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isActive
                      ? Color.accentColor.opacity(0.14)
                      : Color.secondary.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isActive ? Color.accentColor.opacity(0.45) : Color.clear,
                    lineWidth: 0.5
                )
        )
        .help(tooltip)
    }

    private var tooltip: String {
        if let bundleID {
            return "\(name) (\(bundleID))"
        }
        return "\(name) — fallback for any app publishing to macOS Now Playing"
    }
}

// MARK: - Flow layout

/// Lightweight `Layout` that wraps subviews onto multiple lines, like
/// SwiftUI's `HStack` but with wrapping. Used for the chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = computeRows(maxWidth: maxWidth, subviews: subviews)
        let totalHeight = rows.reduce(CGFloat(0)) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * lineSpacing
        let widestRow = rows.map(\.width).max() ?? 0
        return CGSize(width: min(widestRow, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let prospective = rows[rows.count - 1].width
                + (rows[rows.count - 1].indices.isEmpty ? 0 : spacing)
                + size.width
            if prospective > maxWidth, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var current = rows[rows.count - 1]
            if !current.indices.isEmpty {
                current.width += spacing
            }
            current.indices.append(index)
            current.width += size.width
            current.height = max(current.height, size.height)
            rows[rows.count - 1] = current
        }
        return rows
    }
}
