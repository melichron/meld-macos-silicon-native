// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI

struct RecentComparison: Codable, Hashable, Identifiable {
    let left: String
    let right: String
    let folders: Bool
    var id: Self { self }
    var urls: [URL] { [left, right].map { URL(fileURLWithPath: $0, isDirectory: folders) } }
}

enum Theme: String, CaseIterable {
    case system = "Системная", light = "Светлая", dark = "Тёмная"

    @MainActor func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor final class Preferences: ObservableObject {
    private let defaults: UserDefaults
    @Published private(set) var recent: [RecentComparison]
    @Published var theme: Theme {
        didSet {
            defaults.set(theme.rawValue, forKey: "theme")
            theme.apply()
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        recent = defaults.data(forKey: "recentComparisons").flatMap {
            try? JSONDecoder().decode([RecentComparison].self, from: $0)
        } ?? []
        theme = defaults.string(forKey: "theme").flatMap(Theme.init(rawValue:)) ?? .system
    }

    func record(_ urls: [URL], folders: Bool) {
        let item = RecentComparison(left: urls[0].standardizedFileURL.path,
                                    right: urls[1].standardizedFileURL.path, folders: folders)
        recent = [item] + recent.filter { $0 != item }.prefix(19)
        defaults.set(try? JSONEncoder().encode(recent), forKey: "recentComparisons")
    }
}
