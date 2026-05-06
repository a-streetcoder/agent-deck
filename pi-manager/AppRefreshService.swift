import Foundation

struct AppRefreshSnapshot: Sendable {
    let projectPreferencesByPath: [String: ProjectPreference]
    let discoveredProjects: [DiscoveredProject]
    let enabledProjects: [DiscoveredProject]
    let globalSnapshot: ScanSnapshot
    let projectSnapshots: [String: ScanSnapshot]
    let selectedProject: DiscoveredProject?
    let selectedProjectSnapshot: ScanSnapshot?
}

struct AppRefreshService: Sendable {
    func loadSnapshot(rootURL: URL, selectedProjectPath: String?, preferencesByPath: [String: ProjectPreference]) -> AppRefreshSnapshot {
        let discovery = ProjectDiscovery()
        let scanner = PiScanner()
        let discoveredProjects = discovery.discoverProjects(
            rootDirectoryURL: rootURL,
            additionalProjectPaths: Array(preferencesByPath.keys),
            preferencesByPath: preferencesByPath
        )
        let enabledProjects = discoveredProjects.filter { project in
            preferencesByPath[project.path]?.isEnabled ?? true
        }
        let globalSnapshot = scanner.scan(projectRoot: nil)
        let projectSnapshots = Dictionary(uniqueKeysWithValues: enabledProjects.map { project in
            (project.path, scanner.scan(projectRoot: project.url))
        })
        let selectedProject = selectedProjectPath.flatMap { path in
            discoveredProjects.first { project in
                project.path == path && (preferencesByPath[project.path]?.isEnabled ?? true)
            }
        }
        let selectedProjectSnapshot = selectedProject.flatMap { projectSnapshots[$0.path] }

        return AppRefreshSnapshot(
            projectPreferencesByPath: preferencesByPath,
            discoveredProjects: discoveredProjects,
            enabledProjects: enabledProjects,
            globalSnapshot: globalSnapshot,
            projectSnapshots: projectSnapshots,
            selectedProject: selectedProject,
            selectedProjectSnapshot: selectedProjectSnapshot
        )
    }
}
