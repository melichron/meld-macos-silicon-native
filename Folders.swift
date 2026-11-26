// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

private func ancestors(_ path: String) -> [String] {
    var parents: [String] = []
    var current = ""
    for part in path.split(separator: "/").dropLast() {
        current = current.isEmpty ? String(part) : current + "/" + part
        parents.append(current)
    }
    return parents
}

struct Folders: View {
    @ObservedObject var model: Model
    @ObservedObject var preferences: Preferences
    private var visible: [Entry] {
        let matches = model.entries.filter {
            (model.showEqual || $0.status != "Совпадает") &&
                (model.search.isEmpty || $0.path.localizedCaseInsensitiveContains(model.search))
        }
        if model.search.isEmpty {
            return matches.filter { model.collapsed.isDisjoint(with: ancestors($0.path)) }
        }
        let paths = Set(matches.flatMap { [$0.path] + ancestors($0.path) })
        return model.entries.filter { paths.contains($0.path) }
    }

    func tint(_ entry: Entry) -> Color {
        switch entry.status {
        case "Только слева", "Только справа": return .green
        case "Изменён": return .blue
        case "Совпадает": return Color(nsColor: .secondaryLabelColor)
        default: return .red
        }
    }

    private func statusSymbol(_ entry: Entry) -> String {
        switch entry.status {
        case "Совпадает": return "equal.circle"
        case "Изменён": return "pencil"
        case "Только слева", "Только справа": return "plus"
        default: return "exclamationmark.triangle"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField(tr("Найти по пути"), text: $model.search).frame(maxWidth: 280)
                Toggle(tr("Включая совпадающие"), isOn: $model.showEqual)
                Toggle(tr("Показывать .git"), isOn: Binding(get: { model.includeGit }, set: model.showGit))
                Spacer()
            }.padding(10)
            HStack(spacing: 18) {
                Label(tr("Совпадает"), systemImage: "equal.circle").foregroundStyle(.secondary)
                Label(tr("Изменён"), systemImage: "pencil").foregroundStyle(.blue)
                Label(tr("Только с одной стороны"), systemImage: "plus").foregroundStyle(.green)
            }.font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.bottom, 8)
            HStack(spacing: 64) {
                ForEach(model.roots.indices, id: \.self) { side in
                    Label(model.roots[side].path, systemImage: "folder.fill")
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.font(.headline).padding(10).background(.bar)
            Divider()
            let list = visible
            if list.isEmpty {
                Text(model.search.isEmpty ? tr("В этом представлении нет файлов или папок") : tr("Совпадений по запросу нет"))
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(list) { entry in
                            HStack(spacing: 0) {
                                cell(entry, kind: entry.left)
                                HStack(spacing: 4) {
                                    Image(systemName: statusSymbol(entry))
                                        .foregroundStyle(tint(entry)).accessibilityLabel(tr(entry.status))
                                    if let side = entry.copySource {
                                        Button(side == 0 ? "→" : "←") { model.copyFile(entry) }
                                            .help(tr(side == 0 ? "Скопировать файл вправо" : "Скопировать файл влево") + ": " + entry.path)
                                    }
                                }.frame(width: 64)
                                cell(entry, kind: entry.right)
                            }.padding(.horizontal, 8).frame(minHeight: 31)
                            .background(entry.status == "Совпадает" ? Color.clear : tint(entry).opacity(0.14))
                            Divider()
                        }
                    }
                }
            }
        }.disabled(model.busy)
    }

    private func cell(_ entry: Entry, kind: String?) -> some View {
        let name = (entry.path as NSString).lastPathComponent
        return Button {
            if entry.directory {
                if !model.collapsed.insert(entry.path).inserted { model.collapsed.remove(entry.path) }
            } else if entry.editable {
                model.newComparison?(model.roots.map { $0.appendingPathComponent(entry.path) }, false)
            }
        } label: {
            HStack(spacing: 5) {
                if kind == "dir" {
                    Image(systemName: model.collapsed.contains(entry.path) && model.search.isEmpty ? "chevron.right" : "chevron.down")
                        .font(.caption2)
                }
                if let kind {
                    Image(systemName: kind == "dir" ? "folder" : kind == "link" ? "link" : "doc")
                    Text(name).lineLimit(1).truncationMode(.middle)
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }.foregroundStyle(tint(entry))
                .padding(.leading, CGFloat(min(ancestors(entry.path).count, 12) * 13))
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).help(entry.path + " · " + tr(entry.status))
    }
}
