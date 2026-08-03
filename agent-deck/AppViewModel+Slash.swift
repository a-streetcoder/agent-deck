import Foundation

// MARK: - Slash universe / composer catalog

extension AppViewModel {
    func refreshedSlashItemForUse(_ item: SlashItem, projectPath: String?) -> SlashItem {
        switch item.payload {
        case .skill(let name, let body, let filePath, let recordID):
            let currentBody = latestSkillBody(name: name, filePath: filePath, recordID: recordID, projectPath: projectPath) ?? body
            return SlashItem(id: item.id, kind: item.kind, displayName: item.displayName, description: item.description, scopeLabel: item.scopeLabel, isActive: item.isActive, payload: .skill(name: name, body: currentBody, filePath: filePath, recordID: recordID))
        case .skillCollection(let id, let name, let body):
            guard let collection = appSettings.skillCollections.first(where: { $0.id == id }) else { return item }
            let currentBody = slashSkillCollectionBody(collection, forProjectPath: projectPath)
            return SlashItem(id: item.id, kind: item.kind, displayName: item.displayName, description: item.description, scopeLabel: item.scopeLabel, isActive: item.isActive, payload: .skillCollection(id: id, name: name, body: currentBody.isEmpty ? body : currentBody))
        case .prompt(let name, let body, let filePath, let recordID):
            let currentBody = latestPromptBody(name: name, filePath: filePath, recordID: recordID, projectPath: projectPath) ?? body
            return SlashItem(id: item.id, kind: item.kind, displayName: item.displayName, description: item.description, scopeLabel: item.scopeLabel, isActive: item.isActive, payload: .prompt(name: name, body: currentBody, filePath: filePath, recordID: recordID))
        case .loopDefinition(let definition):
            let currentDefinition = loopDefinitionForLaunch(definition)
            return SlashItem(id: item.id, kind: item.kind, displayName: item.displayName, description: item.description, scopeLabel: item.scopeLabel, isActive: item.isActive, payload: .loopDefinition(currentDefinition))
        case .command, .loopCreateNew:
            return item
        }
    }

    func latestSkillBody(name: String, filePath: String?, recordID: String?, projectPath: String?) -> String? {
        if let filePath, let body = try? String(contentsOfFile: filePath, encoding: .utf8) { return body }
        let catalog = projectPath.flatMap { skillCatalog(forProjectPath: $0) } ?? globalSnapshot.skills
        return catalog.first { $0.id == recordID || $0.filePath == filePath || $0.name == name }?.body
    }

    func latestPromptBody(name: String, filePath: String?, recordID: String?, projectPath: String?) -> String? {
        if let filePath, let body = try? String(contentsOfFile: filePath, encoding: .utf8) { return body }
        let catalog = projectPath.flatMap { promptTemplateCatalog(forProjectPath: $0) } ?? globalSnapshot.promptTemplates
        return catalog.first { $0.id == recordID || $0.filePath == filePath || $0.name == name }?.body
    }

