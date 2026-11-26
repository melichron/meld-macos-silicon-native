// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI

struct ComparisonView: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Две папки…") { model.choose(true) }.keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Два файла…") { model.choose(false) }.keyboardShortcut("o")
                if !model.roots.isEmpty {
                    Button { model.open(model.roots, folders: true) } label: { Image(systemName: "arrow.clockwise") }
                        .help("Обновить сравнение папок")
                }
            }
            .disabled(model.busy)
            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            Divider()
            Group {
                if !model.roots.isEmpty { Folders(model: model) }
                else if model.docs.count == 2 { comparison }
                else {
                    VStack(spacing: 12) {
                        Image(systemName: "folder.badge.gearshape").font(.largeTitle)
                        Text(model.roots.isEmpty ? "Открой две папки или два файла" : "Выбери файл из списка")
                    }.foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if model.busy {
                Divider()
                HStack { ProgressView().controlSize(.small); Text("Сравнение…"); Spacer() }.padding(6)
            }
        }
        .alert("MeldMac", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK") { model.message = nil }
        } message: { Text(model.message ?? "") }
    }

    var comparison: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                HStack {
                    Picker("Вид", selection: $model.editing) {
                        Text("Редактор").tag(true)
                        Text("По блокам").tag(false)
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                    let changes = model.changes
                    Menu("Блоки (\(changes.count))") {
                        ForEach(Array(changes.enumerated()), id: \.element.id) { i, change in
                            Button("Блок \(i + 1) · строка \(change.left.lowerBound + 1)") { model.jump(to: i); proxy.scrollTo("\(change.id)/0", anchor: .top) }
                        }
                    }.fixedSize().disabled(changes.isEmpty || !model.currentDiff)
                    if model.editing, let band = model.selectedChange {
                        Text("\(model.activeBlock + 1)/\(changes.count)").font(.caption)
                        Button("←") { model.transfer(band, to: 0) }.help("Перенести выбранный блок влево")
                        Button("→") { model.transfer(band, to: 1) }.help("Перенести выбранный блок вправо")
                    }
                    if !model.currentDiff { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Отменить") { if let last = model.history.last { model.update(last, undo: true) } }
                        .disabled(model.history.isEmpty)
                    Button("Сохранить") { model.save() }.disabled(!model.dirty)
                }.padding(8)
                HStack(spacing: 56) {
                    ForEach(0..<2) { i in
                        Text(model.docs[i].url.path).font(.caption).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading).help(model.docs[i].url.path)
                    }
                }.padding(8)
                Divider()
                if model.editing {
                    HStack(spacing: 0) {
                        FileEditor(model: model, side: 0)
                        Divider()
                        FileEditor(model: model, side: 1)
                    }
                } else if model.currentDiff {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.rows) { row in
                                HStack(alignment: .top, spacing: 0) {
                                    line(0, row)
                                    HStack(spacing: 2) {
                                        if row.band.changed && row.offset == 0 {
                                            Button("←") { model.transfer(row.band, to: 0) }.help("Заменить блок слева версией справа")
                                            Button("→") { model.transfer(row.band, to: 1) }.help("Заменить блок справа версией слева")
                                        }
                                    }.controlSize(.small).frame(width: 62)
                                    line(1, row)
                                }.padding(.vertical, 2)
                                .background(row.band.changed ? (row.band.left.isEmpty || row.band.right.isEmpty ? Color.green : Color.blue).opacity(0.22) : Color.clear)
                            }
                        }
                    }
                } else { Spacer() }
            }.disabled(model.busy)
        }
    }

    func line(_ side: Int, _ row: DisplayRow) -> some View {
        let range = side == 0 ? row.band.left : row.band.right
        let marks = (side == 0 ? row.band.leftMarks : row.band.rightMarks)[row.offset] ?? []
        let offset = row.offset
        let idx = range.lowerBound + offset
        let valid = idx < range.upperBound
        return HStack(alignment: .top, spacing: 6) {
            Text(valid ? String(idx + 1) : "").foregroundStyle(.secondary).frame(width: 45, alignment: .trailing)
            highlightedLine(valid ? model.docs[side].lines[idx] : "", spans: marks).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 12, design: .monospaced)).frame(maxWidth: .infinity)
    }
}

