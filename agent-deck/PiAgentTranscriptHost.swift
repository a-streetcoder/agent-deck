import AppKit
import Combine
import SwiftUI

// MARK: - SwiftUI host isolating render-cache observation

struct PiAgentTranscriptHost: View {
    @ObservedObject var cache: PiAgentTranscriptRenderCache
    let sessionID: UUID?
    /// Read LIVE (like `makeItems`), never captured as a value: the host
    /// re-evaluates on render-cache pulses without the parent re-running, and a
    /// stale captured flag kept the switch "hold" active one SwiftUI round-trip
    /// after the transcript had already decoded — a visible lag on every switch.
    let isTranscriptLoading: () -> Bool
    let bottomScrollRequest: Int
    let makeItems: () -> [PiAgentAppKitTranscriptItem]
    let onPinnedToBottomChange: (Bool) -> Void
    let onBenchAdvanceSession: () -> Void
    let benchSessionCount: () -> Int

    var body: some View {
        PiAgentAppKitTranscriptView(
            items: makeItems(),
            sessionID: sessionID,
            itemsSessionID: cache.contentSessionID,
            isTranscriptLoading: isTranscriptLoading(),
            renderRevision: cache.renderRevision,
            streamingRevision: cache.streamingRevision,
            autoScrollTurnRevision: cache.autoScrollTurnRevision,
            bottomScrollRequest: bottomScrollRequest,
            onPinnedToBottomChange: onPinnedToBottomChange,
            onScrollingChange: { [cache] scrolling in cache.setUserScrolling(scrolling) },
            onBenchAdvanceSession: onBenchAdvanceSession,
            benchSessionCount: benchSessionCount
        )
    }
}
