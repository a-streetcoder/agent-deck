import AppKit
import Foundation
import SwiftUI

/// A single sRGB color stored as plain components so it can be persisted in the
/// `AppSettings` JSON and round-tripped through SwiftUI's `ColorPicker`.
struct ThemeColor: Codable, Hashable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Convenience for preset literals expressed in 0–255 component space.
    init(_ red255: Int, _ green255: Int, _ blue255: Int) {
        self.red = Double(red255) / 255
        self.green = Double(green255) / 255
        self.blue = Double(blue255) / 255
    }

    /// Normalizes whatever color space `ColorPicker` hands back into sRGB so the
    /// stored components stay comparable and stable across edits.
    init(color: Color) {
        let srgbWhite = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? srgbWhite
        self.red = Double(resolved.redComponent)
        self.green = Double(resolved.greenComponent)
        self.blue = Double(resolved.blueComponent)
    }

    enum CodingKeys: String, CodingKey {
        case red, green, blue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        red = try container.decodeIfPresent(Double.self, forKey: .red) ?? 0
        green = try container.decodeIfPresent(Double.self, forKey: .green) ?? 0
        blue = try container.decodeIfPresent(Double.self, forKey: .blue) ?? 0
    }

    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }

    /// `#RRGGBB` — used to feed the WKWebView markdown CSS.
    var hexString: String {
        func channel(_ value: Double) -> Int { min(max(Int((value * 255).rounded()), 0), 255) }
        return String(format: "#%02X%02X%02X", channel(red), channel(green), channel(blue))
    }

    /// Linear mix toward `other`. `amount` 0 keeps self, 1 becomes `other`.
    func mixed(with other: ThemeColor, amount: Double) -> ThemeColor {
        let t = min(max(amount, 0), 1)
        return ThemeColor(
            red: red + (other.red - red) * t,
            green: green + (other.green - green) * t,
            blue: blue + (other.blue - blue) * t
        )
    }

    func lightened(by amount: Double) -> ThemeColor {
        mixed(with: ThemeColor(255, 255, 255), amount: amount)
    }

    func darkened(by amount: Double) -> ThemeColor {
        mixed(with: ThemeColor(0, 0, 0), amount: amount)
    }
}

/// A user-selectable color theme. Only the curated tokens below are stored —
/// gradient/derived shades are computed from `accent` (see `ThemeManager`) so a
/// custom theme always stays internally consistent.
struct Theme: Codable, Hashable, Identifiable {
    var id: UUID
    var name: String
    /// Built-in presets are read-only; custom themes can be edited and deleted.
    var isBuiltIn: Bool
    var accent: ThemeColor      // brand accent — buttons, selection, links
    var assistant: ThemeColor   // assistant / user message bubbles
    var thinking: ThemeColor    // thinking bubbles
    var tool: ThemeColor        // tool-call bubbles
    var error: ThemeColor       // error bubbles + removed diff lines
    var stderr: ThemeColor      // stderr bubbles
    var diffAdded: ThemeColor   // added diff lines

    init(
        id: UUID = UUID(),
        name: String,
        isBuiltIn: Bool,
        accent: ThemeColor,
        assistant: ThemeColor,
        thinking: ThemeColor,
        tool: ThemeColor,
        error: ThemeColor,
        stderr: ThemeColor,
        diffAdded: ThemeColor
    ) {
        self.id = id
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.accent = accent
        self.assistant = assistant
        self.thinking = thinking
        self.tool = tool
        self.error = error
        self.stderr = stderr
        self.diffAdded = diffAdded
    }

    enum CodingKeys: String, CodingKey {
        case id, name, isBuiltIn, accent, assistant, thinking, tool, error, stderr, diffAdded
    }

