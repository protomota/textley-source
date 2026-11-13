import AppKit

@MainActor
final class LineNumberRuler: NSRulerView {
    private weak var document: EditorDocument?

    init(scrollView: NSScrollView, document: EditorDocument) {
        self.document = document
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = document.editor
        ruleThickness = 54
        clipsToBounds = true
        NotificationCenter.default.addObserver(self, selector: #selector(didScroll),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    @objc private func didScroll() { needsDisplay = true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.intersection(rect).fill()
        guard let document, let layout = document.editor.layoutManager,
              let container = document.editor.textContainer, let scrollView else { return }
        let textView = document.editor
        let origin = textView.textContainerOrigin
        let visible = scrollView.contentView.documentVisibleRect
        let contentRect = visible.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layout.glyphRange(forBoundingRect: contentRect, in: container)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let source = textView.string as NSString
        func draw(_ number: Int, at height: CGFloat) {
            let text = String(number) as NSString
            let size = text.size(withAttributes: attributes)
            let point = convert(NSPoint(x: 0, y: height + origin.y), from: textView)
            let y = isFlipped ? point.y + 1 : point.y - size.height - 1
            text.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y), withAttributes: attributes)
        }
        if source.length == 0 {
            draw(1, at: 0)
        } else {
            layout.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, range, _ in
                let character = layout.characterIndexForGlyph(at: range.location)
                if character == 0 || source.character(at: character - 1) == 10 {
                    draw(document.lineNumber(at: character), at: used.minY)
                }
            }
            if source.character(at: source.length - 1) == 10,
               layout.extraLineFragmentTextContainer == container {
                draw(document.lineNumber(at: source.length), at: layout.extraLineFragmentUsedRect.minY)
            }
        }
    }
}
