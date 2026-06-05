import AppKit
import SwiftUI

/// Identifies an in-progress update that stalled on files edited both locally
/// and upstream — drives the conflict-resolution sheet.
struct SkillUpdateConflictContext: Identifiable {
    let id = UUID()
    let repository: ImportedSkillRepository
    let conflicts: [SkillRepositoryConflict]
}

/// Lets the user resolve a synced skill update where their in-place edits
/// collide with upstream changes — Keep Mine or Take Remote, per file.
struct SkillUpdateConflictSheet: View {
    var viewModel: AppViewModel
    let context: SkillUpdateConflictContext
    @Binding var isPresented: Bool
    var onResolved: (SkillRepositoryUpdateOutcome) -> Void

    @State private var resolutions: [String: SkillConflictResolution] = [:]
    @State private var isApplying = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Resolve Update Conflicts")
                    .font(.headline)
                    .fontWidth(.expanded)
                Text("These files in \(context.repository.displayName) were edited here and upstream. Choose which version to keep for each.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)

            Divider()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(context.conflicts) { conflict in
                        conflictRow(conflict)
                        if conflict.id != context.conflicts.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(18)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()

            HStack {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
                Spacer()
                Button("Cancel") { isPresented = false }
                    .appSecondaryButton()
                    .keyboardShortcut(.cancelAction)
                Button {
                    apply()
                } label: {
                    if isApplying {
                        AppSpinner().controlSize(.small)
                    } else {
                        Text("Apply Update")
                    }
                }
                .appPrimaryButton()
                .keyboardShortcut(.defaultAction)
                .disabled(isApplying)
            }
            .padding(16)
        }
        .frame(width: 560, height: 460)
        .onAppear {
            for conflict in context.conflicts where resolutions[conflict.repoRelativePath] == nil {
                resolutions[conflict.repoRelativePath] = .keepMine
            }
        }
    }

    private func conflictRow(_ conflict: SkillRepositoryConflict) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(conflict.fileName)
                .font(.body.weight(.semibold))
            Text(conflict.repoRelativePath)
                .font(.caption.monospaced())
                .foregroundStyle(AppTheme.mutedText)
                .lineLimit(1)
                .truncationMode(.middle)
            Picker("Resolution", selection: Binding(
                get: { resolutions[conflict.repoRelativePath] ?? .keepMine },
                set: { resolutions[conflict.repoRelativePath] = $0 }
            )) {
                Text("Keep Mine").tag(SkillConflictResolution.keepMine)
                Text("Take Remote").tag(SkillConflictResolution.takeRemote)
            }
            .appSegmentedPicker()
            .labelsHidden()
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func apply() {
        isApplying = true
        errorMessage = nil
        Task {
            do {
                let outcome = try await viewModel.resolveSkillRepositoryUpdate(
                    context.repository,
                    resolutions: resolutions
                )
                isApplying = false
                isPresented = false
                onResolved(outcome)
            } catch {
                isApplying = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