    /// Per-field decode-if-present so a custom theme stored by an older build
    /// stays valid if tokens are added later.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Theme.defaultTheme
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Custom"
        isBuiltIn = try container.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
        accent = try container.decodeIfPresent(ThemeColor.self, forKey: .accent) ?? fallback.accent
        assistant = try container.decodeIfPresent(ThemeColor.self, forKey: .assistant) ?? fallback.assistant
        thinking = try container.decodeIfPresent(ThemeColor.self, forKey: .thinking) ?? fallback.thinking
        tool = try container.decodeIfPresent(ThemeColor.self, forKey: .tool) ?? fallback.tool
        error = try container.decodeIfPresent(ThemeColor.self, forKey: .error) ?? fallback.error
        stderr = try container.decodeIfPresent(ThemeColor.self, forKey: .stderr) ?? fallback.stderr
        diffAdded = try container.decodeIfPresent(ThemeColor.self, forKey: .diffAdded) ?? fallback.diffAdded
    }
}

extension Theme {
    /// The exact dark-mode palette the app shipped with before themes existed —
    /// see `AppTheme` in `DesignSystem.swift`. UUIDs of built-in themes are fixed
    /// literals so a stored selection stays valid across app updates.
    static let defaultTheme = Theme(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        name: "Default",
        isBuiltIn: true,
        accent: ThemeColor(100, 210, 255),
        assistant: ThemeColor(186, 110, 238),
        thinking: ThemeColor(140, 151, 232),
        tool: ThemeColor(221, 168, 78),
        error: ThemeColor(229, 116, 108),
        stderr: ThemeColor(224, 138, 178),
        diffAdded: ThemeColor(86, 201, 138)
    )

    static let ember = Theme(
        id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        name: "Ember",
        isBuiltIn: true,
        accent: ThemeColor(255, 138, 76),
        assistant: ThemeColor(245, 130, 90),
        thinking: ThemeColor(230, 165, 95),
        tool: ThemeColor(225, 175, 80),
        error: ThemeColor(232, 92, 88),
        stderr: ThemeColor(230, 128, 150),
        diffAdded: ThemeColor(120, 198, 128)
    )

    static let forest = Theme(
        id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
        name: "Forest",
        isBuiltIn: true,
        accent: ThemeColor(96, 200, 140),
        assistant: ThemeColor(120, 200, 150),
        thinking: ThemeColor(128, 188, 170),
        tool: ThemeColor(210, 180, 100),
        error: ThemeColor(228, 116, 108),
        stderr: ThemeColor(216, 140, 165),
        diffAdded: ThemeColor(96, 205, 130)
    )

    static let violet = Theme(
        id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
        name: "Violet",
        isBuiltIn: true,
        accent: ThemeColor(180, 130, 245),
        assistant: ThemeColor(190, 120, 240),
        thinking: ThemeColor(150, 140, 235),
        tool: ThemeColor(220, 165, 95),
        error: ThemeColor(230, 110, 120),
        stderr: ThemeColor(225, 135, 185),
        diffAdded: ThemeColor(110, 200, 150)
    )

    static let monoSlate = Theme(
        id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
        name: "Mono Slate",
        isBuiltIn: true,
        accent: ThemeColor(140, 160, 185),
        assistant: ThemeColor(150, 165, 190),
        thinking: ThemeColor(135, 150, 180),
        tool: ThemeColor(180, 165, 140),
        error: ThemeColor(200, 130, 130),
        stderr: ThemeColor(190, 145, 165),
        diffAdded: ThemeColor(140, 180, 150)
    )

    /// Default first — the rest are presented as presets in Settings.
    static let builtInThemes: [Theme] = [defaultTheme, ember, forest, violet, monoSlate]

    // Gradient/depth shades derived from the accent. Tuned so the Default
    // accent's shades land close to the hand-picked values the app shipped
    // with, while staying sensible for any custom accent.
    var accentBright: ThemeColor { accent.lightened(by: 0.30) }
    var accentDeep: ThemeColor { accent.darkened(by: 0.33) }
    var accentShadow: ThemeColor { accent.darkened(by: 0.72) }

    /// Accent + role colors in display order — used for compact swatch strips.
    var previewSwatches: [ThemeColor] { [accent, assistant, thinking, tool, error, diffAdded] }
}
