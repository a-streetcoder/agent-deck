import Combine
import Foundation
import SwiftUI

// MARK: - App language

/// In-app UI language (menu / Settings switchable). English + 简体中文.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case chinese = "zh"

    var id: String { rawValue }

    /// Picker label (bilingual so both stay recognizable).
    var menuLabel: String {
        switch self {
        case .english: return "English"
        case .chinese: return "中文"
        }
    }

    /// Preferred Apple lproj name under the app bundle.
    var lprojCode: String {
        switch self {
        case .english: return "en"
        case .chinese: return "zh-Hans"
        }
    }

    /// Lookup candidates — Xcode may fold `zh-Hans` → `zh-hans` on disk.
    var lprojCandidates: [String] {
        switch self {
        case .english: return ["en"]
        case .chinese: return ["zh-Hans", "zh-hans", "zh_CN", "zh-CN", "zh"]
        }
    }

    /// Locale for `String(format:)`.
    var locale: Locale {
        switch self {
        case .english: return Locale(identifier: "en_US")
        case .chinese: return Locale(identifier: "zh_CN")
        }
    }

    /**
     Detect language from system preferred languages.

     - Returns: `.chinese` when primary preferred language is any Chinese variant; otherwise `.english`.
     */
    static func detectSystemLanguage() -> AppLanguage {
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
        if preferred.hasPrefix("zh") { return .chinese }
        return .english
    }

    /**
     Resolve language for app start.

     Order: persisted `UserDefaults` → system preferred languages.
     */
    static func resolvePreferred() -> AppLanguage {
        if let raw = UserDefaults.standard.string(forKey: LanguageStore.defaultsKey),
           let lang = AppLanguage(rawValue: raw)
        {
            return lang
        }
        return detectSystemLanguage()
    }
}

// MARK: - Language store

/// Observable language store. Views that read `language` re-render on switch.
@MainActor
final class LanguageStore: ObservableObject {
    static let shared = LanguageStore()

    /// UserDefaults key for persisted language.
    nonisolated static let defaultsKey = "pi.deck.appLanguage"

    @Published private(set) var language: AppLanguage

    /**
     Bootstrap language:

     - If key exists → use it.
     - Else → detect system language once and persist.
     */
    private init() {
        if let raw = UserDefaults.standard.string(forKey: Self.defaultsKey),
           let lang = AppLanguage(rawValue: raw)
        {
            language = lang
        } else {
            language = AppLanguage.detectSystemLanguage()
            UserDefaults.standard.set(language.rawValue, forKey: Self.defaultsKey)
        }
    }

    /**
     Switch UI language and persist.

     - Parameter language: Target language.
     */
    func setLanguage(_ language: AppLanguage) {
        guard self.language != language else { return }
        self.language = language
        UserDefaults.standard.set(language.rawValue, forKey: Self.defaultsKey)
    }

    /**
     Localized string for a `Localizable.strings` key.

     - Parameter key: Same key as in `en.lproj` / `zh-Hans.lproj`.
     - Returns: Translated text for the active language.
     */
    func t(_ key: String) -> String {
        L10n.string(key, language: language)
    }

    /**
     Localized format string with positional replacements (`%@`, `%d`, …).

     - Parameters:
       - key: Strings key.
       - args: Format arguments in order.
     */
    func t(_ key: String, _ args: CVarArg...) -> String {
        let format = L10n.string(key, language: language)
        return String(format: format, locale: language.locale, arguments: args)
    }

    /**
     Composer input placeholder for Pi Agent.

     - Parameters:
       - hasSelectedSession: Whether a session is selected.
       - isCompacting: Whether context compaction is running.
       - isRunning: Whether the agent turn is in progress.
       - isNoProject: Session has no project root.
     - Returns: Localized placeholder string.
     */
    func composerPlaceholder(
        hasSelectedSession: Bool,
        isCompacting: Bool,
        isRunning: Bool,
        isNoProject: Bool
    ) -> String {
        if !hasSelectedSession { return t("composer.placeholder.startSession") }
        if isCompacting { return t("composer.placeholder.compacting") }
        if isRunning { return t("composer.placeholder.steer") }
        if isNoProject { return t("composer.placeholder.noProject") }
        return t("composer.placeholder.withProject")
    }
}

// MARK: - Bundle lookup

/// Bundle-backed lookup for `Localizable.strings` (app target → `Bundle.main`).
///
/// **Add a string:** edit `en.lproj` + `zh-Hans.lproj`, then call `language.t("key")` in UI.
enum L10n {
    /**
     Resolve a localized string from `Localizable.strings`.

     - Parameters:
       - key: Key in the `.strings` file.
       - language: Active app language.
     - Returns: Localized text; falls back to English, then to the raw key.
     */
    static func string(_ key: String, language: AppLanguage) -> String {
        let value = localizedString(key, language: language)
        if value != key || language == .english {
            return value
        }
        return localizedString(key, language: .english)
    }

    /**
     Load the `*.lproj` bundle for in-app language switching.

     - Parameter language: Target language.
     - Returns: lproj `Bundle`, or `Bundle.main` if missing.
     */
    static func localizationBundle(for language: AppLanguage) -> Bundle {
        for code in language.lprojCandidates {
            if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
               let bundle = Bundle(path: path)
            {
                return bundle
            }
        }
        let wanted = Set(language.lprojCandidates.map { $0.lowercased() })
        for loc in Bundle.main.localizations where wanted.contains(loc.lowercased()) {
            if let path = Bundle.main.path(forResource: loc, ofType: "lproj"),
               let bundle = Bundle(path: path)
            {
                return bundle
            }
        }
        return .main
    }

    private static func localizedString(_ key: String, language: AppLanguage) -> String {
        let bundle = localizationBundle(for: language)
        return bundle.localizedString(forKey: key, value: nil, table: "Localizable")
    }
}

// MARK: - View helper

extension View {
    /// Observe language changes so chrome re-renders after switch.
    func observingLanguage(_ store: LanguageStore = .shared) -> some View {
        environmentObject(store)
    }
}
