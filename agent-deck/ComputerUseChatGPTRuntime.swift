import AppKit
import Foundation

private final class ComputerUseLaunchCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resolve(_ value: Bool) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

@MainActor
enum ComputerUseChatGPTRuntime {
    static let bundleIdentifier = "com.openai.codex"
    static let applicationURL = URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true)

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    static func openAndWaitUntilRunning(timeout: Duration = .seconds(10)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        if !isRunning {
            let launched = await withCheckedContinuation { continuation in
                let gate = ComputerUseLaunchCompletionGate(continuation)
                Task {
                    try? await Task.sleep(for: timeout)
                    gate.resolve(false)
                }

                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { application, error in
                    gate.resolve(application != nil && error == nil)
                }
            }
            guard launched else {
                NSSound.beep()
                return false
            }
        } else {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first?
                .activate(options: [.activateAllWindows])
        }

        while clock.now < deadline {
            if isRunning { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        NSSound.beep()
        return false
    }
}
