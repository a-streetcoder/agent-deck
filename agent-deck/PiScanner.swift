import Foundation

// `FileManager.default` is documented thread-safe and the other stored
// properties are immutable `Set<String>` values, so the scanner is safe to
// share across `concurrentPerform` workers. `FileManager` itself is marked
// non-Sendable in Foundation, hence the `@unchecked`.
nonisolated struct PiScanner: @unchecked Sendable {
    private let fileManager = FileManager.default
    private let externalSkillPaths: Set<String>
    private let externalPromptPaths: Set<String>
    private let skillCollectionNames: Set<String>

    init(externalSkillPaths: Set<String> = [], externalPromptPaths: Set<String> = [], skillCollectionNames: Set<String> = []) {
        self.externalSkillPaths = externalSkillPaths
        self.externalPromptPaths = externalPromptPaths
        self.skillCollectionNames = skillCollectionNames
    }

    func scan(projectRoot: URL?) -> ScanSnapshot {
        let globalAgentDirectory = homeDirectory().appendingPathComponent(".pi/agent/agents", isDirectory: true)
        let legacyGlobalAgentDirectory = homeDirectory().appendingPathComponent(".agents", isDirectory: true)
        let agentLibraryDirectory = homeDirectory().appendingPathComponent(".pi/agent/agent-library/agents", isDirectory: true)
        let globalSettings = homeDirectory().appendingPathComponent(".pi/agent/settings.json")
        let globalEnv = homeDirectory().appendingPathComponent(".pi/agent/.env")
        let globalSkills = homeDirectory().appendingPathComponent(".pi/agent/skills", isDirectory: true)
        let globalPrompts = homeDirectory().appendingPathComponent(".pi/agent/prompts", isDirectory: true)
        let libraryPrompts = homeDirectory().appendingPathComponent(".pi/agent/prompt-library", isDirectory: true)
        let extraGlobalSkills = homeDirectory().appendingPathComponent(".agents/skills", isDirectory: true)

        let projectSettings = projectRoot?.appendingPathComponent(".pi/settings.json")
        let projectEnv = projectRoot?.appendingPathComponent(".pi/.env")

        let builtinAgents = scanAgents(at: bundledAgentsDirectory(), scope: .builtin)
        let bundledSkills = scanSkills(at: bundledSkillsDirectory(), scope: .builtin)
        let legacyGlobalAgents = scanAgents(at: legacyGlobalAgentDirectory, scope: .global)
        let globalAgents = scanAgents(at: globalAgentDirectory, scope: .global)
        let projectAgents: [AgentRecord] = []
        let legacyProjectAgents: [AgentRecord] = []

        let settings = [
            scanSettings(at: globalSettings, scope: .global),
            // Preserve unrelated project settings for their own consumers, but
            // never import Pi's project-local subagent configuration.
            scanSettings(at: projectSettings, scope: .project, includesSubagentConfiguration: false)
        ].compactMap { $0 }

        let libraryAgents = scanAgents(at: agentLibraryDirectory, scope: .library)

        let packageSkillScan = scanPackageSkills(
            projectRoot: nil,
            globalSettings: settings.first(where: { $0.path == globalSettings.path }),
            projectSettings: nil
        )

        let skills = deduplicatedByCanonicalPath(
            bundledSkills +
            scanSkills(at: globalSkills, scope: .global) +
            scanSkills(at: extraGlobalSkills, scope: .global, allowRootMarkdown: false) +
            packageSkillScan.skills
        )
        let librarySkills = deduplicatedByCanonicalPath(scanExternalSkills(paths: externalSkillPaths))

        let envKeys =
            scanEnv(at: globalEnv, scope: .global) +
            scanEnv(at: projectEnv, scope: .project)

        let globalSettingsSummary = settings.first(where: { $0.path == globalSettings.path })
        let promptScan = scanPromptTemplates(
            projectRoot: nil,
            globalPromptsDirectory: globalPrompts,
            globalSettings: globalSettingsSummary,
            projectSettings: nil
        )
        let libraryPromptTemplates = dedupePromptTemplates(
            scanPromptTemplates(at: libraryPrompts, scope: .library, discoveryKind: .standardDirectory, packageName: nil)
                + scanExternalPrompts(paths: externalPromptPaths)
        )

        let effectiveAgents = resolveAgents(
            projectRoot: projectRoot?.path,
            builtin: builtinAgents,
            legacyGlobal: legacyGlobalAgents,
            global: globalAgents,
            legacyProject: legacyProjectAgents,
            project: projectAgents,
            userOverrides: globalSettingsSummary?.agentOverrides ?? [],
            userDisableBuiltins: globalSettingsSummary?.disableBuiltins
        )

        let warnings = buildWarnings(
            effectiveAgents: effectiveAgents,
            rawAgents: builtinAgents + legacyGlobalAgents + globalAgents + legacyProjectAgents + projectAgents,
            skills: skills + librarySkills,
            promptTemplates: promptScan.templates,
            envKeys: envKeys,
            malformedWarnings: malformedResourceWarnings(
                agentDirectories: [bundledAgentsDirectory(), legacyGlobalAgentDirectory, globalAgentDirectory, agentLibraryDirectory].compactMap { $0 },
                skillDirectories: [globalSkills, extraGlobalSkills].compactMap { $0 } + packageSkillScan.skillDirectories
            ) + packageSkillScan.warnings + promptScan.warnings
        )

        return ScanSnapshot(
            projectRoot: projectRoot?.path,
            builtinAgents: builtinAgents,
            globalAgents: legacyGlobalAgents + globalAgents,
            projectAgents: projectAgents,
            legacyProjectAgents: legacyProjectAgents,
            effectiveAgents: effectiveAgents,
            libraryAgents: libraryAgents,
            skills: skills,
            librarySkills: librarySkills,
            promptTemplates: promptScan.templates,
            libraryPromptTemplates: libraryPromptTemplates,
            settings: settings,
            envKeys: envKeys,
            warnings: warnings
        )
    }

    private func homeDirectory() -> URL {
        fileManager.homeDirectoryForCurrentUser
    }

    private func bundledAgentsDirectory() -> URL? {
        bundledResourceDirectory(named: "bundled-agents")
    }

    private func bundledSkillsDirectory() -> URL? {
        bundledResourceDirectory(named: "bundled-skills")
    }

    private func bundledPromptsDirectory() -> URL? {
        bundledResourceDirectory(named: "bundled-prompts")
    }

    private func bundledResourceDirectory(named name: String) -> URL? {
        let bundleURL = Bundle.main.resourceURL?.appendingPathComponent(name, isDirectory: true)
        if let bundleURL, fileManager.fileExists(atPath: bundleURL.path) { return bundleURL }

        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(name, isDirectory: true)
        if fileManager.fileExists(atPath: sourceURL.path) { return sourceURL }
        return nil
    }

    private func scanAgents(at directory: URL?, scope: ResourceScopeKind) -> [AgentRecord] {
        let urls = markdownFiles(in: directory)

        return urls
            .filter { url in
                url.pathExtension == "md" &&
                url.lastPathComponent != "SKILL.md" &&
                !url.pathComponents.contains("skills")
            }
            .compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let document = parseMarkdownDocument(text)
                let config = parseAgentConfig(frontmatter: document.frontmatter, body: document.body)
                guard !config.name.isEmpty, !config.description.isEmpty else { return nil }
                let name = config.name
                return AgentRecord(
                    id: "\(scope.rawValue):\(name):\(url.path)",
                    name: name,
                    description: config.description,
                    source: ScopeID(kind: scope, path: url.path),
                    filePath: url.path,
                    rawFrontmatter: document.frontmatter,
                    promptBody: document.body,
                    parsed: AgentConfig(name: name, description: config.description, whenToUse: config.whenToUse, model: config.model, fallbackModels: config.fallbackModels, thinking: config.thinking, systemPromptMode: config.systemPromptMode, inheritSkills: config.inheritSkills, disabled: config.disabled, tools: config.tools, mcpDirectTools: config.mcpDirectTools, mcpServers: config.mcpServers, extensions: config.extensions, skills: config.skills, output: config.output, defaultExpectedOutcome: config.defaultExpectedOutcome, defaultReads: config.defaultReads, defaultProgress: config.defaultProgress, interactive: config.interactive, maxSubagentDepth: config.maxSubagentDepth, systemPrompt: config.systemPrompt, unknownFields: config.unknownFields)
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func markdownFiles(in directory: URL?) -> [URL] {
        guard let directory, fileManager.fileExists(atPath: directory.path) else { return [] }
        let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        var urls: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "md" else { continue }
            urls.append(url)
        }
        return urls
    }

    /// Deduplicates a list of skill records by their canonical (symlink-resolved) file path.
    /// Without this, a symlink at `~/.pi/agent/skills/foo` pointing to `~/.agents/skills/foo`
    /// produces two `SkillRecord`s with the same content, which then surfaces as a
    /// "Duplicate skill name" diagnostic. Resolving to the canonical path collapses these
    /// to a single record while preserving scan order (first occurrence wins).
    /// Scans prompt template files referenced in place via `externalPromptPaths`.
    /// Each registered path is expected to be a single `.md` file that stays where
    /// the user keeps it; Agent Deck never copies it into the prompt library.
    private func scanExternalPrompts(paths: Set<String>) -> [PromptTemplateRecord] {
        var records: [PromptTemplateRecord] = []
        var seenPaths = Set<String>()

        for path in paths.sorted() {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  url.pathExtension == "md",
                  let record = scanPromptTemplateFile(at: url, scope: .library, discoveryKind: .externalReference, packageName: nil)
            else { continue }

            let standardizedPath = URL(fileURLWithPath: record.filePath).standardizedFileURL.path
            guard seenPaths.insert(standardizedPath).inserted else { continue }
            records.append(record)
        }

        return records.sorted { lhs, rhs in
            let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.filePath < rhs.filePath
        }
    }

    private func deduplicatedByCanonicalPath(_ skills: [SkillRecord]) -> [SkillRecord] {
        var seen: Set<String> = []
        var result: [SkillRecord] = []
        result.reserveCapacity(skills.count)
        for skill in skills {
            let canonical = URL(fileURLWithPath: skill.filePath).resolvingSymlinksInPath().path
            if seen.insert(canonical).inserted {
                result.append(skill)
            }
        }
        return result
    }

    private func scanSkills(at directory: URL?, scope: ResourceScopeKind, allowRootMarkdown: Bool = true) -> [SkillRecord] {
        guard let directory, let urls = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }

        return urls.compactMap { url in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }

            if isDirectory.boolValue {
                let skillFile = url.appendingPathComponent("SKILL.md")
                guard let text = try? String(contentsOf: skillFile, encoding: .utf8) else { return nil }
                let document = parseMarkdownDocument(text)
                let name = document.frontmatter["name"]?.nonEmpty ?? url.lastPathComponent
                let description = document.frontmatter["description"]?.nonEmpty
                return SkillRecord(
                    id: "\(scope.rawValue):\(name):\(skillFile.path)",
                    name: name,
                    description: description,
                    source: ScopeID(kind: scope, path: skillFile.path),
                    filePath: skillFile.path,
                    body: text
                )
            }

            guard allowRootMarkdown, url.pathExtension == "md", url.lastPathComponent != "SKILL.md" else { return nil }
            return scanStandaloneSkillFile(at: url, scope: scope)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func scanExternalSkills(paths: Set<String>) -> [SkillRecord] {
        var records: [SkillRecord] = []
        var seenSkillPaths = Set<String>()

        for path in paths.sorted() {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }

            let scannedRecords: [SkillRecord]
            if isDirectory.boolValue {
                let skillFile = url.appendingPathComponent("SKILL.md")
                if fileManager.fileExists(atPath: skillFile.path),
                   let skill = scanStandaloneSkillFile(at: skillFile, scope: .library) {
                    scannedRecords = [skill]
                } else {
                    scannedRecords = scanSkills(at: url, scope: .library)
                }
            } else if url.lastPathComponent == "SKILL.md",
                      let skill = scanStandaloneSkillFile(at: url, scope: .library) {
                scannedRecords = [skill]
            } else if url.pathExtension == "md",
                      let skill = scanStandaloneSkillFile(at: url, scope: .library) {
                scannedRecords = [skill]
            } else {
                scannedRecords = []
            }

            for record in scannedRecords {
                let standardizedPath = URL(fileURLWithPath: record.filePath).standardizedFileURL.path
                guard seenSkillPaths.insert(standardizedPath).inserted else { continue }
                records.append(record)
            }
        }

        return records.sorted { lhs, rhs in
            let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.filePath < rhs.filePath
        }
    }

    private func scanPackageSkills(
        projectRoot: URL?,
        globalSettings: SettingsSummary?,
        projectSettings: SettingsSummary?
    ) -> (skills: [SkillRecord], skillDirectories: [URL], warnings: [DiagnosticWarning]) {
        var skills: [SkillRecord] = []
        var skillDirectories: [URL] = []
        var warnings: [DiagnosticWarning] = []
        var seenSkillPaths = Set<String>()
        var seenDirectories = Set<String>()

        let packageRefs = [globalSettings?.packages ?? [], projectSettings?.packages ?? []].flatMap { $0 }
        for packageRef in packageRefs {
            guard let packageDirectory = resolvePackageDirectory(for: packageRef, projectRoot: projectRoot) else {
                continue
            }
            let packageName = SlashCommandCatalog.normalizePackageReference(packageRef)
            let packageSkillLocations = resolvePackageSkillLocations(packageDirectory: packageDirectory)
            if packageSkillLocations.isEmpty {
                continue
            }

            for url in packageSkillLocations {
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                    warnings.append(.init(id: "missing-package-skills:\(packageName):\(url.path)", message: "Package \(packageName) declares skills at \(url.path), but that path was not found."))
                    continue
                }

                if isDirectory.boolValue {
                    let standardizedPath = url.standardizedFileURL.path
                    if seenDirectories.insert(standardizedPath).inserted {
                        skillDirectories.append(url)
                    }

                    for skill in scanSkills(at: url, scope: .package) {
                        let skillPath = URL(fileURLWithPath: skill.filePath).standardizedFileURL.path
                        if seenSkillPaths.insert(skillPath).inserted {
                            skills.append(skill)
                        }
                    }
                } else if url.lastPathComponent == "SKILL.md",
                          let skill = scanStandaloneSkillFile(at: url, scope: .package),
                          seenSkillPaths.insert(URL(fileURLWithPath: skill.filePath).standardizedFileURL.path).inserted {
                    skills.append(skill)
                    let parentDirectory = url.deletingLastPathComponent()
                    let standardizedPath = parentDirectory.standardizedFileURL.path
                    if seenDirectories.insert(standardizedPath).inserted {
                        skillDirectories.append(parentDirectory)
                    }
                }
            }
        }

        return (
            skills.sorted { lhs, rhs in
                let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return lhs.filePath < rhs.filePath
            },
            skillDirectories,
            warnings
        )
    }

    private func scanStandaloneSkillFile(at file: URL, scope: ResourceScopeKind) -> SkillRecord? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let document = parseMarkdownDocument(text)
        let name = document.frontmatter["name"]?.nonEmpty ?? file.deletingLastPathComponent().lastPathComponent
        let description = document.frontmatter["description"]?.nonEmpty
        return SkillRecord(
            id: "\(scope.rawValue):\(name):\(file.path)",
            name: name,
            description: description,
            source: ScopeID(kind: scope, path: file.path),
            filePath: file.path,
            body: text
        )
    }

    private func scanPromptTemplates(
        projectRoot: URL?,
        globalPromptsDirectory: URL,
        globalSettings: SettingsSummary?,
        projectSettings: SettingsSummary?
    ) -> (templates: [PromptTemplateRecord], warnings: [DiagnosticWarning]) {
        var templates: [PromptTemplateRecord] = []
        var warnings: [DiagnosticWarning] = []

        if let bundledPromptsDirectory = bundledPromptsDirectory() {
            templates += scanPromptTemplates(at: bundledPromptsDirectory, scope: .builtin, discoveryKind: .standardDirectory, packageName: nil)
        }
        templates += scanPromptTemplates(at: globalPromptsDirectory, scope: .global, discoveryKind: .standardDirectory, packageName: nil)

        for (settings, scope) in [(globalSettings, ResourceScopeKind.global), (projectSettings, ResourceScopeKind.project)] {
            guard let settings else { continue }
            for path in settings.prompts {
                let url = URL(fileURLWithPath: path)
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                    warnings.append(.init(id: "missing-prompt-path:\(settings.path):\(path)", message: "Prompt path \(path) from \(settings.path) does not exist."))
                    continue
                }
                if isDirectory.boolValue {
                    templates += scanPromptTemplates(at: url, scope: scope, discoveryKind: .settings, packageName: nil)
                } else if url.pathExtension == "md" {
                    if let template = scanPromptTemplateFile(at: url, scope: scope, discoveryKind: .settings, packageName: nil) {
                        templates.append(template)
                    }
                }
            }
        }

        let packageRefs = [globalSettings?.packages ?? [], projectSettings?.packages ?? []].flatMap { $0 }
        for packageRef in packageRefs {
            guard let packageDirectory = resolvePackageDirectory(for: packageRef, projectRoot: projectRoot) else {
                continue
            }
            let packageName = SlashCommandCatalog.normalizePackageReference(packageRef)
            let packagePrompts = resolvePackagePromptLocations(packageDirectory: packageDirectory)
            if packagePrompts.isEmpty {
                continue
            }
            for url in packagePrompts {
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                    warnings.append(.init(id: "missing-package-prompts:\(packageName):\(url.path)", message: "Package \(packageName) declares prompt templates at \(url.path), but that path was not found."))
                    continue
                }
                if isDirectory.boolValue {
                    templates += scanPromptTemplates(at: url, scope: .package, discoveryKind: .package, packageName: packageName)
                } else if url.pathExtension == "md", let template = scanPromptTemplateFile(at: url, scope: .package, discoveryKind: .package, packageName: packageName) {
                    templates.append(template)
                }
            }
        }

        let dedupedTemplates = dedupePromptTemplates(templates)

        return (
            dedupedTemplates.sorted { lhs, rhs in
                let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return lhs.filePath < rhs.filePath
            },
            warnings
        )
    }

    private func scanPromptTemplates(at directory: URL, scope: ResourceScopeKind, discoveryKind: PromptTemplateDiscoveryKind, packageName: String?) -> [PromptTemplateRecord] {
        guard let urls = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }

        return urls
            .filter { $0.pathExtension == "md" }
            .compactMap { scanPromptTemplateFile(at: $0, scope: scope, discoveryKind: discoveryKind, packageName: packageName) }
    }

    private func scanPromptTemplateFile(at file: URL, scope: ResourceScopeKind, discoveryKind: PromptTemplateDiscoveryKind, packageName: String?) -> PromptTemplateRecord? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let document = parseMarkdownDocument(text)
        let description = document.frontmatter["description"]?.nonEmpty ?? firstNonEmptyLine(in: document.body) ?? "No description"
        return PromptTemplateRecord(
            id: "\(scope.rawValue):prompt:\(file.deletingPathExtension().lastPathComponent):\(file.path)",
            name: file.deletingPathExtension().lastPathComponent,
            description: description,
            argumentHint: document.frontmatter["argument-hint"]?.nonEmpty,
            source: ScopeID(kind: scope, path: file.path),
            filePath: file.path,
            body: text,
            discoveryKind: discoveryKind,
            packageName: packageName
        )
    }

    private func resolvePromptSettingEntries(_ rawValue: Any?, settingsFile: URL) -> [String] {
        let values: [String]
        if let value = rawValue as? String {
            values = [value]
        } else if let array = rawValue as? [Any] {
            values = array.compactMap { $0 as? String }
        } else {
            values = []
        }

        return values.compactMap { path in
            guard !path.isEmpty else { return nil }
            return resolveRelativePath(path, baseDirectory: settingsFile.deletingLastPathComponent()).path
        }
    }

    private func resolvePackagePromptLocations(packageDirectory: URL) -> [URL] {
        var results: [URL] = []
        let packageJSON = packageDirectory.appendingPathComponent("package.json")
        var hasDeclaredPrompts = false

        if let data = try? Data(contentsOf: packageJSON),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let pi = root["pi"] as? [String: Any] {
            let declaredPrompts: [String]
            if let value = pi["prompts"] as? String {
                declaredPrompts = [value]
            } else {
                declaredPrompts = (pi["prompts"] as? [Any])?.compactMap { $0 as? String } ?? []
            }

            hasDeclaredPrompts = !declaredPrompts.isEmpty
            for promptPath in declaredPrompts {
                results.append(resolveRelativePath(promptPath, baseDirectory: packageDirectory))
            }
        }

        if !hasDeclaredPrompts {
            let conventionalDirectory = packageDirectory.appendingPathComponent("prompts", isDirectory: true)
            if fileManager.fileExists(atPath: conventionalDirectory.path) {
                results.append(conventionalDirectory)
            }
        }

        var seen: Set<String> = []
        return results.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private func resolvePackageSkillLocations(packageDirectory: URL) -> [URL] {
        var results: [URL] = []
        let packageJSON = packageDirectory.appendingPathComponent("package.json")
        var hasDeclaredSkills = false

        if let data = try? Data(contentsOf: packageJSON),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let pi = root["pi"] as? [String: Any] {
            let declaredSkills: [String]
            if let value = pi["skills"] as? String {
                declaredSkills = [value]
            } else {
                declaredSkills = (pi["skills"] as? [Any])?.compactMap { $0 as? String } ?? []
            }

            hasDeclaredSkills = !declaredSkills.isEmpty
            for skillPath in declaredSkills {
                results.append(resolveRelativePath(skillPath, baseDirectory: packageDirectory))
            }
        }

        if !hasDeclaredSkills {
            let conventionalDirectory = packageDirectory.appendingPathComponent("skills", isDirectory: true)
            if fileManager.fileExists(atPath: conventionalDirectory.path) {
                results.append(conventionalDirectory)
            }
        }

        var seen: Set<String> = []
        return results.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private func resolvePackageDirectory(for packageReference: String, projectRoot: URL?) -> URL? {
        if packageReference.hasPrefix("/") {
            return URL(fileURLWithPath: packageReference, isDirectory: true)
        }
        if packageReference.hasPrefix(".") {
            return projectRoot?.appendingPathComponent(packageReference, isDirectory: true)
        }

        let packageName = SlashCommandCatalog.normalizePackageReference(packageReference)
        let candidates = [
            URL(fileURLWithPath: "/opt/homebrew/lib/node_modules/\(packageName)", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/lib/node_modules/\(packageName)", isDirectory: true),
            homeDirectory().appendingPathComponent(".npm-global/lib/node_modules/\(packageName)", isDirectory: true),
            homeDirectory().appendingPathComponent("node_modules/\(packageName)", isDirectory: true),
        ].compactMap { $0 }

        return candidates.first(where: { fileManager.fileExists(atPath: $0.path) })
    }

    private func resolveRelativePath(_ path: String, baseDirectory: URL) -> URL {
        let expanded = NSString(string: path).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
        }
        return baseDirectory.appendingPathComponent(expanded)
    }

    private func dedupePromptTemplates(_ templates: [PromptTemplateRecord]) -> [PromptTemplateRecord] {
        var seenPaths = Set<String>()
        var seenPackageNames = Set<String>()
        var deduped: [PromptTemplateRecord] = []

        for template in templates {
            let canonicalPath = URL(fileURLWithPath: template.filePath).standardizedFileURL.path
            if seenPaths.insert(canonicalPath).inserted {
                let packageScopedName = [template.packageName ?? "", template.name.lowercased()].joined(separator: "::")
                seenPackageNames.insert(packageScopedName)
                deduped.append(template)
                continue
            }

            let packageScopedName = [template.packageName ?? "", template.name.lowercased()].joined(separator: "::")
            if seenPackageNames.contains(packageScopedName) {
                continue
            }
        }

        return deduped
    }

    private func dedupePromptWarningRecords(_ records: [PromptTemplateRecord]) -> [PromptTemplateRecord] {
        var seenPaths = Set<String>()
        var deduped: [PromptTemplateRecord] = []

        for record in records {
            let canonicalPath = URL(fileURLWithPath: record.filePath).standardizedFileURL.path
            if seenPaths.insert(canonicalPath).inserted {
                deduped.append(record)
            }
        }

        return deduped
    }

    private func scanSettings(at file: URL?, scope: ResourceScopeKind, includesSubagentConfiguration: Bool = true) -> SettingsSummary? {
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return SettingsSummary(path: file.path, packages: [], prompts: [], disableBuiltins: nil, agentOverrides: [])
        }

        let packages = packageSources(from: root["packages"])
        let prompts = resolvePromptSettingEntries(root["prompts"], settingsFile: file)
        let subagents = includesSubagentConfiguration ? root["subagents"] as? [String: Any] : nil
        let disableBuiltins = subagents?["disableBuiltins"] as? Bool
        let overridesRoot = (subagents?["agentOverrides"] as? [String: Any]) ?? [:]
        let overrides: [BuiltinOverrideRecord] = overridesRoot.compactMap { name, payload in
            guard let payload = payload as? [String: Any] else { return nil }
            let values = payload.compactMapValues { JSONValue.fromFoundation($0) }
            return BuiltinOverrideRecord(
                agentName: name,
                scope: ScopeID(kind: .override, path: file.path),
                settingsPath: file.path,
                values: values
            )
        }
        .sorted { $0.agentName.localizedCaseInsensitiveCompare($1.agentName) == .orderedAscending }

        return SettingsSummary(path: file.path, packages: packages, prompts: prompts, disableBuiltins: disableBuiltins, agentOverrides: overrides)
    }

    private func packageSources(from value: Any?) -> [String] {
        guard let packages = value as? [Any] else { return [] }
        return packages.compactMap { package in
            if let source = package as? String { return source }
            return (package as? [String: Any])?["source"] as? String
        }
    }

    private func scanEnv(at file: URL?, scope: ResourceScopeKind) -> [EnvKeyRecord] {
        guard let file, let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text
            .split(whereSeparator: \.isNewline)
            .compactMap { rawLine -> EnvKeyRecord? in
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !line.hasPrefix("#") else {
                    return nil
                }
                let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let rawKey = parts.first else { return nil }
                let key = String(rawKey).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { return nil }
                let value = parts.count > 1 ? String(parts[1]) : nil
                return EnvKeyRecord(id: "\(scope.rawValue):\(key):\(file.path)", key: key, value: value, source: ScopeID(kind: scope, path: file.path))
            }
    }

    private func resolveAgents(
        projectRoot: String?,
        builtin: [AgentRecord],
        legacyGlobal: [AgentRecord],
        global: [AgentRecord],
        legacyProject: [AgentRecord],
        project: [AgentRecord],
        userOverrides: [BuiltinOverrideRecord],
        userDisableBuiltins: Bool?
    ) -> [EffectiveAgentRecord] {
        let allNames = Set(
            builtin.map(\.name) +
            legacyGlobal.map(\.name) +
            global.map(\.name) +
            legacyProject.map(\.name) +
            project.map(\.name) +
            userOverrides.map(\.agentName)
        )

        return allNames.sorted().compactMap { name in
            let builtinRecord = builtin.first(where: { $0.name == name })
            let globalRecord = legacyGlobal.first(where: { $0.name == name }) ?? global.first(where: { $0.name == name })
            let projectRecord = project.first(where: { $0.name == name }) ?? legacyProject.first(where: { $0.name == name })
            let userOverride = userOverrides.first(where: { $0.agentName == name })
            let projectOverride: BuiltinOverrideRecord? = nil

            let winner = projectRecord ?? globalRecord ?? builtinRecord
            guard var resolved = winner?.parsed else { return nil }
            if winner?.source.kind == .builtin {
                if let userOverride {
                    resolved = applyOverride(userOverride, to: resolved)
                } else if userDisableBuiltins == true {
                    resolved.disabled = true
                }
            }
            let resolutionKind: ResolutionKind
            if projectRecord != nil {
                resolutionKind = builtinRecord == nil ? .projectCustom : .projectReplacement
            } else if globalRecord != nil {
                resolutionKind = builtinRecord == nil ? .globalCustom : .globalReplacement
            } else if userOverride != nil || projectOverride != nil {
                resolutionKind = .builtinWithOverride
            } else {
                resolutionKind = .builtin
            }

            return EffectiveAgentRecord(
                id: "\(projectRoot ?? "global")::\(name)",
                name: name,
                projectRoot: projectRoot,
                builtin: builtinRecord,
                globalCustom: globalRecord,
                projectCustom: projectRecord,
                userOverride: userOverride,
                projectOverride: projectOverride,
                resolved: resolved,
                resolutionKind: resolutionKind
            )
        }
    }

    private func applyOverride(_ override: BuiltinOverrideRecord?, to config: AgentConfig, includeDisabled: Bool = true) -> AgentConfig {
        guard let override else { return config }
        var result = config

        for (key, rawValue) in override.values {
            switch key {
            case "whenToUse":
                if let value = rawValue.stringValue { result.whenToUse = value }
                else if rawValue.boolValue == false { result.whenToUse = nil }
            case "model":
                if let value = rawValue.stringValue { result.model = value }
                else if rawValue.boolValue == false { result.model = nil }
            case "thinking":
                if let value = rawValue.stringValue { result.thinking = value }
                else if rawValue.boolValue == false { result.thinking = "off" }
            case "systemPromptMode":
                if let value = rawValue.stringValue { result.systemPromptMode = value }
            case "inheritProjectContext", "defaultContext":
                continue
            case "inheritSkills":
                if let value = rawValue.boolValue { result.inheritSkills = value }
            case "disabled":
                if includeDisabled, let value = rawValue.boolValue { result.disabled = value }
            case "skills":
                if rawValue.boolValue == false { result.skills = [] }
                else if let values = splitJSONArray(rawValue) { result.skills = values }
            case "defaultExpectedOutcome":
                if let value = rawValue.stringValue { result.defaultExpectedOutcome = parseExpectedOutcome(value) }
                else if rawValue.boolValue == false { result.defaultExpectedOutcome = nil }
            case "tools":
                if rawValue.boolValue == false {
                    result.tools = nil
                    result.mcpDirectTools = nil
                } else if let values = splitJSONArray(rawValue) {
                    let parsedTools = splitToolList(values.joined(separator: ", "))
                    result.tools = parsedTools.tools
                    result.mcpDirectTools = parsedTools.mcpDirectTools
                }
            case "fallbackModels":
                if rawValue.boolValue == false { result.fallbackModels = [] }
                else if let values = splitJSONArray(rawValue) { result.fallbackModels = values }
            case "systemPrompt":
                if let value = rawValue.stringValue { result.systemPrompt = value }
            default:
                result.unknownFields[key] = stringify(rawValue)
            }
        }

        return result
    }

    private func buildWarnings(
        effectiveAgents: [EffectiveAgentRecord],
        rawAgents: [AgentRecord],
        skills: [SkillRecord],
        promptTemplates: [PromptTemplateRecord],
        envKeys: [EnvKeyRecord],
        malformedWarnings: [DiagnosticWarning]
    ) -> [DiagnosticWarning] {
        var warnings: [DiagnosticWarning] = malformedWarnings
        let skillNames = Set(skills.map(\.name)).union(skillCollectionNames)
        let exaConfigured = envKeys.contains {
            $0.key == "EXA_API_KEY" && ($0.value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        }
        let duplicatePromptNames = Dictionary(grouping: promptTemplates, by: \.name).compactMapValues { records in
            let uniqueRecords = dedupePromptWarningRecords(records)
            return uniqueRecords.count > 1 ? uniqueRecords : nil
        }

        for (name, records) in duplicatePromptNames {
            let locations = records
                .map { "\($0.source.kind.rawValue) · \(URL(fileURLWithPath: $0.filePath).standardizedFileURL.path)" }
                .sorted()
                .joined(separator: ", ")
            warnings.append(.init(id: "duplicate-prompt:\(name)", message: "Duplicate prompt template /\(name) exists across sources: \(locations)."))
        }

        for agent in effectiveAgents {
            for skill in agent.resolved.skills where !skillNames.contains(skill) {
                warnings.append(.init(id: "skill:\(agent.name):\(skill)", message: "Agent \(agent.name) references missing skill \(skill)."))
            }
            if let tools = agent.resolved.tools,
               tools.contains(where: { PiNativeSubagentBridgeExtensions.exaToolNames.contains($0.lowercased()) }),
               !exaConfigured {
                warnings.append(.init(id: "env:\(agent.name)", message: "Agent \(agent.name) uses bundled web tools but EXA_API_KEY was not found."))
            }
            if let tools = agent.resolved.tools,
               tools.contains(where: { $0.lowercased() == PiNativeSubagentBridgeExtensions.fallbackWebFetchToolName }),
               exaConfigured {
                warnings.append(.init(id: "env:\(agent.name):web-fetch", message: "Agent \(agent.name) uses web_fetch, but Exa is configured. Agent Deck exposes Exa web tools instead."))
            }
            if let extensions = agent.resolved.extensions, !extensions.isEmpty,
               ((agent.resolved.tools ?? []).isEmpty && (agent.resolved.mcpDirectTools ?? []).isEmpty) {
                warnings.append(.init(id: "extensions:\(agent.name)", message: "Agent \(agent.name) declares extensions but no explicit tools, so capabilities may not match expectations."))
            }
        }

        return warnings.sorted { $0.message.localizedCaseInsensitiveCompare($1.message) == .orderedAscending }
    }

    private func malformedResourceWarnings(agentDirectories: [URL], skillDirectories: [URL]) -> [DiagnosticWarning] {
        var warnings: [DiagnosticWarning] = []

        for directory in agentDirectories {
            guard let urls = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { continue }
            for url in urls where url.pathExtension == "md" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let document = parseMarkdownDocument(text)
                if !text.hasPrefix("---") {
                    warnings.append(.init(id: "malformed-agent:\(url.path)", message: "Malformed frontmatter in \(url.path). Markdown agent files should start with frontmatter."))
                    continue
                }
                if document.frontmatter["name"]?.isEmpty != false || document.frontmatter["description"]?.isEmpty != false {
                    warnings.append(.init(id: "incomplete-agent:\(url.path)", message: "Malformed frontmatter in \(url.path). Agent files need at least name and description."))
                }
            }
        }

        for directory in skillDirectories {
            guard let urls = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { continue }
            for folder in urls {
                let skillFile = folder.appendingPathComponent("SKILL.md")
                guard let text = try? String(contentsOf: skillFile, encoding: .utf8) else { continue }
                let document = parseMarkdownDocument(text)
                if !text.hasPrefix("---") || document.frontmatter["name"]?.isEmpty != false {
                    warnings.append(.init(id: "malformed-skill:\(skillFile.path)", message: "Malformed frontmatter in \(skillFile.path). Skills should define frontmatter with a name."))
                }
            }
        }

        return warnings
    }

    private func parseAgentConfig(frontmatter: [String: String], body: String) -> AgentConfig {
        var unknownFields = frontmatter

        func pop(_ key: String) -> String? {
            defer { unknownFields.removeValue(forKey: key) }
            return frontmatter[key]?.nonEmpty
        }

        let localName = pop("name") ?? ""
        let packageName = pop("package")
        let name = runtimeName(localName: localName, packageName: packageName)
        let rawTools = pop("tools")
        let skillValue = pop("skill") ?? pop("skills")
        let parsedMaxSubagentDepth = Int(pop("maxSubagentDepth") ?? "")
        _ = pop("inheritProjectContext")
        _ = pop("defaultContext")
        return AgentConfig(
            name: name,
            description: pop("description") ?? "",
            whenToUse: pop("whenToUse"),
            model: pop("model"),
            fallbackModels: splitList(pop("fallbackModels")),
            thinking: pop("thinking"),
            systemPromptMode: parseSystemPromptMode(pop("systemPromptMode"), name: name),
            inheritSkills: parseBool(pop("inheritSkills")) ?? false,
            disabled: parseBool(pop("disabled")),
            tools: frontmatter.keys.contains("tools") ? splitToolList(rawTools).tools : nil,
            mcpDirectTools: frontmatter.keys.contains("tools") ? splitToolList(rawTools).mcpDirectTools : nil,
            mcpServers: frontmatter.keys.contains("mcpServers") ? optionalList(pop("mcpServers")) : nil,
            extensions: frontmatter.keys.contains("extensions") ? splitList(pop("extensions")) : nil,
            skills: optionalList(skillValue) ?? [],
            output: pop("output"),
            defaultExpectedOutcome: parseExpectedOutcome(pop("defaultExpectedOutcome")),
            defaultReads: optionalList(pop("defaultReads")),
            defaultProgress: parseBool(pop("defaultProgress")) ?? false,
            interactive: parseBool(pop("interactive")) ?? false,
            maxSubagentDepth: parsedMaxSubagentDepth.flatMap { $0 >= 0 ? $0 : nil },
            systemPrompt: body,
            unknownFields: unknownFields
        )
    }

    private func parseExpectedOutcome(_ value: String?) -> PiSubagentExpectedOutcome? {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !normalized.isEmpty else { return nil }
        return PiSubagentExpectedOutcome.allCases.first { outcome in
            outcome.rawValue.lowercased() == normalized ||
            outcome.displayName.lowercased() == normalized ||
            outcome.displayName.replacingOccurrences(of: " ", with: "").lowercased() == normalized
        }
    }

    private func parseMarkdownDocument(_ text: String) -> (frontmatter: [String: String], body: String) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---") else {
            return ([:], normalized)
        }

        let startIndex = normalized.index(normalized.startIndex, offsetBy: 3)
        guard let range = normalized.range(of: "\n---", range: startIndex..<normalized.endIndex) else {
            return ([:], normalized)
        }

        let frontmatterBlock = String(normalized[normalized.index(after: startIndex)..<range.lowerBound])
        let bodyStart = normalized.index(range.lowerBound, offsetBy: 4)
        let body = String(normalized[bodyStart...]).trimmingCharacters(in: .whitespacesAndNewlines)

        let rawLines = frontmatterBlock.components(separatedBy: "\n")
        var frontmatter: [String: String] = [:]
        var i = 0
        while i < rawLines.count {
            let rawLine = rawLines[i]
            guard let separator = rawLine.firstIndex(of: ":") else {
                i += 1
                continue
            }
            let key = String(rawLine[..<separator]).trimmingCharacters(in: .whitespaces)
            var value = String(rawLine[rawLine.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            guard !key.isEmpty else { i += 1; continue }

            if SkillFrontmatter.isBlockScalarIndicator(value) {
                // Consume subsequent indented lines as the block-scalar value.
                i += 1
                let keyLineIndent = rawLine.prefix(while: { $0 == " " || $0 == "\t" }).count
                var blockLines: [String] = []
                while i < rawLines.count {
                    let nextRaw = rawLines[i]
                    let nextTrimmed = nextRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if nextTrimmed.isEmpty || nextTrimmed.hasPrefix("#") {
                        blockLines.append(nextTrimmed)
                        i += 1
                        continue
                    }
                    let nextIndent = nextRaw.prefix(while: { $0 == " " || $0 == "\t" }).count
                    if nextIndent > keyLineIndent {
                        blockLines.append(nextTrimmed)
                        i += 1
                    } else {
                        break
                    }
                }
                let joined: String
                if value.hasPrefix("|") {
                    joined = blockLines.joined(separator: "\n")
                } else {
                    joined = blockLines
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                }
                if !joined.isEmpty {
                    frontmatter[key] = joined
                }
            } else {
                frontmatter[key] = value
                i += 1
            }
        }
        return (frontmatter, body)
    }

    private func firstNonEmptyLine(in text: String) -> String? {
        text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    private func parseBool(_ value: String?) -> Bool? {
        guard let value else { return nil }
        switch value.lowercased() {
        case "true", "yes", "1": return true
        case "false", "no", "0": return false
        default: return nil
        }
    }

    private func parseSystemPromptMode(_ value: String?, name: String) -> String {
        switch value {
        case "append", "replace": return value ?? "replace"
        default: return defaultSystemPromptMode(name: name)
        }
    }

    private func defaultSystemPromptMode(name: String) -> String {
        name == "delegate" ? "append" : "replace"
    }

    private func defaultInheritProjectContext(name: String) -> Bool {
        name == "delegate"
    }

    private func runtimeName(localName: String, packageName: String?) -> String {
        let package = packageName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .components(separatedBy: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-").inverted)
            .joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        guard let package, !package.isEmpty else { return localName }
        return "\(package).\(localName)"
    }

    private func parseDefaultContext(_ value: String?) -> String? {
        switch value {
        case "fresh", "fork": return value
        default: return nil
        }
    }

    private func splitToolList(_ value: String?) -> (tools: [String]?, mcpDirectTools: [String]?) {
        let items = splitList(value)
        var tools: [String] = []
        var mcpDirectTools: [String] = []
        for item in items {
            if item.hasPrefix("mcp:") {
                let name = String(item.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { mcpDirectTools.append(name) }
            } else {
                tools.append(item)
            }
        }
        return (tools.isEmpty ? nil : tools, mcpDirectTools.isEmpty ? nil : mcpDirectTools)
    }

    private func optionalList(_ value: String?) -> [String]? {
        let values = splitList(value)
        return values.isEmpty ? nil : values
    }

    private func splitJSONArray(_ value: JSONValue) -> [String]? {
        guard case let .array(items) = value else { return nil }
        return items.compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private func splitList(_ value: String?) -> [String] {
        guard let value, !value.isEmpty else { return [] }
        return value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func stringify(_ value: JSONValue) -> String {
        value.compactDescription
    }
}
