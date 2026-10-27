import AppKit
import SwiftUI

/// Which characters of a reading roll when it changes. Pure, so the decision
/// can be checked without layers.
enum RollingDigits {
    enum Plan: Equatable {
        case unchanged
        /// Same shape: only the digits at these positions roll. `upward` means
        /// the reading went up, so new digits come in from below.
        case roll(positions: [Int], upward: Bool)
        /// The length or a non-digit changed, so the reading is redrawn in
        /// place without motion.
        case redraw
    }

    static func plan(from old: String, to new: String) -> Plan {
        guard old != new else {
            return .unchanged
        }
        let before = Array(old)
        let after = Array(new)
        guard !old.isEmpty, before.count == after.count else {
            return .redraw
        }

        var positions: [Int] = []
        for index in before.indices where before[index] != after[index] {
            guard isDigit(before[index]), isDigit(after[index]) else {
                return .redraw
            }
            positions.append(index)
        }
        return .roll(positions: positions, upward: value(of: new) >= value(of: old))
    }

    static func isDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    private static func value(of text: String) -> Double {
        Double(text.filter { isDigit($0) || $0 == "." }) ?? 0
    }
}

/// A reading whose changed digits roll into place. Core Animation runs the
/// roll in the render server, so the app does no work per frame. A SwiftUI
/// content transition would redraw the whole window on the CPU for every
/// frame of every roll.
struct RollingNumberText: View {
    let text: String
    let font: NSFont
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.flowLightIsActive) private var isVisible

    /// System font with tabular digits, like `.system(size:weight:)` plus
    /// `.monospacedDigit()`.
    init(_ text: String, size: CGFloat, weight: NSFont.Weight) {
        self.text = text
        self.font = .monospacedDigitSystemFont(ofSize: size, weight: weight)
    }

    var body: some View {
        let baseline = RollingNumberView.baseline(for: font)
        RollingNumberRepresentable(text: text, font: font, animates: isVisible && !reduceMotion)
            .alignmentGuide(.firstTextBaseline) { _ in baseline }
            .alignmentGuide(.lastTextBaseline) { _ in baseline }
            .accessibilityElement()
            .accessibilityLabel(text)
    }
}

private struct RollingNumberRepresentable: NSViewRepresentable {
    let text: String
    let font: NSFont
    let animates: Bool

    func makeNSView(context: Context) -> RollingNumberView {
        RollingNumberView()
    }

    func updateNSView(_ view: RollingNumberView, context: Context) {
        view.update(text: text, font: font, animates: animates)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RollingNumberView, context: Context) -> CGSize? {
        RollingNumberView.size(of: text, font: font)
    }
}

/// One masked slot per character, each showing a pre-drawn glyph. A changed
/// digit gets a push transition from its old glyph to the new one.
final class RollingNumberView: NSView {
    private static let rollDuration: CFTimeInterval = 0.35
    private static var lineHeights: [NSFont: CGFloat] = [:]

    private var text = ""
    private var font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    private var glyphLayers: [CALayer] = []
    private var slotLayers: [CALayer] = []
    private var glyphCache: [String: CGImage] = [:]

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        Self.size(of: text, font: font)
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static func size(of text: String, font: NSFont) -> CGSize {
        CGSize(width: ceil(text.reduce(0) { $0 + width(of: $1, font: font) }), height: lineHeight(for: font))
    }

    /// Distance from the top to where digits sit, for text-baseline alignment.
    static func baseline(for font: NSFont) -> CGFloat {
        lineHeight(for: font) + font.descender
    }

    private static func lineHeight(for font: NSFont) -> CGFloat {
        if let cached = lineHeights[font] {
            return cached
        }
        let height = NSLayoutManager().defaultLineHeight(for: font)
        lineHeights[font] = height
        return height
    }

    private static func width(of character: Character, font: NSFont) -> CGFloat {
        (String(character) as NSString).size(withAttributes: [.font: font]).width
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        redrawGlyphs()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        redrawGlyphs()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        redrawGlyphs()
    }

    func update(text newText: String, font newFont: NSFont, animates: Bool) {
        if newFont != font {
            font = newFont
            text = newText
            invalidateIntrinsicContentSize()
            redrawGlyphs()
            return
        }

        let plan = RollingDigits.plan(from: text, to: newText)
        text = newText

        switch plan {
        case .unchanged:
            return
        case .redraw:
            invalidateIntrinsicContentSize()
            rebuild()
        case let .roll(positions, upward):
            let characters = Array(newText)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for index in positions {
                let glyph = glyphLayers[index]
                if animates {
                    let push = CATransition()
                    push.type = .push
                    // The geometry is flipped, so `.fromTop` enters from
                    // below on screen: rising readings roll up.
                    push.subtype = upward ? .fromTop : .fromBottom
                    push.duration = Self.rollDuration
                    push.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    glyph.add(push, forKey: "roll")
                }
                glyph.contents = image(for: characters[index])
            }
            CATransaction.commit()
        }
    }

    /// Colors, scale or font changed: drop cached glyphs and redraw without
    /// motion.
    private func redrawGlyphs() {
        glyphCache = [:]
        rebuild()
    }

    private func rebuild() {
        guard let host = layer else {
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        slotLayers.forEach { $0.removeFromSuperlayer() }
        slotLayers = []
        glyphLayers = []

        let scale = window?.backingScaleFactor ?? 2
        let lineHeight = Self.lineHeight(for: font)
        var x: CGFloat = 0
        for character in text {
            let width = Self.width(of: character, font: font)
            let slot = CALayer()
            slot.frame = CGRect(x: x, y: 0, width: width, height: lineHeight)
            slot.masksToBounds = true

            let glyph = CALayer()
            glyph.frame = slot.bounds
            glyph.contentsScale = scale
            glyph.contentsGravity = .topLeft
            glyph.contents = image(for: character)

            slot.addSublayer(glyph)
            host.addSublayer(slot)
            slotLayers.append(slot)
            glyphLayers.append(glyph)
            x += width
        }
    }

    private func image(for character: Character) -> CGImage? {
        let scale = window?.backingScaleFactor ?? 2
        let key = "\(character)|\(effectiveAppearance.name.rawValue)|\(scale)"
        if let cached = glyphCache[key] {
            return cached
        }

        let string = String(character) as NSString
        let size = CGSize(width: ceil(Self.width(of: character, font: font)), height: Self.lineHeight(for: font))
        guard size.width > 0,
              let bitmap = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: Int(size.width * scale),
                  pixelsHigh: Int(size.height * scale),
                  bitsPerSample: 8,
                  samplesPerPixel: 4,
                  hasAlpha: true,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bytesPerRow: 0,
                  bitsPerPixel: 0
              ) else {
            return nil
        }
        bitmap.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            string.draw(at: .zero, withAttributes: [.font: font, .foregroundColor: NSColor.labelColor])
        }
        NSGraphicsContext.restoreGraphicsState()

        let image = bitmap.cgImage
        glyphCache[key] = image
        return image
    }
}
