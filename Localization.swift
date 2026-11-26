// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

enum AppLanguage: String, CaseIterable {
    case en, de, es, fr, ru, uk

    var name: String {
        switch self {
        case .en: return "English"
        case .de: return "Deutsch"
        case .es: return "Español"
        case .fr: return "Français"
        case .ru: return "Русский"
        case .uk: return "Українська"
        }
    }

    static var current: Self {
        if let saved = UserDefaults.standard.string(forKey: "interfaceLanguage"),
           let language = Self(rawValue: saved) { return language }
        let preferred = Bundle.preferredLocalizations(from: allCases.map(\.rawValue))
        return preferred.first.flatMap(Self.init(rawValue:)) ?? .en
    }

    private static let bundles: [Self: Bundle] = Dictionary(uniqueKeysWithValues: allCases.compactMap { language in
        guard let url = Bundle.main.url(forResource: language.rawValue, withExtension: "lproj"),
              let bundle = Bundle(url: url) else { return nil }
        return (language, bundle)
    })

    func text(_ key: String) -> String {
        Self.bundles[self]?.localizedString(forKey: key, value: key, table: nil) ?? key
    }
}

func tr(_ key: String) -> String { AppLanguage.current.text(key) }
