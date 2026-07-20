import Foundation
import SwiftUI
import Combine
import ObjectiveC

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

// MARK: - Runtime Bundle override
// AppleLanguages alone often needs an app restart. Swizzling Bundle.main lets
// LocalizedStringKey / NSLocalizedString follow the in-app choice immediately.

private enum AppLanguageBundleOverride {
    static var code: String = "en"
    private static var didInstall = false

    static func installIfNeeded() {
        guard !didInstall else { return }
        didInstall = true
        object_setClass(Bundle.main, LanguageAwareBundle.self)
    }

    static func setCode(_ code: String) {
        installIfNeeded()
        self.code = code
    }
}

private final class LanguageAwareBundle: Bundle, @unchecked Sendable {
    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        let code = AppLanguageBundleOverride.code
        if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
           let langBundle = Bundle(path: path) {
            let translated = langBundle.localizedString(forKey: key, value: nil, table: tableName)
            // Only accept a real hit (not the key echoed back) when EN; for IT keys are Italian.
            if code == "en", translated != key {
                return translated
            }
            if code == "it" {
                return langBundle.localizedString(forKey: key, value: value, table: tableName)
            }
        }
        return super.localizedString(forKey: key, value: value, table: tableName)
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
            applyLanguage()
        }
    }

    var locale: Locale { preference.locale }
    var code: String { preference.localizationCode }
    var isEnglish: Bool { code == "en" }

    init() {
        // Default English for open-source / international installs; user can switch to Italiano.
        let raw = UserDefaults.standard.string(forKey: Self.defaultsKey) ?? AppLanguage.english.rawValue
        preference = AppLanguage(rawValue: raw) ?? .english
        applyLanguage()
    }

    /// Apply in-app language to Bundle + UserDefaults (no restart required).
    private func applyLanguage() {
        let code = preference.localizationCode
        AppLanguageBundleOverride.setCode(code)
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

    /// Italian source keys → localized string for the active language.
    func t(_ key: String) -> String {
        guard isEnglish else { return key }

        if let fromTable = Self.enTable[key], fromTable != key, !fromTable.isEmpty {
            return fromTable
        }
        if let path = Bundle.main.path(forResource: "en", ofType: "lproj"),
           let bundle = Bundle(path: path) {
            let v = bundle.localizedString(forKey: key, value: nil, table: nil)
            if v != key { return v }
        }
        // Missing EN entry: keep the Italian source key (honest fallback).
        return key
    }
}

/// Lookup helper for `String` contexts (alerts, non-SwiftUI). Italian source keys.
@MainActor
func L(_ key: String) -> String {
    AppLanguageStore.shared.t(key)
}

// MARK: - Settings UI

/// Dedicated Settings → Language tab content.
struct LanguageSettingsView: View {
    @EnvironmentObject private var language: AppLanguageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("IMPOSTAZIONI"))
                        .font(QS.Font.labelXS)
                        .foregroundStyle(QS.Color.outline)
                    Text(L("Lingua"))
                        .font(QS.Font.ui(16, weight: .semibold))
                        .foregroundStyle(QS.Color.onSurface)
                    Text(L("Lingua dell’interfaccia. Sistema segue macOS; scegli Italiano o English per forzarla."))
                        .font(QS.Font.ui(11))
                        .foregroundStyle(QS.Color.outline)
                        .frame(maxWidth: 560, alignment: .leading)
                }
                Spacer()
            }
            .padding(16)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    LanguageSettingsCard()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(QS.Color.backgroundDeep)
    }
}

struct LanguageSettingsCard: View {
    @EnvironmentObject private var language: AppLanguageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Lingua"))
                .font(QS.Font.ui(13, weight: .semibold))
                .foregroundStyle(QS.Color.onSurface)
            Text(L("Lingua dell’interfaccia. Sistema segue macOS; scegli Italiano o English per forzarla."))
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
