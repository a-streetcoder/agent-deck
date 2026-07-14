import XCTest
@testable import agent_deck

final class MCPBridgeCallResultEnvelopeTests: XCTestCase {
    func testEnvelopeEncodesOrderedMixedTextAndImageBlocks() throws {
        let image = Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()
        let result = MCPCallResult(content: [
            .init(type: "text", text: "before", data: nil, mimeType: nil),
            .init(type: "image", text: nil, data: image, mimeType: "image/png"),
            .init(type: "text", text: "after", data: nil, mimeType: nil)
        ], isError: true)

        let envelope = PiMCPBridgeCallResultEnvelope.callResult(result, server: "photos", tool: "inspect")
        XCTAssertEqual(envelope.version, PiMCPBridgeCallResultEnvelope.currentVersion)
        XCTAssertEqual(envelope.server, "photos")
        XCTAssertEqual(envelope.tool, "inspect")
        XCTAssertTrue(envelope.isError)
        XCTAssertEqual(envelope.content.map(\.type), ["text", "image", "text"])
        XCTAssertEqual(envelope.content[0].text, "before")
        XCTAssertEqual(envelope.content[1].data, image)
        XCTAssertEqual(envelope.content[1].mimeType, "image/png")
        XCTAssertEqual(envelope.content[2].text, "after")

        let decoded = try JSONDecoder().decode(PiMCPBridgeCallResultEnvelope.self, from: JSONEncoder().encode(envelope))
        XCTAssertEqual(decoded, envelope)
    }

    func testEnvelopeReplacesInvalidAndUnsupportedContentWithOrderedDiagnostics() {
        let tooLarge = Data(repeating: 0, count: PiMCPBridgeCallResultEnvelope.maximumImageDecodedBytes + 1).base64EncodedString()
        let result = MCPCallResult(content: [
            .init(type: "text", text: "kept", data: nil, mimeType: nil),
            .init(type: "image", text: nil, data: "not base64!", mimeType: "image/png"),
            .init(type: "resource", text: nil, data: nil, mimeType: nil),
            .init(type: "image", text: nil, data: "AA==", mimeType: "image/tiff"),
            .init(type: "image", text: nil, data: tooLarge, mimeType: "image/png"),
            .init(type: "audio", text: nil, data: nil, mimeType: nil),
            .init(type: "text", text: "tail", data: nil, mimeType: nil)
        ], isError: false)

        let envelope = PiMCPBridgeCallResultEnvelope.callResult(result, server: "server", tool: "tool")
        XCTAssertEqual(envelope.content.map(\.type), ["text", "text", "text", "text", "text", "text", "text"])
        XCTAssertEqual(envelope.content.compactMap(\.text), [
            "kept",
            "MCP image content omitted: invalid base64 data.",
            "MCP resource content omitted: resources are not supported by this bridge.",
            "MCP image content omitted: unsupported MIME type.",
            "MCP image content omitted: exceeds the \(PiMCPBridgeCallResultEnvelope.maximumImageDecodedBytes)-byte per-image limit.",
            "MCP content omitted: unsupported content type.",
            "tail"
        ])
    }

    func testEnvelopeBoundsBlockCountAndEncodedPayloadForHostileContent() throws {
        let hugeType = String(repeating: "x", count: 100_000)
        let hugeMIME = String(repeating: "y", count: 100_000)
        let blocks = (0..<1_000).map { index in
            MCPContentBlock(type: index.isMultiple(of: 2) ? hugeType : "resource", text: nil, data: nil, mimeType: hugeMIME)
        }

        let envelope = PiMCPBridgeCallResultEnvelope.callResult(.init(content: blocks, isError: false), server: hugeType, tool: hugeType)
        XCTAssertLessThanOrEqual(envelope.content.count, PiMCPBridgeCallResultEnvelope.maximumContentBlocks)
        XCTAssertEqual(envelope.content.last?.text, "MCP content omitted: result truncated.")
        XCTAssertTrue(envelope.content.allSatisfy { $0.text?.count ?? 0 < 200 })
        XCTAssertLessThanOrEqual(envelope.server.count, 256)
        XCTAssertLessThanOrEqual(envelope.tool.count, 256)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(envelope).count, PiMCPBridgeCallResultEnvelope.maximumEncodedEnvelopeBytes)
    }

    func testEnvelopeAppliesTextAndAggregateImageLimitsWithoutReorderingLaterBlocks() {
        let oversizedText = String(repeating: "a", count: PiMCPBridgeCallResultEnvelope.maximumTextBlockCharacters + 1)
        let image = Data(repeating: 1, count: PiMCPBridgeCallResultEnvelope.maximumImageDecodedBytes).base64EncodedString()
        let result = MCPCallResult(content: [
            .init(type: "text", text: oversizedText, data: nil, mimeType: nil),
            .init(type: "image", text: nil, data: image, mimeType: "image/jpeg"),
            .init(type: "image", text: nil, data: image, mimeType: "image/jpeg"),
            .init(type: "image", text: nil, data: image, mimeType: "image/jpeg"),
            .init(type: "text", text: "kept", data: nil, mimeType: nil)
        ], isError: false)

        let envelope = PiMCPBridgeCallResultEnvelope.callResult(result, server: "server", tool: "tool")
        XCTAssertEqual(envelope.content.map(\.type), ["text", "image", "image", "text", "text"])
        XCTAssertEqual(envelope.content[0].text, "MCP text content omitted: exceeds the \(PiMCPBridgeCallResultEnvelope.maximumTextBlockCharacters)-character per-block limit.")
        XCTAssertEqual(envelope.content[3].text, "MCP image content omitted: exceeds the \(PiMCPBridgeCallResultEnvelope.maximumAggregateImageDecodedBytes)-byte aggregate limit.")
        XCTAssertEqual(envelope.content[4].text, "kept")
    }
}
