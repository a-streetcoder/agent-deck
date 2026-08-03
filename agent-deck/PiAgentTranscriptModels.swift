import AppKit
import Foundation
import SwiftUI

// MARK: - Timeline items, cell kinds, AppKit row models, question-rail policy

extension PiAgentTranscriptEntry {
    var isNativeSubagentCard: Bool {
        guard let rawJSON,
              let data = rawJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return false }
        return type == "agent_deck_subagent_started" || type == "agent_deck_subagent_card"
    }

}

struct PiAgentTranscriptTimelineItem: Identifiable {
    enum Kind {
        case thread(PiAgentTranscriptThread)
    }

    let id: String
    let timestamp: Date
    let kind: Kind
}

struct PiAgentTranscriptTimelineSnapshot {
    let allItems: [PiAgentTranscriptTimelineItem]
    let visibleItems: [PiAgentTranscriptTimelineItem]
    let mainVisibleItems: [PiAgentTranscriptTimelineItem]
    let earlierVisibleItems: [PiAgentTranscriptTimelineItem]
    let preCompactionArchive: (hiddenCount: Int, compactedAt: Date)?
    let recentWindowArchive: (hiddenCount: Int, limit: Int)?
}

/// How a transcript row is rendered. Every row is now fully native AppKit (no
/// per-row SwiftUI / `NSHostingView`); the spec knows how to build/configure/
/// measure the concrete view.
enum PiAgentTranscriptCellKind {
    case native(NativeRowSpec)
}

extension PiAgentTranscriptCellKind {
    /// Convenience for a native message bubble.
    static func bubble(_ payload: NativeBubblePayload) -> PiAgentTranscriptCellKind {
        .native(.of(PiAgentNativeBubbleView.self, prewarmPolicy: .extendedIdle) { view, width in
            view.configure(payload: payload, width: width)
        })
    }
}

/// Resolves a reported row height without allowing a streaming row to shrink
/// below a real measurement at its current width. Tiled estimates deliberately
/// do not participate: a row's first real measurement must be able to replace
/// its initial estimate.
enum TranscriptMeasuredHeightResolver {
    static func resolvedHeight(
        _ measuredHeight: CGFloat,
        priorMeasuredHeight: CGFloat?,
        isStreaming: Bool
    ) -> CGFloat {
        guard isStreaming, let priorMeasuredHeight else { return measuredHeight }
        return max(measuredHeight, priorMeasuredHeight)
    }
}

struct PiAgentAppKitTranscriptItem {
    let id: String
    let kind: PiAgentTranscriptCellKind
    let contentRevision: Int
    /// Non-nil only for top-level user question rows (`q-<threadID>`). Used by
    /// the transcript-side navigation rail without affecting row layout.
    let questionNavigationTitle: String?
    /// Vertical spacing baked into the row, applied as padding inside the cell.
    /// `NSTableView.intercellSpacing` is uniform, but the transcript needs
    /// different gaps (question↔reply, sibling, thread↔thread) — so each gap is
    /// split in half across the two adjacent rows' facing insets. Folded into
    /// `contentRevision` so an inset change re-tiles the row.
    let topInset: CGFloat
    let bottomInset: CGFloat
    /// Fast height estimate used by `heightOfRow` before the cell renders.
    /// Closer estimates produce smoother first paint — the cell self-measures
    /// after it renders and reports its actual height back via callback.
    /// Includes the row insets so the estimate matches the measured height.
    let estimatedHeight: (CGFloat) -> CGFloat

    init(
        id: String,
        kind: PiAgentTranscriptCellKind,
        contentRevision: Int = 0,
        questionNavigationTitle: String? = nil,
        topInset: CGFloat = 0,
        bottomInset: CGFloat = 0,
        estimatedHeight: @escaping (CGFloat) -> CGFloat = { _ in 120 }
    ) {
        self.id = id
        self.kind = kind
        self.contentRevision = contentRevision
        self.questionNavigationTitle = questionNavigationTitle
        self.topInset = topInset
        self.bottomInset = bottomInset
        self.estimatedHeight = estimatedHeight
    }
}


enum PiAgentTranscriptTableSection: Hashable {
    case main
}

struct UserQuestionNavigationRailItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let isActive: Bool
    /// Vertical px offset from the rail's center, used only in sliding-window
    /// mode (many questions). 0 = rail center; negative = older (up), positive
    /// = newer (down), mirroring the transcript so marks track their messages.
    var centerOffset: CGFloat = 0
}

enum TranscriptFloatingControlGeometry {
    static let transcriptHorizontalPadding: CGFloat = 18
    static let jumpToLatestTrailingPadding: CGFloat = 22
    static let questionRailCollapsedWidth: CGFloat = 22
    static let questionRailRowHeight: CGFloat = 22
    static let questionRailRowSpacing: CGFloat = 6
    static let questionRailVerticalPadding: CGFloat = 16
    static let questionScrollTopPadding: CGFloat = 12

    /// The rail is hosted inside the AppKit scroll view, while the scroll-to-bottom
    /// FAB is hosted by the surrounding SwiftUI ZStack. Compensate for the transcript
    /// SwiftUI horizontal padding so both trailing strokes land on the same screen x.
    static var questionRailTrailingInsetInsideScrollView: CGFloat {
        max(0, jumpToLatestTrailingPadding - transcriptHorizontalPadding)
    }
}

struct QuestionRailVisibilityPolicy {
    func shouldShow(questionCount: Int, evenStackedHeight: CGFloat, railHeight: CGFloat) -> Bool {
        questionCount >= 2 && railHeight >= 44
    }
}

struct QuestionRailActiveQuestionResolver {
    let landingOffset: CGFloat
    let visibleHeight: CGFloat
    let bottomTolerance: CGFloat

    init(landingOffset: CGFloat, visibleHeight: CGFloat, bottomTolerance: CGFloat = 2) {
        self.landingOffset = landingOffset
        self.visibleHeight = visibleHeight
        self.bottomTolerance = bottomTolerance
    }

    func activeID(questions: [(id: String, minY: CGFloat)], viewportY: CGFloat, documentHeight: CGFloat) -> String? {
        guard !questions.isEmpty else { return nil }
        let maxY = max(0, documentHeight - visibleHeight)
        if maxY - viewportY < bottomTolerance {
            return questions.last?.id
        }

        let anchorY = viewportY + landingOffset
        return questions.last(where: { $0.minY <= anchorY })?.id ?? questions.first?.id
    }
}

struct QuestionRailScrollLandingResolver {
    let landingOffset: CGFloat
    let visibleHeight: CGFloat
    let tolerance: CGFloat
    let maxCorrections: Int

    init(landingOffset: CGFloat, visibleHeight: CGFloat, tolerance: CGFloat = 1, maxCorrections: Int = 6) {
        self.landingOffset = landingOffset
        self.visibleHeight = visibleHeight
        self.tolerance = tolerance
        self.maxCorrections = maxCorrections
    }

    func targetY(rowMinY: CGFloat, documentHeight: CGFloat) -> CGFloat {
        let maxY = max(0, documentHeight - visibleHeight)
        return min(max(0, rowMinY - landingOffset), maxY)
    }

    func needsCorrection(currentY: CGFloat, rowMinY: CGFloat, documentHeight: CGFloat) -> CGFloat? {
        let nextY = targetY(rowMinY: rowMinY, documentHeight: documentHeight)
        return abs(nextY - currentY) > tolerance ? nextY : nil
    }
}

enum QuestionRailKeyboardDirection {
    case previous
    case next
}

struct QuestionRailKeyboardNavigator {
    func targetID(questionIDs: [String], activeID: String?, direction: QuestionRailKeyboardDirection) -> String? {
        guard questionIDs.count >= 2 else { return nil }
        guard let activeID, let currentIndex = questionIDs.firstIndex(of: activeID) else {
            return direction == .previous ? questionIDs.last : questionIDs.first
        }

        switch direction {
        case .previous:
            guard currentIndex > questionIDs.startIndex else { return nil }
            return questionIDs[questionIDs.index(before: currentIndex)]
        case .next:
            let nextIndex = questionIDs.index(after: currentIndex)
            guard nextIndex < questionIDs.endIndex else { return nil }
            return questionIDs[nextIndex]
        }
    }
}

