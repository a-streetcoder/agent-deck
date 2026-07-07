import SwiftUI
import AppKit

struct PiAgentLoopControlBar: View {
    let run: LoopRun
    let onOpenDetails: () -> Void
    let onStop: () -> Void
    let onRetry: (() -> Void)?
    let onSave: (() -> Void)?
    let onRevealArtifacts: (() -> Void)?
    let onRevealWorktree: (() -> Void)?
    let onApplyWorktree: (() -> Void)?
    let onDiscardWorktree: (() -> Void)?
    let onApproveHumanApproval: (() -> Void)?
    let onRejectHumanApproval: (() -> Void)?

    var body: some View {
        AppRowCard {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "infinity")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(AppTheme.brandAccent)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(AppTheme.brandAccent.opacity(0.14)))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(titleText)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(run.displayStatusName)
                            .font(AppTheme.Font.caption.weight(.semibold))
                            .foregroundStyle(run.isActive ? AppTheme.brandAccent : AppTheme.mutedText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule(style: .continuous).fill((run.isActive ? AppTheme.brandAccent : AppTheme.mutedText).opacity(0.12)))
                    }
                    Text(detailText)
                        .font(AppTheme.Font.caption)
                        .foregroundStyle(AppTheme.mutedText)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                actions
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 10) {
            if canResolveHumanApproval || run.isActive {
                HStack(spacing: 8) {
                    if canResolveHumanApproval {
                        Button("Approve", action: { onApproveHumanApproval?() })
                            .appPrimaryButton()
                            .controlSize(.small)
                            .disabled(onApproveHumanApproval == nil)
                        Button("Reject", role: .destructive, action: { onRejectHumanApproval?() })
                            .appDestructiveButton()
                            .controlSize(.small)
                            .disabled(onRejectHumanApproval == nil)
                    }
                    if run.isActive {
                        Button("Stop", role: .destructive, action: onStop)
                            .appDestructiveButton()
                            .controlSize(.small)
                    }
                }
            }

            if canResolveHumanApproval || run.isActive {
                actionDivider
            }

            HStack(spacing: 8) {
                Button("Details", action: onOpenDetails)
                    .appSmallSecondaryButton()
                if canRetry {
                    Button("Retry Failed Iteration", action: { onRetry?() })
                        .appSmallSecondaryButton()
                        .disabled(onRetry == nil)
                }
                if canSave {
                    Button("Save Loop", action: { onSave?() })
                        .appSmallSecondaryButton()
                        .disabled(onSave == nil)
                }
            }

            if canRevealArtifacts || canRevealWorktree || canApplyWorktree || canDiscardWorktree {
                actionDivider
                HStack(spacing: 8) {
                    if canRevealArtifacts {
                        Button("Reveal Artifacts", action: { onRevealArtifacts?() })
                            .appSmallSecondaryButton()
                            .disabled(onRevealArtifacts == nil)
                    }
                    if canRevealWorktree {
                        Button("Reveal Worktree", action: { onRevealWorktree?() })
                            .appSmallSecondaryButton()
                            .disabled(onRevealWorktree == nil)
                    }
                    if canApplyWorktree {
                        Button("Apply Worktree", action: { onApplyWorktree?() })
                            .appSmallSecondaryButton()
                            .disabled(onApplyWorktree == nil)
                    }
                    if canDiscardWorktree {
                        Button("Discard Worktree", role: .destructive, action: { onDiscardWorktree?() })
                            .appDestructiveButton()
                            .controlSize(.small)
                            .disabled(onDiscardWorktree == nil)
                    }
                }
            }
        }
    }

    private var actionDivider: some View {
        Rectangle()
            .fill(AppTheme.hairlineStroke)
            .frame(width: 1, height: 20)
    }

    private var titleText: String {
        run.isActive ? "Loop running" : "Loop: \(run.structure.displayName)"
    }

    private var detailText: String {
        var parts = [run.structure.displayName, run.iterationProgressText]
        if let evaluation = run.iterations.last?.goalEvaluation {
            var evaluatorText = "Goal evaluator: \(evaluation.result.displayName)"
            if let rationale = evaluation.conciseRationaleText {
                evaluatorText += " — \(rationale)"
            }
            parts.append(evaluatorText)
        } else if let stopReason = run.stopReason, !run.isActive {
            parts.append("Stop reason: \(stopReason.displayName)")
        } else if let latest = run.iterations.last?.summary, !latest.isEmpty {
            parts.append(trimSummary(latest))
        }
        return parts.joined(separator: " · ")
    }

    private func trimSummary(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 140 else { return trimmed }
        return String(trimmed.prefix(140)) + "…"
    }

    private var canRetry: Bool { !run.isActive && run.status == .failed && !run.presentsGoalNotMetOutcome }
    private var canSave: Bool { !run.isActive }
    private var canRevealArtifacts: Bool { run.artifactDirectoryPath != nil && !canRevealWorktree }

    private var canRevealWorktree: Bool {
        run.writeTarget == .newWorktree && hasWorktree && !worktreeAlreadyHandled
    }

    private var canApplyWorktree: Bool {
        canOperateOnWorktree
    }

    private var canDiscardWorktree: Bool {
        canOperateOnWorktree
    }

    private var canResolveHumanApproval: Bool {
        run.structure == .humanApproval && run.status == .stopped && run.stopReason == .humanInputRequired
    }

    private var canOperateOnWorktree: Bool {
        run.writeTarget == .newWorktree && !run.isActive && hasWorktree && !worktreeAlreadyHandled
    }

    private var hasWorktree: Bool {
        guard let worktreeURL else { return false }
        return FileManager.default.fileExists(atPath: worktreeURL.path)
    }

    private var worktreeAlreadyHandled: Bool {
        run.worktreeState == .applied || run.worktreeState == .discarded || hasAppliedMarker || hasDiscardedMarker
    }

    private var worktreeURL: URL? {
        run.artifactDirectoryPath.map { URL(fileURLWithPath: $0).appendingPathComponent("worktree", isDirectory: true) }
    }

    private var hasAppliedMarker: Bool {
        guard let artifactDirectoryURL else { return false }
        return FileManager.default.fileExists(atPath: artifactDirectoryURL.appendingPathComponent("worktree.applied").path)
    }

    private var hasDiscardedMarker: Bool {
        guard let artifactDirectoryURL else { return false }
        return FileManager.default.fileExists(atPath: artifactDirectoryURL.appendingPathComponent("worktree.discarded").path)
    }

    private var artifactDirectoryURL: URL? {
        run.artifactDirectoryPath.map { URL(fileURLWithPath: $0) }
    }
}

