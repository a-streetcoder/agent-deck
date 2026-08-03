import AppKit
import Combine
import SwiftUI

// MARK: - Active session column layout

extension PiAgentScreen {
    var activeSessionPaneBoundary: some View {
        Color.clear
            .frame(minWidth: 360, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .overlay(alignment: .topLeading) {
                activeSessionColumn
            }
    }

    var activeSessionColumn: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                transcript
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, TranscriptFloatingControlGeometry.transcriptHorizontalPadding)
                    // Suppress the edge-fade `.mask` while a splitter drag is
                    // active: its gradient smears into a full-column blur mask
                    // until the table re-lays out to the settled width.
                    .transcriptEdgeFade(enabled: !isColumnResizing)

                // NOTE: the old opaque "settle cover" (spinner shown over the
                // transcript on every session switch) is gone. The switch is now
                // correct on its first frame — the coordinator holds the previous
                // transcript until the new one is decoded, then measures the
                // visible rows synchronously before pinning — so hiding the table
                // behind a spinner only ADDED a flash of loading state per click.

                // Sits ON TOP of the edge fade (added after it) so the pill
                // itself is never faded out. Isolated in its own view that observes
                // `transcriptPinnedState` so toggling the pill never re-evaluates this
                // screen's body (and never re-runs the transcript items build).
                JumpToLatestOverlay(pinnedState: transcriptPinnedState) {
                    requestTranscriptBottomScroll()
                }
            }
            PiAgentProcessingIndicatorBar(message: stabilizedProcessingMessage)

            Divider()

            VStack(spacing: 12) {
                // Shown for project drafts, including subagents-off — the card
                // renders dimmed with its switch so agents can be turned back
                // on right here instead of from the Agents screen. General Chat
                // never exposes Deck-agent delegation.
                if let session = store.selectedSession,
                   !session.isNoProject,
                   session.status == .draft,
                   store.activeLoopRun(for: session.id) == nil {
#if DEBUG
                    PiAgentSessionSubagentPickerCard(
                        viewModel: viewModel,
                        session: session,
                        stressExpansionRequest: isPickerStressRequested ? pickerStressExpansionRequest : nil,
                        stressRowSource: isPickerStressRequested ? pickerStressRowSource : nil,
                        stressAcknowledgements: isPickerStressRequested ? pickerStressAcknowledgements : nil
                    )
                    .id(session.id)
#else
                    PiAgentSessionSubagentPickerCard(viewModel: viewModel, session: session)
                        .id(session.id)
#endif
                }

                if let request = store.selectedUIRequest {
                    PiAgentUIRequestInlineNotice(
                        request: request,
                        onRespond: { isUIRequestSheetPresented = true },
                        onCancel: { viewModel.cancelPiAgentUIRequest(request) }
                    )
                } else if let request = selectedPendingSupervisorRequest {
                    PiSubagentSupervisorRequestInlineNotice(
                        request: request,
                        onRespond: { isSupervisorRequestSheetPresented = true },
                        onCancel: { viewModel.cancelSubagentSupervisorRequest(request.id, parentSessionID: request.parentSessionID) }
                    )
                }

                PiAgentComposerPanel(
                    viewModel: viewModel,
                    store: store,
                    selectedSessionID: store.selectedSessionID,
                    onWillSend: beginTranscriptAutoScrollTurn,
                    onDidSend: requestTranscriptBottomScroll
                )
                .equatable()
            }
            .padding(18)
        }
    }

    @ViewBuilder
    var sessionHeader: some View {
        if let session = store.selectedSession {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    AppLabelTag(text: session.kind.rawValue, color: sessionKindTagColor(session.kind))
                    if session.isAgentBound, let agentName = session.agentName, !agentName.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles.rectangle.stack")
                                .font(AppTheme.Font.caption2.weight(.semibold))
                            Text(LanguageStore.shared.t("agent.chatWith", agentName))
                                .font(AppTheme.Font.footnote.weight(.semibold))
                        }
                        .foregroundStyle(AppTheme.brandAccent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule(style: .continuous).fill(AppTheme.brandAccent.opacity(0.12)))
                    }
                    AppLabelTag(text: effectiveStatus(for: session), color: effectiveStatusColor(for: session))
                    Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(AppTheme.Font.footnote)
                        .foregroundStyle(AppTheme.mutedText)
                    Spacer(minLength: 0)
                }
                Text(session.displayTitle)
                    .font(.title3.bold())
                    .fontWidth(.expanded)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)

                if let error = session.lastError {
                    Text(error)
                        .font(AppTheme.Font.footnote)
                        .foregroundStyle(.red)
                }
            }
        } else {
            AppCard(title: LanguageStore.shared.t("agent.noSessionTitle")) {
                Text(LanguageStore.shared.t("agent.noSessionBody"))
                    .foregroundStyle(AppTheme.mutedText)
            }
        }
    }

    var transcript: some View {
        // `PiAgentTranscriptHost` is the ONLY view that observes `transcriptCache`,
        // so the ~30Hz streaming pulse re-renders the transcript table alone and no
        // longer invalidates this screen's session list / composer. `makeItems` is
        // re-run inside the host on each pulse; it reads the live cache + parent
        // references (store/viewModel), so the items stay correct even though the
        // parent struct it captured isn't re-evaluated between pulses.
        PiAgentTranscriptHost(
            cache: transcriptCache,
            sessionID: store.selectedSession?.id,
            isTranscriptLoading: { [store] in store.isSelectedTranscriptLoading },
            bottomScrollRequest: transcriptBottomScrollRequest,
            makeItems: { appKitTranscriptItems },
            onPinnedToBottomChange: { isPinnedToBottom in
                transcriptPinnedState.isPinned = isPinnedToBottom
            },
            onBenchAdvanceSession: { viewModel.selectNextPiAgentSession() },
            benchSessionCount: { viewModel.scopedPiAgentSessionsInOrder().count }
        )
        .onChange(of: selectedSessionProcessingMessage) { _, message in
            updateStabilizedProcessingMessage(message)
            guard message != nil, transcriptPinnedState.isPinned else { return }
            requestTranscriptBottomScroll()
        }
        .perfScene("PiAgentTranscript")
    }

}
