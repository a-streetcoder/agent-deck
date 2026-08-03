import Foundation

// MARK: - Environment key editor drafts

extension AppViewModel {
    func makeEnvDraft(for record: EnvKeyRecord) -> EnvEditorDraft {
        envPersistence.makeDraft(for: record)
    }

    func makeNewEnvDraft(prefilledKey: String? = nil) -> EnvEditorDraft {
        envPersistence.makeNewDraft(prefilledKey: prefilledKey)
    }

    func saveEnvDrafts(_ drafts: [EnvEditorDraft]) throws {
        guard !drafts.isEmpty else { return }
        // A batch targets the global file. Recording inside the loop and
        // refreshing in `defer` keeps refreshes running for files already
        // written even if a later save throws.
        var written: [(scope: ResourceScopeKind, path: String)] = []
        defer {
            for file in written {
                refreshAfterFileScopedChange(sourceKind: file.scope, filePath: file.path)
            }
        }
        for draft in drafts {
            try envPersistence.save(draft)
            if !written.contains(where: { $0.path == draft.path }) {
                written.append((draft.scope, draft.path))
            }
        }
    }

    func deleteEnvKey(_ record: EnvKeyRecord) throws {
        try envPersistence.delete(record)
        refreshAfterFileScopedChange(sourceKind: record.source.kind, filePath: record.source.path)
    }

}
