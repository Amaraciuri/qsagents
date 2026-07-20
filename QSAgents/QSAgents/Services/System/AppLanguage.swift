import Foundation
import SwiftUI
import Combine

/// User-facing language preference for QS Agents (independent of macOS system language).
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case italian
    case english

    var id: String { rawValue }

    var menuTitleIT: String {
        switch self {
        case .system: return "Sistema"
        case .italian: return "Italiano"
        case .english: return "English"
        }
    }

    var menuTitleEN: String {
        switch self {
        case .system: return "System"
        case .italian: return "Italiano"
        case .english: return "English"
        }
    }

    /// Locale used for SwiftUI `LocalizedStringKey` lookup.
    var locale: Locale {
        switch self {
        case .system:
            return Locale.autoupdatingCurrent
        case .italian:
            return Locale(identifier: "it")
        case .english:
            return Locale(identifier: "en")
        }
    }

    var localizationCode: String {
        switch self {
        case .system:
            let code = Locale.autoupdatingCurrent.language.languageCode?.identifier ?? "en"
            return (code == "it") ? "it" : "en"
        case .italian: return "it"
        case .english: return "en"
        }
    }
}

@MainActor
final class AppLanguageStore: ObservableObject {
    static let shared = AppLanguageStore()
    private static let defaultsKey = "qs.language.preference"

    /// Italian → English table loaded from `Resources/L10nEn.json` (runtime fallback).
    private static let enTable: [String: String] = {
        guard
            let url = Bundle.main.url(forResource: "L10nEn", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return dict
    }()

    @Published var preference: AppLanguage {
        didSet {
            UserDefaults.standard.set(preference.rawValue, forKey: Self.defaultsKey)
            applyAppleLanguages()
        }
    }

    var locale: Locale { preference.locale }
    var code: String { preference.localizationCode }
    var isEnglish: Bool { code == "en" }

    init() {
        // Default English for open-source / international installs; user can switch to Italiano.
        let raw = UserDefaults.standard.string(forKey: Self.defaultsKey) ?? AppLanguage.english.rawValue
        preference = AppLanguage(rawValue: raw) ?? .english
        applyAppleLanguages()
    }

    /// Helps Foundation / Bundle lookups follow the in-app choice.
    private func applyAppleLanguages() {
        switch preference {
        case .system:
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        case .italian:
            UserDefaults.standard.set(["it"], forKey: "AppleLanguages")
        case .english:
            UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
        }
        UserDefaults.standard.synchronize()
    }

    func label(for lang: AppLanguage) -> String {
        isEnglish ? lang.menuTitleEN : lang.menuTitleIT
    }

    func t(_ key: String) -> String {
        if isEnglish {
            if let fromTable = Self.enTable[key] { return fromTable }
            if let path = Bundle.main.path(forResource: "en", ofType: "lproj"),
               let bundle = Bundle(path: path) {
                let v = NSLocalizedString(key, tableName: nil, bundle: bundle, value: key, comment: "")
                if v != key { return v }
            }
            return key
        }
        return key
    }
}

/// Lookup helper for `String` contexts (alerts, non-SwiftUI). Italian source keys.
@MainActor
func L(_ key: String) -> String {
    AppLanguageStore.shared.t(key)
}

// MARK: - Settings UI

struct LanguageSettingsCard: View {
    @EnvironmentObject private var language: AppLanguageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(language.isEnglish ? "Language" : "Lingua")
                .font(QS.Font.ui(13, weight: .semibold))
                .foregroundStyle(QS.Color.onSurface)
            Text(language.isEnglish
                 ? "UI language for QS Agents. System follows macOS; choose Italiano or English to force it."
                 : "Lingua dell’interfaccia. Sistema segue macOS; scegli Italiano o English per forzarla.")
                .font(QS.Font.ui(11))
                .foregroundStyle(QS.Color.onSurfaceVariant)
            Picker("", selection: $language.preference) {
                ForEach(AppLanguage.allCases) { lang in
                    Text(language.label(for: lang)).tag(lang)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(QS.Color.surfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
