// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import AppKit

private func ribbon(width: CGFloat, left: ClosedRange<CGFloat>, right: ClosedRange<CGFloat>) -> CGPath {
    let path = CGMutablePath()
    let mid = width / 2
    path.move(to: CGPoint(x: 0, y: left.lowerBound))
    path.addCurve(to: CGPoint(x: width, y: right.lowerBound),
                  control1: CGPoint(x: mid, y: left.lowerBound), control2: CGPoint(x: mid, y: right.lowerBound))
    path.addLine(to: CGPoint(x: width, y: right.upperBound))
    path.addCurve(to: CGPoint(x: 0, y: left.upperBound),
                  control1: CGPoint(x: mid, y: right.upperBound), control2: CGPoint(x: mid, y: left.upperBound))
    path.closeSubpath()
    return path
}

@MainActor final class EditorLinks: ObservableObject {
    weak var left: FileEditor.Coordinator?
    weak var right: FileEditor.Coordinator?
    weak var gutter: GutterView?
}

struct EditorGutter: NSViewRepresentable {
    @ObservedObject var model: Model
    let links: EditorLinks
    func makeNSView(context: Context) -> GutterView {
        let view = GutterView()
        view.links = links
        links.gutter = view
        return view
    }
    func updateNSView(_ view: GutterView, context: Context) {
        view.needsDisplay = true
    }
}

@MainActor final class GutterView: NSView {
    weak var links: EditorLinks?
    override var isFlipped: Bool { true }

    private func endpoints(_ editor: FileEditor.Coordinator) -> (visible: NSRange, y: (Int) -> CGFloat)? {
        guard let text = editor.textView, let layout = text.layoutManager, let container = text.textContainer,
              editor.paintedRevision == editor.model.revision, !editor.starts.isEmpty else { return nil }
        let origin = text.textContainerOrigin
        let visible = text.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let count = editor.starts.count - 1
        let length = editor.starts[count]
        return (chars, { row in
            let offset = editor.starts[row]
            let line: CGRect
            if offset == length && layout.extraLineFragmentTextContainer != nil {
                line = layout.extraLineFragmentRect
            } else if length > 0 {
                let glyph = layout.glyphIndexForCharacter(at: min(offset, length - 1))
                line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            } else {
                line = CGRect(x: 0, y: 0, width: 1, height: layout.defaultLineHeight(for: text.font!))
            }
            let y = row == count ? line.maxY : line.minY
            return self.convert(NSPoint(x: 0, y: origin.y + y), from: text).y
        })
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let left = links?.left, let right = links?.right, left.model.currentDiff,
              let ly = endpoints(left), let ry = endpoints(right),
              let ctx = NSGraphicsContext.current?.cgContext else { return }
        for band in left.model.bands where band.changed {
            if left.starts[band.left.upperBound] < ly.visible.location &&
                right.starts[band.right.upperBound] < ry.visible.location { continue }
            if left.starts[band.left.lowerBound] > NSMaxRange(ly.visible) &&
                right.starts[band.right.lowerBound] > NSMaxRange(ry.visible) { continue }
            let a = ly.y(band.left.lowerBound), b = ly.y(band.left.upperBound)
            let c = ry.y(band.right.lowerBound), d = ry.y(band.right.upperBound)
            guard max(b, d) >= dirtyRect.minY, min(a, c) <= dirtyRect.maxY else { continue }
            let color: NSColor = band.left.isEmpty || band.right.isEmpty ? .systemGreen : .systemBlue
            ctx.setFillColor(color.withAlphaComponent(0.24).cgColor)
            ctx.setStrokeColor(color.withAlphaComponent(0.72).cgColor)
            ctx.addPath(ribbon(width: bounds.width, left: a...max(a,b), right: c...max(c,d)))
            ctx.drawPath(using: .fillStroke)
        }
    }
}

struct BlockAnchor {
    let row: DisplayRow
    let bounds: Anchor<CGRect>
}
struct BlockAnchors: PreferenceKey {
    static var defaultValue: [BlockAnchor] { [] }
    static func reduce(value: inout [BlockAnchor], nextValue: () -> [BlockAnchor]) {
        value.append(contentsOf: nextValue())
    }
}

struct AlignedGutter: View {
    let anchors: [BlockAnchor]
    var body: some View {
        GeometryReader { geometry in
            Canvas { ctx, size in
                for group in Dictionary(grouping: anchors, by: { $0.row.band.id }).values {
                    guard let first = group.first else { continue }
                    let band = first.row.band
                    let top = geometry[first.bounds].minY
                    func end(_ count: Int) -> CGFloat {
                        if count <= first.row.offset { return top }
                        let index = min(count - 1 - first.row.offset, group.count - 1)
                        return geometry[group[index].bounds].maxY
                    }
                    let shape = Path(ribbon(width: 62, left: top...max(top,end(band.left.count)),
                                            right: top...max(top,end(band.right.count))))
                        .offsetBy(dx: (size.width - 62) / 2, dy: 0)
                    let color: Color = band.left.isEmpty || band.right.isEmpty ? .green : .blue
                    ctx.fill(shape, with: .color(color.opacity(0.30)))
                    ctx.stroke(shape, with: .color(color.opacity(0.75)))
                }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
