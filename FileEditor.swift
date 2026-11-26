// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import AppKit

struct FileEditor: NSViewRepresentable {
    @ObservedObject var model: Model
    let side: Int

    let links: EditorLinks

    func makeCoordinator() -> Coordinator { Coordinator(model, side: side, links: links) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let text = NSTextView(frame: scroll.contentView.bounds)
        text.isRichText = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isContinuousSpellCheckingEnabled = false
        text.isAutomaticLinkDetectionEnabled = false
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textContainerInset = NSSize(width: 7, height: 7)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.setAccessibilityLabel(side == 0 ? "Левый редактор" : "Правый редактор")
        scroll.documentView = text
        text.delegate = context.coordinator
        context.coordinator.attach(text, scroll: scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView else { return }
        context.coordinator.refresh(text)
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        let model: Model
        let side: Int
        var contentRevision = -1
        var paintedRevision = -1
        var lastJump = 0
        var refreshing = false
        var starts: [Int] = []

        private var lastScrollY: CGFloat = 0
        weak var textView: NSTextView?
        let links: EditorLinks
        init(_ model: Model, side: Int, links: EditorLinks) {
            self.links = links
            self.model = model
            self.side = side
        }

        func attach(_ text: NSTextView, scroll: NSScrollView) {
            textView = text
            if side == 0 { links.left = self } else { links.right = self }
            let clip = scroll.contentView
            clip.postsBoundsChangedNotifications = true
            clip.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged(_:)),
                name: NSView.boundsDidChangeNotification, object: clip)
            NotificationCenter.default.addObserver(self, selector: #selector(redraw),
                name: NSView.frameDidChangeNotification, object: clip)
        }

        @objc private func boundsChanged(_ note: Notification) {
            redraw()
            guard let clip = note.object as? NSClipView, clip.bounds.minY != lastScrollY else { return }
            lastScrollY = clip.bounds.minY
            links.scrolled(self)
        }

        var readyForScroll: Bool {
            paintedRevision == model.revision && !starts.isEmpty &&
                starts.last == textView?.textStorage?.length && textView?.layoutManager != nil
        }

        // Use TextKit's laid-out line boundaries for both scrolling and ribbons.
        func lineY(_ row: Int) -> CGFloat {
            guard let text = textView, let layout = text.layoutManager,
                  let length = text.textStorage?.length else { return 0 }
            let offset = min(starts[row], length)
            let line: CGRect
            if offset == length && layout.extraLineFragmentTextContainer != nil {
                line = layout.extraLineFragmentRect
            } else if length > 0 {
                let glyph = layout.glyphIndexForCharacter(at: min(offset, length - 1))
                line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            } else {
                line = CGRect(x: 0, y: 0, width: 1, height: layout.defaultLineHeight(for: text.font!))
            }
            return text.textContainerOrigin.y + (row == starts.count - 1 ? line.maxY : line.minY)
        }

        func logicalPosition(at y: CGFloat) -> CGFloat {
            guard let text = textView, let layout = text.layoutManager,
                  let container = text.textContainer else { return 0 }
            let point = NSPoint(x: 0, y: y - text.textContainerOrigin.y)
            let index = layout.characterIndex(for: point, in: container,
                                              fractionOfDistanceBetweenInsertionPoints: nil)
            var lo = 0, hi = starts.count - 1
            while lo + 1 < hi {
                let mid = (lo + hi) / 2
                if starts[mid] <= index { lo = mid } else { hi = mid }
            }
            let top = lineY(lo)
            let progress = (y - top) / max(1, lineY(lo + 1) - top)
            return CGFloat(lo) + min(1, max(0, progress))
        }

        func documentY(at row: CGFloat) -> CGFloat {
            let index = min(Int(row), starts.count - 1)
            let top = lineY(index)
            guard index + 1 < starts.count else { return top }
            return top + (row - CGFloat(index)) * (lineY(index + 1) - top)
        }

        @objc private func redraw() { links.gutter?.needsDisplay = true }

        func textDidChange(_ notification: Notification) {
            guard !refreshing, let text = notification.object as? NSTextView else { return }
            let normalized = text.string.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            model.edit(normalized, side: side)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !refreshing, model.currentDiff, paintedRevision == model.revision,
                  let text = notification.object as? NSTextView, text.window?.firstResponder === text else { return }
            let caret = text.selectedRange().location
            for (index, band) in model.changes.enumerated() {
                let rows = side == 0 ? band.left : band.right
                if starts[rows.lowerBound] <= caret && (caret < starts[rows.upperBound] ||
                    (caret == starts[rows.upperBound] && (rows.isEmpty || rows.upperBound == starts.count - 1))) {
                    model.activeBlock = index
                    break
                }
            }
        }

        func refresh(_ text: NSTextView) {
            redraw()
            guard !text.hasMarkedText(), model.docs.indices.contains(side) else { return }
            refreshing = true
            defer { refreshing = false }
            let lines = model.docs[side].lines
            if contentRevision != model.revision {
                let value = lines.joined(separator: "\n")
                if !value.utf8.elementsEqual(text.string.utf8) {
                    let old = text.selectedRange()
                    text.string = value
                    let start = min(old.location, text.string.utf16.count)
                    text.setSelectedRange(NSRange(location: start, length: min(old.length, text.string.utf16.count - start)))
                }
                contentRevision = model.revision
            }
            guard model.currentDiff, let layout = text.layoutManager else { return }
            if paintedRevision != model.revision {
                starts = [0]
                for line in lines { starts.append(starts.last! + line.utf16.count + 1) }
                starts[lines.count] = text.string.utf16.count
                layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: starts.last!))
                for band in model.changes {
                    let rows = side == 0 ? band.left : band.right
                    let marks = side == 0 ? band.leftMarks : band.rightMarks
                    let color: NSColor = band.left.isEmpty || band.right.isEmpty ? .systemGreen : .systemBlue
                    let range = NSRange(location: starts[rows.lowerBound], length: starts[rows.upperBound] - starts[rows.lowerBound])
                    if range.length > 0 {
                        layout.addTemporaryAttribute(.backgroundColor, value: color.withAlphaComponent(0.22), forCharacterRange: range)
                    }
                    for (offset, spans) in marks {
                        let row = rows.lowerBound + offset
                        highlight(spans, line: lines[row], start: starts[row], layout: layout)
                    }
                }
                paintedRevision = model.revision
                if lastJump == model.jumpRequest { links.synchronize() }
            }
            if lastJump != model.jumpRequest, let band = model.selectedChange {
                lastJump = model.jumpRequest
                let row = side == 0 ? band.left.lowerBound : band.right.lowerBound
                text.scrollRangeToVisible(NSRange(location: starts[row], length: 0))
            }
        }

        private func highlight(_ spans: [InlineSpan], line: String, start: Int, layout: NSLayoutManager) {
            // Translate scalar offsets once and expand each mark to complete graphemes.
            let utf16 = line as NSString
            var offsets = [0]
            for scalar in line.unicodeScalars { offsets.append(offsets.last! + scalar.utf16.count) }
            for span in spans {
                let range = NSRange(location: offsets[span.start], length: offsets[span.end] - offsets[span.start])
                var visible = utf16.rangeOfComposedCharacterSequences(for: range)
                visible.location += start
                layout.addTemporaryAttribute(.backgroundColor, value: NSColor.systemOrange.withAlphaComponent(0.60), forCharacterRange: visible)
            }
        }
    }
}
