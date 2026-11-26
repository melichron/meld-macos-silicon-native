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
    private struct Attempt {
        let id = UUID()
        let item: RecentComparison
        var succeeded: Bool?
        var removed = false
    }
    private var pending: [Attempt] = []
    private var recordedThisLaunch = false
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

    func removeRecent(_ item: RecentComparison) {
        for index in pending.indices where pending[index].item == item {
            pending[index].removed = true
        }
        saveRecent(recent.filter { $0 != item })
    }

    func clearRecent() {
        for index in pending.indices { pending[index].removed = true }
        saveRecent([])
    }

    private func saveRecent(_ items: [RecentComparison]) {
        recent = items
        defaults.set(try? JSONEncoder().encode(items), forKey: "recentComparisons")
    }

    func beginComparison(_ urls: [URL], folders: Bool) -> (Bool) -> Void {
        guard !recordedThisLaunch else { return { _ in } }
        let item = RecentComparison(left: urls[0].standardizedFileURL.path,
                                    right: urls[1].standardizedFileURL.path, folders: folders)
        let attempt = Attempt(item: item)
        pending.append(attempt)
        return { [weak self] success in self?.finish(attempt.id, success: success) }
    }

    private func finish(_ id: UUID, success: Bool) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        pending[index].succeeded = success
        // A later, faster file comparison can finish before a folder scan.
        while let first = pending.first, let success = first.succeeded {
            pending.removeFirst()
            if success {
                recordedThisLaunch = true
                pending.removeAll()
                if !first.removed { saveRecent([first.item] + recent.filter { $0 != first.item }.prefix(19)) }
                return
            }
        }
    }
}