    func slashSkillCollectionBody(_ collection: SkillCollectionRecord, forProjectPath projectPath: String?, catalog providedCatalog: [SkillRecord]? = nil) -> String {
        let catalog = providedCatalog ?? projectPath.flatMap { skillCatalog(forProjectPath: $0) } ?? globalSnapshot.skills
        let members = skillRecords(in: collection, forProjectPath: projectPath)
            .filter { !skillIsExcludedFromRuntime($0, in: collection, catalog: catalog) }
        let memberList = members.map { "- `\($0.name)`" }.joined(separator: "\n")
        let description = collection.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        # \(collection.name)

        \(description?.isEmpty == false ? description! : "Skill collection")

        Included skills:
        \(memberList.isEmpty ? "- None" : memberList)
        """
    }

    /// Materializes the full universe of Skills, Prompts, Commands, and Loops the
    /// composer's `/` browser can show. Build once when the panel opens and hold
    /// the result in `@State` — never call inside a SwiftUI `body`.
    ///
    /// - Parameter runtimeSlashCommands: Pi `get_commands` for the active session
    ///   (extension registerCommand list + runtime skills/prompts). Merged so
    ///   user extensions appear in `/` even when not in Deck's Command Library.
    func slashUniverse(
        forProjectPath projectPath: String?,
        useSelectedProjectFallback: Bool = true,
        runtimeSlashCommands: [PiRuntimeSlashCommand]? = nil
    ) -> SlashUniverse {
        let fallback = useSelectedProjectFallback ? selectedProjectPath : nil
        let scopedPath = (projectPath ?? fallback)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        guard scopedPath != nil || useSelectedProjectFallback else { return .empty }
        let projectFeatureSlashEnabled = scopedPath != nil

        let runtime = runtimeSlashCommands ?? []
        let runtimeSkillNames: Set<String> = Set(runtime.compactMap { cmd in
            guard cmd.isSkill else { return nil }
            var bare = cmd.bareName
            if bare.hasPrefix("skill:") { bare = String(bare.dropFirst("skill:".count)) }
            return bare
        })
        let runtimePromptNames: Set<String> = Set(runtime.compactMap { cmd in
            guard cmd.source == "prompt", !cmd.isSkill else { return nil }
            return cmd.bareName
        })
        let runtimeExtensionCommands = runtime.filter(\.isExtensionCommand)

        // Skills
        let catalogSkillRecords: [SkillRecord]
        if let path = scopedPath {
            catalogSkillRecords = skillCatalog(forProjectPath: path)
        } else {
            catalogSkillRecords = globalSnapshot.skills
        }
        let activeSkillNames = activeParentSkillNames(forProjectPath: scopedPath, useSelectedProjectFallback: false)
            .union(runtimeSkillNames)
        let activeCollectionIDs = appSettings.defaultSkillCollectionIDs.union(scopedPath.map { projectPreference(for: $0).assignedSkillCollectionIDs } ?? [])
        let disabledBundledSkillNames = appSettings.disabledBundledSkillNames
        var seenSkillName = Set<String>()
        let individualSkillItems = catalogSkillRecords
            .filter { !($0.source.kind == .builtin && disabledBundledSkillNames.contains($0.name)) }
            .filter { seenSkillName.insert($0.name).inserted }
            .map { record in
                SlashItem(
                    id: "skill:\(record.id)",
                    kind: .skill,
                    displayName: record.name,
                    description: record.description?.isEmpty == false ? record.description : nil,
                    scopeLabel: record.source.displayName,
                    isActive: activeSkillNames.contains(record.name),
                    payload: .skill(name: record.name, body: record.body, filePath: record.filePath, recordID: record.id)
                )
            }
        let collectionItems = appSettings.skillCollections.map { collection in
            let body = slashSkillCollectionBody(collection, forProjectPath: scopedPath, catalog: catalogSkillRecords)
            let description = collection.description?.trimmingCharacters(in: .whitespacesAndNewlines)
            return SlashItem(
                id: "skill-collection:\(collection.id.uuidString)",
                kind: .skill,
                displayName: collection.name,
                description: description?.isEmpty == false ? description : "Skill collection",
                scopeLabel: "Collection",
                isActive: activeCollectionIDs.contains(collection.id),
                payload: .skillCollection(id: collection.id, name: collection.name, body: body)
            )
        }
        let skills = (collectionItems + individualSkillItems)
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        // Prompts
        let promptRecords: [PromptTemplateRecord]
        if let path = scopedPath {
            promptRecords = promptTemplateCatalog(forProjectPath: path)
        } else {
            promptRecords = globalSnapshot.promptTemplates
        }
        let activePromptNames = activeParentPromptTemplateNames(forProjectPath: scopedPath, useSelectedProjectFallback: false)
            .union(runtimePromptNames)
        let disabledBundledPromptNames = appSettings.disabledBundledPromptNames
        var seenPromptName = Set<String>()
        let prompts = promptRecords
            .filter { !($0.source.kind == .builtin && disabledBundledPromptNames.contains($0.name)) }
            .filter { seenPromptName.insert($0.name).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { record in
                SlashItem(
                    id: "prompt:\(record.id)",
                    kind: .prompt,
                    displayName: record.name,
                    description: record.description.isEmpty ? nil : record.description,
                    scopeLabel: record.source.displayName,
                    isActive: activePromptNames.contains(record.name),
                    payload: .prompt(name: record.name, body: record.body, filePath: record.filePath, recordID: record.id)
                )
            }

        // Commands — Deck Command Library (when project-scoped) + Pi runtime
        // extension `registerCommand` entries from `get_commands`.
        var knownCommandSlash = Set<String>()
        var commands: [SlashItem] = []
        if projectFeatureSlashEnabled {
            for command in PiInjectedCommandCatalog.all
                .filter({ PiInjectedCommandCatalog.isEnabled($0, settings: appSettings) })
                .sorted(by: { $0.slashName.localizedStandardCompare($1.slashName) == .orderedAscending }) {
                knownCommandSlash.insert(command.slashName.lowercased())
                let bare = command.slashName.hasPrefix("/")
                    ? String(command.slashName.dropFirst()).lowercased()
                    : command.slashName.lowercased()
                knownCommandSlash.insert(bare)
                commands.append(
                    SlashItem(
                        id: "command:\(command.id)",
                        kind: .command,
                        displayName: command.title,
                        description: command.description.isEmpty ? nil : command.description,
                        scopeLabel: command.source == .builtIn ? "Built-in" : "Library",
                        isActive: true,
                        payload: .command(slashName: command.slashName, commandID: command.id)
                    )
                )
            }
        }
        for cmd in runtimeExtensionCommands.sorted(by: {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }) {
            let slashName = cmd.invocation
            let bare = cmd.bareName.lowercased()
            if knownCommandSlash.contains(slashName.lowercased()) || knownCommandSlash.contains(bare) {
                continue
            }
            knownCommandSlash.insert(slashName.lowercased())
            knownCommandSlash.insert(bare)
            commands.append(
                SlashItem(
                    id: "runtime-command:\(cmd.bareName)",
                    kind: .command,
                    displayName: cmd.bareName,
                    description: cmd.description,
                    scopeLabel: "Extension",
                    isActive: true,
                    payload: .command(slashName: slashName, commandID: "runtime:\(cmd.bareName)")
                )
            )
        }

        let createLoop = SlashItem(
            id: "loop:create-new",
            kind: .loop,
            displayName: "Create New Loop…",
            description: "Configure and launch an unsaved loop for this transcript.",
            scopeLabel: "Unsaved",
            isActive: true,
            payload: .loopCreateNew
        )
        let savedLoops = loopDefinitions
            .filter { $0.isAvailable(in: scopedPath) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { definition in
                SlashItem(
                    id: "loop:\(definition.id)",
                    kind: .loop,
                    displayName: definition.name,
                    description: definition.description.isEmpty ? nil : definition.description,
                    scopeLabel: definition.source.displayName,
                    isActive: true,
                    payload: .loopDefinition(definition)
                )
            }
        let loops = projectFeatureSlashEnabled ? [createLoop] + savedLoops : []

        return SlashUniverse(skills: skills, prompts: prompts, commands: commands, loops: loops)
    }


}
