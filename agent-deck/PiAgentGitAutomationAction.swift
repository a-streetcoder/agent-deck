import Foundation

enum PiAgentGitAutomationAction: String, Hashable {
    case commit
    case push
    case commitAndPush
    case merge
}