// The matcher counts Unicode scalars. Highlight a complete visible character
// even when only one of its combining marks or emoji components changed.
private func highlightedLine(_ line: String, spans: [InlineSpan]) -> Text {
    guard !spans.isEmpty else { return Text(verbatim: line) }
    var result = AttributedString()
    var run = line.startIndex
    var highlighted = false
    var scalar = 0
    var span = 0
    func appendRun(to end: String.Index) {
        guard run < end else { return }
        var part = AttributedString(String(line[run..<end]))
        if highlighted {
            part.backgroundColor = .orange.opacity(0.60)
            part.inlinePresentationIntent = .stronglyEmphasized
        }
        result.append(part)
    }
    for index in line.indices {
        while span < spans.count && spans[span].end <= scalar { span += 1 }
        let next = scalar + line[index].unicodeScalars.count
        let changed = span < spans.count && spans[span].start < next
        if changed != highlighted {
            appendRun(to: index)
            run = index
            highlighted = changed
        }
        scalar = next
    }
    appendRun(to: line.endIndex)
    return Text(result)
}

@MainActor final class Delegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    var models: [NSWindow: Model] = [:]
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Завершить MeldMac", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let mainItem = NSMenuItem()
        mainItem.submenu = appMenu
        menu.addItem(mainItem)
        let file = NSMenu(title: "Файл")
        file.addItem(withTitle: "Сохранить изменения", action: #selector(saveComparison), keyEquivalent: "s").target = self
        let fileItem = NSMenuItem()
        fileItem.submenu = file
        menu.addItem(fileItem)
        let edit = NSMenu(title: "Правка")
        edit.addItem(withTitle: "Отменить правку", action: #selector(undoComparison), keyEquivalent: "z").target = self
        edit.addItem(.separator())
        for (title, selector, key) in [("Вырезать", "cut:", "x"), ("Скопировать", "copy:", "c"), ("Вставить", "paste:", "v"), ("Выбрать всё", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
        }
        let editItem = NSMenuItem()
        editItem.submenu = edit
        menu.addItem(editItem)
        NSApp.mainMenu = menu
        let paths = Array(CommandLine.arguments.dropFirst())
        let urls = paths.count == 2 ? paths.map { URL(fileURLWithPath: $0) } : []
        present(urls, folders: urls.first.flatMap { try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory } == true, parent: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func present(_ urls: [URL], folders: Bool, parent: NSWindow?) {
        if !urls.isEmpty, let existing = models.first(where: { _, model in
            folders ? model.roots == urls : model.docs.map(\.url) == urls
        }) {
            existing.key.makeKeyAndOrderFront(nil)
            return
        }
        let model = Model()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1150, height: 740), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = urls.isEmpty ? "MeldMac" : urls.map(\.lastPathComponent).joined(separator: " ↔ ")
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "MeldMac"
        window.isReleasedWhenClosed = false
        models[window] = model
        model.newComparison = { [weak self, weak window, weak model] urls, folders in
            guard let self, let window, let model else { return }
            if model.docs.isEmpty && model.roots.isEmpty && !model.busy {
                window.title = urls.map(\.lastPathComponent).joined(separator: " ↔ ")
                model.open(urls, folders: folders)
            } else {
                self.present(urls, folders: folders, parent: window)
            }
        }
        model.didSave = { [weak self] in
            for m in self?.models.values.filter({ !$0.roots.isEmpty }) ?? [] { m.open(m.roots, folders: true) }
        }
        window.minSize = NSSize(width: 780, height: 420)
        window.contentView = NSHostingView(rootView: ComparisonView(model: model))
        window.delegate = self
        window.center()
        if let parent { parent.addTabbedWindow(window, ordered: .above) }
        window.makeKeyAndOrderFront(nil)
        if urls.count == 2 { model.open(urls, folders: folders) }
    }
    private var currentModel: Model? { NSApp.keyWindow.flatMap { models[$0] } }

    @objc func saveComparison() { currentModel?.save() }

    @objc func undoComparison() {
        if let model = currentModel, let previous = model.history.last { model.update(previous, undo: true) }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(saveComparison): return currentModel?.dirty == true
        case #selector(undoComparison): return currentModel?.history.isEmpty == false
        default: return true
        }
    }

    func confirmClose() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Закрыть без сохранения изменений?"
        alert.addButton(withTitle: "Продолжить сравнение")
        alert.addButton(withTitle: "Закрыть без сохранения")
        return alert.runModal() == .alertSecondButtonReturn
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        models[sender]?.dirty != true || confirmClose()
    }
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow { models.removeValue(forKey: window) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        (!models.values.contains(where: { $0.dirty }) || confirmClose()) ? .terminateNow : .terminateCancel
    }
}

@main struct MeldMac {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = Delegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}
