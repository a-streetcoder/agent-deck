import SwiftUI

/// Standalone toolbar button (agent-deck repo only) that opens the release sheet.
/// Mirrors `PiAgentOpenTerminalToolbarButton`'s neutral, monochrome chrome so it
/// reads as its own glass island. Visibility is gated upstream by
/// `viewModel.shouldShowAgentDeckReleaseAction`.
struct PiAgentReleaseToolbarButton: View {
    var viewModel: AppViewModel
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Label("Release", systemImage: "shippingbox")
        }
        .accessibilityLabel("Release")
        .symbolRenderingMode(.monochrome)
        .foregroundStyle(.primary)
        .tint(.primary)
        .help("Tag and push a new \(AppBrand.displayName) release")
        .sheet(isPresented: $isPresented) {
            AgentDeckReleaseSheet(viewModel: viewModel)
        }
    }
}

/// Replaces `scripts/release.sh`: preflights main, lets you pick a patch/minor/major
/// bump, and tags + pushes. Follows the shared modal-sheet chrome.
struct AgentDeckReleaseSheet: View {
    var viewModel: AppViewModel

    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case loading
        case ready
        case releasing
        case done
    }

    private enum NotesState: Equatable {
        case idle
        case generating
        case ready
        case failed
    }

    @State private var phase: Phase = .loading
    @State private var preflight: ReleaseService.Preflight?
    @State private var bump: ReleaseService.Bump = .minor
    @State private var pushedTag: String?
    @State private var errorMessage: String?
    @State private var notesText: String = ""
    @State private var notesState: NotesState = .idle
    @State private var didStartNotes = false

    private var projectURL: URL? { viewModel.agentDeckReleaseProjectURL }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
            Divider()
            footer
        }
        .frame(width: 460)
        .task {
            await runPreflight()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Release \(AppBrand.displayName)")
                .font(.headline)
                .fontWidth(.expanded)
            Text(ReleaseService.repository)
                .font(.caption.monospaced())
                .foregroundStyle(AppTheme.mutedText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Checking \(ReleaseService.mainBranch)…")
                    .foregroundStyle(AppTheme.mutedText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .ready:
            if let preflight {
                readyContent(preflight)
            } else {
                errorBlock
            }

        case .releasing:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Tagging and pushing \(preflight?.tag(for: bump) ?? "")…")
                    .foregroundStyle(AppTheme.mutedText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .done:
            doneContent
        }
    }

    @ViewBuilder
    private func readyContent(_ preflight: ReleaseService.Preflight) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                statusRow(
                    label: "Current version",
                    value: preflight.latestTag ?? "none",
                    ok: true
                )
                statusRow(
                    label: "Branch",
                    value: preflight.branch,
                    ok: preflight.branch == ReleaseService.mainBranch
                )
                statusRow(
                    label: "Working tree",
                    value: preflight.isClean ? "clean" : "uncommitted changes",
                    ok: preflight.isClean
                )
                statusRow(
                    label: "Sync",
                    value: syncDescription(preflight),
                    ok: preflight.ahead == 0 && preflight.behind == 0
                )
            }

            if let blocker = preflight.blocker {
                Label(blocker, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("New version")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedText)
                    Picker("Bump", selection: $bump) {
                        Text("Patch — \(preflight.nextPatch)").tag(ReleaseService.Bump.patch)
                        Text("Minor — \(preflight.nextMinor)").tag(ReleaseService.Bump.minor)
                        Text("Major — \(preflight.nextMajor)").tag(ReleaseService.Bump.major)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text("Tags \(preflight.tag(for: bump)) and pushes it to \(ReleaseService.remote). CI then builds, signs, and publishes the release.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                releaseNotesSection
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var releaseNotesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Release notes")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.mutedText)
                Spacer()
                Button {
                    Task { await generateNotes() }
                } label: {
                    Label("Regenerate", systemImage: "sparkles")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(AppTheme.brandAccent)
                .disabled(notesState == .generating)
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $notesText)
                    .font(.callout)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 150)
                    .background(AppTheme.contentSubtleFill, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(AppTheme.hairlineStroke))

                if notesState == .generating {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Writing release notes…")
                            .foregroundStyle(AppTheme.mutedText)
                    }
                    .font(.caption)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .allowsHitTesting(false)
                }
            }

            Text(notesCaption)
                .font(.caption)
                .foregroundStyle(notesState == .failed ? .orange : AppTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var notesCaption: String {
        switch notesState {
        case .failed:
            return "Couldn't draft notes — edit your own below, or leave it empty to let CI list the commits."
        default:
            return "AI-drafted from your commits. Edit freely; the heading and version are added automatically. Leave empty to let CI list the commits."
        }
    }

    @ViewBuilder
    private var doneContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Tagged and pushed \(pushedTag ?? "")", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
            Text("The release build is now running in CI.")
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
            VStack(alignment: .leading, spacing: 6) {
                if let actions = ReleaseService.actionsURL() {
                    Link(destination: actions) {
                        Label("Watch the build", systemImage: "arrow.up.forward.app")
                    }
                }
                if let tag = pushedTag, let release = ReleaseService.releaseURL(tag: tag) {
                    Link(destination: release) {
                        Label("Release page", systemImage: "shippingbox")
                    }
                }
            }
            .font(.callout)
        }
    }

    @ViewBuilder
    private var errorBlock: some View {
        Label(errorMessage ?? "Couldn't read the repository.", systemImage: "xmark.octagon.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func statusRow(label: String, value: String, ok: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? Color.green : Color.orange)
            Text(label)
                .foregroundStyle(AppTheme.mutedText)
            Spacer()
            Text(value)
                .font(.callout.monospaced())
        }
        .font(.callout)
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack {
            Spacer()
            switch phase {
            case .done:
                Button("Done") { dismiss() }
                    .appPrimaryButton()
                    .keyboardShortcut(.defaultAction)
            default:
                Button("Cancel") { dismiss() }
                    .appSecondaryButton()
                    .disabled(phase == .releasing)
                Button(confirmTitle) { Task { await confirm() } }
                    .appPrimaryButton()
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConfirm)
            }
        }
        .padding(16)
    }

    private var confirmTitle: String {
        guard let preflight, preflight.isReleasable else { return "Release" }
        return "Release \(preflight.tag(for: bump))"
    }

    private var canConfirm: Bool {
        phase == .ready && (preflight?.isReleasable ?? false)
    }

    // MARK: - Actions

    private func syncDescription(_ preflight: ReleaseService.Preflight) -> String {
        if preflight.ahead == 0 && preflight.behind == 0 { return "up to date" }
        var parts: [String] = []
        if preflight.ahead > 0 { parts.append("\(preflight.ahead) ahead") }
        if preflight.behind > 0 { parts.append("\(preflight.behind) behind") }
        return parts.joined(separator: ", ")
    }

    private func runPreflight() async {
        guard let projectURL else {
            errorMessage = "No project is selected."
            phase = .ready
            return
        }
        do {
            preflight = try await viewModel.agentDeckReleaseService.preflight(projectURL: projectURL)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        phase = .ready
        // Draft notes once the repo is releasable. Fire-and-forget so the ready
        // UI renders immediately; the notes editor shows its own progress.
        if let preflight, preflight.isReleasable, !didStartNotes {
            didStartNotes = true
            Task { await generateNotes() }
        }
    }

    private func generateNotes() async {
        guard let preflight else { return }
        notesState = .generating
        do {
            let notes = try await viewModel.generateAgentDeckReleaseNotes(
                version: preflight.tag(for: bump),
                sinceTag: preflight.latestTag
            )
            notesText = notes
            notesState = .ready
        } catch {
            // Leave whatever the user has typed; an empty body lets CI list commits.
            notesState = .failed
        }
    }

    private func confirm() async {
        guard let projectURL, let preflight, preflight.isReleasable else { return }
        let tag = preflight.tag(for: bump)
        errorMessage = nil
        phase = .releasing
        do {
            try await viewModel.agentDeckReleaseService.tagAndPush(tag: tag, notes: notesText, projectURL: projectURL)
            viewModel.recordAgentDeckReleaseSucceeded(tag: tag)
            pushedTag = tag
            phase = .done
        } catch {
            errorMessage = error.localizedDescription
            phase = .ready
        }
    }
}