struct PiAgentLoopDetailsSheet: View {
    let run: LoopRun
    let revealActionTitle: String?
    let onRevealAction: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Loop Details")
                        .font(.title2.weight(.bold))
                    Text("\(run.structure.displayName) · \(run.displayStatusName) · \(run.iterationProgressText)")
                        .font(AppTheme.Font.footnote)
                        .foregroundStyle(AppTheme.mutedText)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(run.goal)
                        .font(AppTheme.Font.body)
                        .foregroundStyle(.primary)
                    if let stopReason = run.stopReason {
                        detailRow("Stop reason", stopReason.displayName)
                    }
                    ForEach(run.iterations) { iteration in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Iteration \(iteration.index)")
                                .font(AppTheme.Font.body.weight(.semibold))
                            Text(iteration.summary)
                                .font(AppTheme.Font.footnote)
                                .foregroundStyle(.secondary)
                            if let checkerResult = iteration.checkerResult {
                                detailRow("Checker", checkerResult.displayName)
                            }
                            if let evaluation = iteration.goalEvaluation {
                                detailRow("Goal evaluator", evaluation.result.displayName)
                                if !evaluation.rationale.isEmpty {
                                    detailRow("Evaluator rationale", evaluation.rationale)
                                }
                                if let childRunReference = evaluation.childRunReferenceText {
                                    detailRow("Evaluator child", childRunReference.replacingOccurrences(of: "Evaluator child run: ", with: ""))
                                }
                            }
                            if let validation = iteration.validationResult {
                                detailRow("Validation", validation.didPass ? "Passed" : "Failed")
                            }
                            if !iteration.artifacts.isEmpty {
                                detailRow("Artifacts", iteration.artifacts.map(\.filename).joined(separator: ", "))
                            }
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppTheme.panelFill.opacity(0.5)))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                if let revealActionTitle, let onRevealAction {
                    Button(revealActionTitle, action: onRevealAction)
                }
                Spacer()
            }
        }
        .padding(20)
        .frame(width: 560, height: 460)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label + ":")
                .font(AppTheme.Font.caption.weight(.semibold))
                .foregroundStyle(AppTheme.mutedText)
            Text(value)
                .font(AppTheme.Font.caption)
                .foregroundStyle(.secondary)
        }
    }
}
