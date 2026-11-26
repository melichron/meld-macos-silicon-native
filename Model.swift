// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI

struct Problem: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct Entry: Codable, Identifiable {
    let path: String
    let status: String
    let editable: Bool
    let left: String?
    let right: String?
    var directory: Bool { left == "dir" || right == "dir" }
    var copySource: Int? {
        if left == "file" && right == nil { return 0 }
        if right == "file" && left == nil { return 1 }
        return nil
    }
    var id: String { path }
}

struct Document {
    let url: URL
    var original: Data
    let separator: String
    let bom: Bool
    var lines: [String]

    init(_ url: URL) throws {
        self.url = url
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) <= 4_000_000 else {
            throw Problem("Для просмотра нужен обычный текстовый файл до 4 МБ.")
        }
        original = try Data(contentsOf: url)
        bom = original.starts(with: [0xef, 0xbb, 0xbf])
        guard let text = String(data: original.dropFirst(bom ? 3 : 0), encoding: .utf8),
              !text.utf8.contains(0) else { throw Problem("Файл не является текстом UTF-8.") }
        let stripped = text.replacingOccurrences(of: "\r\n", with: "")
        let crlf = stripped.utf8.count != text.utf8.count
        guard [crlf, stripped.contains("\r"), stripped.contains("\n")].filter({ $0 }).count <= 1
        else { throw Problem("Просмотр файлов со смешанными окончаниями строк пока не поддерживается.") }
        separator = crlf ? "\r\n" : stripped.contains("\r") ? "\r" : "\n"
        lines = text.components(separatedBy: separator)
    }

    var bytes: Data {
        var result = bom ? Data([0xef, 0xbb, 0xbf]) : Data()
        result.append(contentsOf: lines.joined(separator: separator).utf8)
        return result
    }
    mutating func save() throws {
        guard try Data(contentsOf: url) == original else {
            throw Problem("Файл изменился на диске. Сохранение остановлено: " + url.path)
        }
        let data = bytes
        try data.write(to: url, options: .atomic)
        original = data
    }
}

func engine<T: Decodable>(_ operation: String, _ input: Data) throws -> T {
    guard let script = Bundle.main.url(forResource: "engine", withExtension: "py") else {
        throw Problem("Не найден модуль сравнения.")
    }
    let task = Process(), stdin = Pipe(), stdout = Pipe()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    task.arguments = ["-E", "-s", "-B", script.path, operation]
    task.standardInput = stdin
    task.standardOutput = stdout
    try task.run()
    try stdin.fileHandleForWriting.write(contentsOf: input)
    try stdin.fileHandleForWriting.close()
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard task.terminationStatus == 0 else { throw Problem("Ошибка сравнения. Проверь доступ к файлам и наличие Python 3 из Command Line Tools.") }
    return try JSONDecoder().decode(T.self, from: data)
}

struct Band: Identifiable {
    let id: Int
    let left: Range<Int>
    let right: Range<Int>
    let changed: Bool
}
struct DisplayRow: Identifiable {
    let band: Band
    let offset: Int
    var id: String { "\(band.id)/\(offset)" }
}
func compare(_ docs: [Document]) throws -> [Band] {
    let changes: [[Int]] = try engine("diff", JSONEncoder().encode(docs.map(\.lines)))
    var result: [Band] = []
    var a = 0, b = 0
    func append(_ endA: Int, _ endB: Int, _ changed: Bool) {
        if a < endA || b < endB {
            result.append(Band(id: result.count, left: a..<endA, right: b..<endB, changed: changed))
        }
        a = endA
        b = endB
    }
    for c in changes {
        append(c[0], c[2], false)
        append(c[1], c[3], true)
    }
    append(docs[0].lines.count, docs[1].lines.count, false)
    return result
}

@MainActor final class Model: ObservableObject {
    @Published var docs: [Document] = []
    @Published var bands: [Band] = [] {
        didSet {
            rows = bands.flatMap { band in
                (0..<max(band.left.count, band.right.count)).map { DisplayRow(band: band, offset: $0) }
            }
        }
    }
    var rows: [DisplayRow] = []
    @Published var entries: [Entry] = []
    @Published var roots: [URL] = []
    @Published var showEqual = false
    @Published var search = ""
    @Published var busy = false
    @Published var message: String?
    @Published var dirty = false
    @Published var history: [[Document]] = []

    @Published var collapsed = Set<String>()
    var newComparison: (([URL], Bool) -> Void)?
    var didSave: (() -> Void)?

    func copyFile(_ entry: Entry) {
        guard let side = entry.copySource, roots.count == 2 else { return }
        let paths = roots
        work { [self] in
            var failure: Error?
            do {
                try await Task.detached {
                    try copyMissing(entry.path, from: paths[side], to: paths[1-side])
                }.value
            } catch { failure = error }
            entries = try await Task.detached {
                try engine("folders", JSONEncoder().encode(paths.map(\.path))) as [Entry]
            }.value
            if let failure { throw Problem(entry.path + " — " + failure.localizedDescription) }
        }
    }

    func work(_ operation: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            defer { self.busy = false }
            do { try await operation() } catch { message = error.localizedDescription }
        }
    }

    func open(_ urls: [URL], folders: Bool, fromList: Bool = false) {
        guard !dirty, urls.count == 2 else { return }
        work { [self] in
            if folders {
                let rows: [Entry] = try await Task.detached {
                    try engine("folders", JSONEncoder().encode(urls.map(\.path)))
                }.value
                entries = rows
                roots = urls
                docs = []
                bands = []
            } else {
                let (files, diff) = try await Task.detached {
                    let files = try urls.map { try Document($0) }
                    return (files, try compare(files))
                }.value
                docs = files
                bands = diff
                if !fromList { roots = []; entries = [] }
            }
            history = []
        }
    }

    func update(_ files: [Document], undo: Bool) {
        work { [self] in
            let diff = try await Task.detached { try compare(files) }.value
            if undo { history.removeLast() } else { history.append(docs) }
            docs = files
            bands = diff
            dirty = files.contains { $0.bytes != $0.original }
        }
    }

    func transfer(_ band: Band, to dest: Int) {
        var files = docs
        let src = 1 - dest
        let ranges = [band.left, band.right]
        files[dest].lines.replaceSubrange(ranges[dest], with: docs[src].lines[ranges[src]])
        if files[dest].lines.isEmpty { files[dest].lines = [""] }
        update(files, undo: false)
    }

    func save() {
        do {
            for i in docs.indices where docs[i].bytes != docs[i].original {
                try docs[i].save()
                history = []
            }
            dirty = false
            didSave?()
        } catch { message = error.localizedDescription }
    }
    func choose(_ folders: Bool) {
        var urls: [URL] = []
        for side in ["слева", "справа"] {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = folders
            panel.canChooseFiles = !folders
            panel.message = "Выбери " + (folders ? "папку " : "файл ") + side
            guard panel.runModal() == .OK, let url = panel.url else { return }
            urls.append(url)
        }
        if let newComparison { newComparison(urls, folders) } else { open(urls, folders: folders) }
    }
}
