import Foundation

enum PiRPCBridgeFixtures {
    static func bridgeEditor(id: String, name: String, payload: String) -> [String: Any] {
        [
            "type": "extension_ui_request",
            "id": id,
            "method": "editor",
            "title": "AGENT_DECK_BRIDGE \(name)",
            "prefill": payload
        ]
    }

    static func nestedBridgeEditor(id: String, name: String, payload: String) -> [String: Any] {
        [
            "type": "extension_ui_request",
            "data": [
                "id": id,
                "method": "editor",
                "title": "AGENT_DECK_BRIDGE \(name)",
                "prefill": payload
            ]
        ]
    }

    static func regularEditor(id: String, title: String = "Edit response", prefill: String = "Draft") -> [String: Any] {
        [
            "type": "extension_ui_request",
            "id": id,
            "method": "editor",
            "title": title,
            "prefill": prefill
        ]
    }

    static func nativeAsk(id: String, payload: String) -> [String: Any] {
        bridgeEditor(id: id, name: "ask_user", payload: payload)
    }

    static func childSupervisor(id: String, requestKind: String, title: String, message: String) -> [String: Any] {
        bridgeEditor(
            id: id,
            name: "contact_supervisor",
            payload: #"{"requestKind":"\#(requestKind)","title":"\#(title)","message":"\#(message)"}"#
        )
    }
}
