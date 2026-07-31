import Foundation

extension Notification.Name {
    static let piAgentNotificationResponse = Notification.Name("piAgentNotificationResponse")
    static let agentDeckImportSkillsRequested = Notification.Name("agentDeckImportSkillsRequested")
    static let agentDeckNewSkillRequested = Notification.Name("agentDeckNewSkillRequested")
    static let agentDeckManageSkillCollectionsRequested = Notification.Name("agentDeckManageSkillCollectionsRequested")
    static let agentDeckNewPromptRequested = Notification.Name("agentDeckNewPromptRequested")
    static let agentDeckImportPromptRequested = Notification.Name("agentDeckImportPromptRequested")
    static let agentDeckNewMemoryRequested = Notification.Name("agentDeckNewMemoryRequested")
    /// Posted from a transcript memory-recall card when the user taps an injected
    /// memory title. `userInfo["id"]` carries the memory record id to open.
    static let agentDeckOpenMemoryRequested = Notification.Name("agentDeckOpenMemoryRequested")
    /// Trailing Review column is about to animate; transcript should ease bubble
    /// widths immediately. `userInfo`: `width` (CGFloat), `duration` (TimeInterval).
    static let transcriptColumnWillAnimateWidth = Notification.Name("transcriptColumnWillAnimateWidth")
    /// Live Review splitter drag: main column width is changing every frame.
    /// `userInfo`: `width` (CGFloat) — target transcript/content column width.
    static let transcriptColumnLiveResizeWidth = Notification.Name("transcriptColumnLiveResizeWidth")
    /// Splitter drag (Review/sidebar) active state, for gating translucent/eased
    /// chrome that would smear into a blur mask mid-drag. `userInfo`: `["active": Bool]`.
    static let transcriptColumnResizeActive = Notification.Name("transcriptColumnResizeActive")
#if DEBUG
    static let sidebarExpandBenchAgentsScrollRequested = Notification.Name("AgentDeckSidebarExpandBenchAgentsScrollRequested")
    static let sidebarExpandBenchModelsScrollRequested = Notification.Name("AgentDeckSidebarExpandBenchModelsScrollRequested")
#endif
}
