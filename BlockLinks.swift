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
    private weak var driver: FileEditor.Coordinator?
    private var syncing = false

    func scrolled(_ source: FileEditor.Coordinator) {
        guard !syncing, !source.refreshing else { return }
        driver = source
        synchronize()
    }

    func synchronize() {
        guard !syncing, let source = driver,
              let target = source.side == 0 ? right : left,
              source.model.currentDiff, source.readyForScroll, target.readyForScroll,
              let from = source.textView?.enclosingScrollView?.contentView,
              let to = target.textView?.enclosingScrollView?.contentView else { return }
        syncing = true
        defer { syncing = false }
        let travel = from.documentRect.height - from.bounds.height
        guard travel > 0 else { return }
        let y = min(max(0, from.bounds.minY), travel)
        // Track the middle of the viewport, moving the anchor to its edges
        // near the start and end so both panes can reach their limits.
        let edge = min(from.bounds.height / 2, travel / 2)
        guard edge > 0 else { return }
        let fraction = 0.5 * (min(y / edge, 1) + max(0, 1 - (travel - y) / edge))
        let destination: CGFloat
        if y == 0 {
            destination = 0
        } else if y == travel {
            destination = to.documentRect.maxY - to.bounds.height
        } else {
            let row = source.logicalPosition(at: y + fraction * from.bounds.height)
            guard let mapped = map(row, bands: source.model.bands, side: source.side) else { return }
            destination = target.documentY(at: mapped) - fraction * to.bounds.height
        }
        var bounds = to.bounds
        bounds.origin.y = destination
        let point = to.constrainBoundsRect(bounds).origin
        if abs(point.y - to.bounds.minY) >= 0.5 {
            to.scroll(to: point)
            target.textView?.enclosingScrollView?.reflectScrolledClipView(to)
        }
    }

    private func map(_ row: CGFloat, bands: [Band], side: Int) -> CGFloat? {
        var lo = 0, hi = bands.count
        while lo < hi {
            let mid = (lo + hi) / 2
            let range = side == 0 ? bands[mid].left : bands[mid].right
            if CGFloat(range.upperBound) <= row { lo = mid + 1 } else { hi = mid }
        }
        guard lo < bands.count else {
            return bands.last.map { CGFloat(side == 0 ? $0.right.upperBound : $0.left.upperBound) }
        }
        let src = side == 0 ? bands[lo].left : bands[lo].right
        let dst = side == 0 ? bands[lo].right : bands[lo].left
        return CGFloat(dst.lowerBound) + (row - CGFloat(src.lowerBound)) * CGFloat(dst.count) / CGFloat(src.count)
    }
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
        return (chars, { row in
            self.convert(NSPoint(x: 0, y: editor.lineY(row)), from: text).y
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
