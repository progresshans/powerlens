import AppKit
import Foundation

@MainActor
enum MenuBarStatusItemRenderer {
    enum Badge: Equatable {
        case none
        case chargingBolt
        case pluggedHolding

        static func resolved(for externalPowerState: ExternalPowerState) -> Self {
            switch externalPowerState {
            case .charging:
                .chargingBolt
            case .holding:
                .pluggedHolding
            case .connected:
                .pluggedHolding
            case .onBattery:
                .none
            }
        }
    }

    static func batteryImage(level: Double?, badge: Badge) -> NSImage {
        cachedImage(percent: canonicalAssetPercent(level: level), badge: badge)
    }

    /// Color on the glyph. The fill follows macOS (yellow in Low Power Mode);
    /// PowerLens's own warning only ever tints the badge, so it cannot be
    /// mistaken for Low Power Mode.
    struct Tint: Hashable, Sendable {
        var lowPowerFill = false
        var warningBadge = false

        static let none = Tint()
    }

    /// A colored, non-template variant. Falls back to the template image when
    /// there is nothing to tint.
    static func batteryImage(level: Double?, badge: Badge, tint: Tint) -> NSImage {
        guard tint != .none else {
            return batteryImage(level: level, badge: badge)
        }

        let percent = canonicalAssetPercent(level: level)
        let key = ImageKey(assetName: assetName(percent: percent), badge: badge, tint: tint)
        if let image = imageCache[key] {
            return image
        }

        let image: NSImage
        if let pathData = assetPathData(named: key.assetName) {
            image = NSImage(size: Metrics.canvasSize, flipped: false) { rect in
                drawTintedAsset(pathData: pathData, badge: badge, tint: tint, in: rect)
                return true
            }
            image.isTemplate = false
        } else {
            image = cachedImage(percent: percent, badge: badge)
        }
        imageCache[key] = image
        return image
    }

    /// Returns the shared base asset; badges are composed at draw time.
    static func assetIdentifier(level: Double?, badge: Badge) -> String {
        assetName(percent: canonicalAssetPercent(level: level))
    }

    static func canLoadAsset(level: Double?, badge: Badge) -> Bool {
        assetPathData(named: assetName(percent: canonicalAssetPercent(level: level))) != nil
    }

    /// The single 5%-step value used by the asset name, image cache, and
    /// programmatic fallback. Keeping this conversion in one place prevents a
    /// missing asset from caching (for example) a 63% drawing under the 65% key.
    static func canonicalAssetPercent(level: Double?) -> Int {
        roundedAssetLevel(normalizedBatteryLevel(level))
    }

    static var canvasSize: NSSize { Metrics.canvasSize }

    /// The macOS 27 battery: level fill, percentage, and power badge share one
    /// solid rounded body. Digits and badge are cut out of the fill and drawn
    /// solid over the empty track, so they stay legible at any level. A
    /// missing level shows "--" over an empty body, never a default fill.
    static func percentInsideImage(level: Double?, badge: Badge, tint: Tint = .none) -> NSImage {
        let key = PercentInsideKey(percent: percentInsideValue(level: level), badge: badge, tint: tint)
        if let image = percentInsideCache[key] {
            return image
        }

        let image = NSImage(size: PercentInsideMetrics.canvasSize, flipped: false) { rect in
            drawPercentInside(key, in: rect)
            return true
        }
        image.isTemplate = tint == .none
        image.accessibilityDescription = key.percent.map { Formatters.percent(Double($0)) }
        // Whole percents times badges and tints add up over a day; only the
        // current image matters, so start over rather than grow without bound.
        if percentInsideCache.count >= PercentInsideMetrics.cacheLimit {
            percentInsideCache.removeAll(keepingCapacity: true)
        }
        percentInsideCache[key] = image
        return image
    }

    /// The whole percent the icon shows, rounded like every other readout.
    static func percentInsideValue(level: Double?) -> Int? {
        guard let level, level.isFinite else {
            return nil
        }
        return Int(min(max(level, 0), 100).rounded())
    }

    static var percentInsideCanvasSize: NSSize { PercentInsideMetrics.canvasSize }

    /// The battery body's frame in the canvas (y up), or nil when the asset
    /// cannot load.
    static var percentInsideBodyFrame: NSRect? {
        percentInsideShape.map {
            PercentInsideMetrics.bodyFrame(
                for: $0.body.bounds,
                in: NSRect(origin: .zero, size: PercentInsideMetrics.canvasSize)
            )
        }
    }

    private static var assetPathDataCache: [String: String] = [:]
    private static var imageCache: [ImageKey: NSImage] = [:]
    private static var percentInsideCache: [PercentInsideKey: NSImage] = [:]

    private static func cachedImage(percent: Int, badge: Badge) -> NSImage {
        let key = ImageKey(assetName: assetName(percent: percent), badge: badge)
        if let image = imageCache[key] {
            return image
        }

        // The programmatic fallback is cached alongside asset-backed images so a
        // missing asset cannot re-enter the bundle lookup on every refresh.
        let image = assetPathData(named: key.assetName)
            .map { assetImage(pathData: $0, badge: badge) }
            ?? batteryImage(level: Double(percent) / 100, badge: badge)
        image.isTemplate = true
        imageCache[key] = image
        return image
    }

    private static func assetImage(pathData: String, badge: Badge) -> NSImage {
        NSImage(size: Metrics.canvasSize, flipped: false) { rect in
            drawAsset(pathData: pathData, badge: badge, in: rect)
            return true
        }
    }

    private static func batteryImage(level: Double, badge: Badge) -> NSImage {
        NSImage(size: Metrics.canvasSize, flipped: false) { rect in
            drawBattery(in: rect, level: level, badge: badge)
            return true
        }
    }

    private static func drawAsset(pathData: String, badge: Badge, in rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }

        context.saveGState()
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)

        let transform = Metrics.assetSymbolTransform(in: rect)
        draw(pathData: pathData, transform: transform)

        switch badge {
        case .none:
            break
        case .chargingBolt:
            drawBolt(transform: transform, context: context)
        case .pluggedHolding:
            drawPlug(transform: transform, context: context)
        }

        context.restoreGState()
    }

    private static func drawBattery(in rect: NSRect, level: Double, badge: Badge) {
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }

        context.saveGState()
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)

        let transform = Metrics.symbolTransform(in: rect)
        drawFill(level: level, transform: transform)
        draw(pathData: SymbolPaths.shell, transform: transform)

        switch badge {
        case .none:
            break
        case .chargingBolt:
            drawBolt(transform: transform, context: context)
        case .pluggedHolding:
            drawPlug(transform: transform, context: context)
        }

        context.restoreGState()
    }

    private static func drawFill(level: Double, transform: AffineTransform) {
        guard level > 0 else {
            return
        }

        let fillRect = Metrics.fillRect(level: level)
        let fillPath = NSBezierPath(
            roundedRect: fillRect,
            xRadius: min(Metrics.fillCornerRadius, fillRect.width / 2),
            yRadius: min(Metrics.fillCornerRadius, fillRect.width / 2)
        )
        fillPath.transform(using: transform)

        NSColor.black.setFill()
        fillPath.fill()
    }

    private static func drawTintedAsset(pathData: String, badge: Badge, tint: Tint, in rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }

        context.saveGState()
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)

        // Non-template images are not recolored by the menu bar, so draw the
        // shell in the text color of the current (menu bar) appearance.
        let ink = NSColor.textColor
        let transform = Metrics.assetSymbolTransform(in: rect)
        let parts = splitFillSubpath(pathData)
        draw(pathData: parts.shell, transform: transform, color: ink)
        if let fill = parts.fill {
            draw(pathData: fill, transform: transform, color: tint.lowPowerFill ? .systemYellow : ink)
        }

        let badgeColor = tint.warningBadge ? NSColor.systemRed : ink
        switch badge {
        case .none:
            break
        case .chargingBolt:
            drawBolt(transform: transform, context: context, color: badgeColor)
        case .pluggedHolding:
            drawPlug(transform: transform, context: context, color: badgeColor)
        }

        context.restoreGState()
    }

    /// Asset paths start with the level fill as their own subpath when the
    /// level is above zero; the remaining three subpaths are the shell.
    private static func splitFillSubpath(_ pathData: String) -> (fill: String?, shell: String) {
        let starts = pathData.indices.filter { pathData[$0] == "M" }
        guard starts.count >= 4 else {
            return (nil, pathData)
        }
        let boundary = starts[1]
        return (String(pathData[..<boundary]), String(pathData[boundary...]))
    }

    private static func drawBolt(transform: AffineTransform, context: CGContext, color: NSColor = .black) {
        let haloPath = path(from: SymbolPaths.boltHalo)
        haloPath.transform(using: transform)

        context.saveGState()
        context.setBlendMode(.destinationOut)
        NSColor.black.setFill()
        haloPath.fill()
        context.restoreGState()

        draw(pathData: SymbolPaths.boltCore, transform: transform, color: color)
    }

    private static func drawPlug(transform: AffineTransform, context: CGContext, color: NSColor = .black) {
        let haloPath = path(from: SymbolPaths.plugCore)
        haloPath.transform(using: transform)
        haloPath.lineCapStyle = .round
        haloPath.lineJoinStyle = .round
        haloPath.lineWidth = Metrics.plugHaloStrokeWidth

        context.saveGState()
        context.setBlendMode(.destinationOut)
        NSColor.black.setFill()
        NSColor.black.setStroke()
        haloPath.fill()
        haloPath.stroke()
        context.restoreGState()

        draw(pathData: SymbolPaths.plugCore, transform: transform, color: color)
    }

    private static func draw(pathData: String, transform: AffineTransform, color: NSColor = .black) {
        let path = path(from: pathData)
        path.transform(using: transform)
        color.setFill()
        path.fill()
    }

    private static func path(from pathData: String) -> NSBezierPath {
        let scanner = Scanner(string: pathData)
        scanner.charactersToBeSkipped = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ","))

        let commandCharacters = CharacterSet(charactersIn: "MLCZ")
        let path = NSBezierPath()
        var command: String?

        while !scanner.isAtEnd {
            if let nextCommand = scanner.scanCharacters(from: commandCharacters) {
                command = String(nextCommand.suffix(1))
            }

            guard let activeCommand = command else {
                break
            }

            switch activeCommand {
            case "M":
                guard let point = scanPoint(scanner) else {
                    return path
                }
                path.move(to: point)
            case "L":
                guard let point = scanPoint(scanner) else {
                    return path
                }
                path.line(to: point)
            case "C":
                guard
                    let control1 = scanPoint(scanner),
                    let control2 = scanPoint(scanner),
                    let end = scanPoint(scanner)
                else {
                    return path
                }
                path.curve(to: end, controlPoint1: control1, controlPoint2: control2)
            case "Z":
                path.close()
                command = nil
            default:
                return path
            }
        }

        return path
    }

    private static func scanPoint(_ scanner: Scanner) -> NSPoint? {
        guard let x = scanner.scanDouble(), let y = scanner.scanDouble() else {
            return nil
        }

        return NSPoint(x: x, y: y)
    }

    private static func normalizedBatteryLevel(_ level: Double?) -> Double {
        min(max((level ?? 0) / 100, 0), 1)
    }

    /// Path data of the first symbol group found, in order. The default list
    /// prefers the lightest small weight.
    private static func assetPathData(
        named name: String,
        symbolIDs: [String] = ["Ultralight-S", "Thin-S", "Regular-S"]
    ) -> String? {
        let cacheKey = ([name] + symbolIDs).joined(separator: "#")
        if let pathData = assetPathDataCache[cacheKey] {
            return pathData
        }

        // `.process("Resources")` flattens the asset folders into the bundle
        // root, so the file is addressed by name alone.
        guard let url = PowerLensResources.bundle.url(
            forResource: name,
            withExtension: "svg"
        ),
            let svg = try? String(contentsOf: url, encoding: .utf8),
            let pathData = symbolIDs.lazy.compactMap({ pathData(from: svg, symbolID: $0) }).first
        else {
            return nil
        }

        assetPathDataCache[cacheKey] = pathData
        return pathData
    }

    private static func assetName(percent: Int) -> String {
        "battery.\(percent)percent"
    }

    private static func roundedAssetLevel(_ level: Double) -> Int {
        let percentage = min(max(level * 100, 0), 100)
        return min(max(Int((percentage / 5).rounded()) * 5, 0), 100)
    }

    private static func pathData(from svg: String, symbolID: String) -> String? {
        guard let groupRange = svg.range(of: "<g id=\"\(symbolID)\"") else {
            return nil
        }

        let regularSmallGroup = svg[groupRange.lowerBound...]
        guard let pathRange = regularSmallGroup.range(of: " d=\"") else {
            return nil
        }

        let pathStart = pathRange.upperBound
        guard let pathEnd = regularSmallGroup[pathStart...].firstIndex(of: "\"") else {
            return nil
        }

        return String(regularSmallGroup[pathStart..<pathEnd])
    }

    private static func drawPercentInside(_ key: PercentInsideKey, in rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext,
              let shape = percentInsideShape
        else {
            return
        }

        context.saveGState()
        defer { context.restoreGState() }
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)

        // Template images are recolored by the menu bar. Tinted images are
        // not, so they draw in the current appearance's text color.
        let ink: NSColor = key.tint == .none ? .black : .textColor
        let secondary = ink.withAlphaComponent(PercentInsideMetrics.trackAlpha)
        let transform = PercentInsideMetrics.transform(for: shape.body.bounds, in: rect)
        let body = transformed(shape.body, by: transform).cgPath
        let nub = transformed(shape.nub, by: transform).cgPath
        let frame = body.boundingBoxOfPath

        let percent = key.percent ?? 0
        let reach = percent > 0
            ? deviceAligned(frame.minX + frame.width * CGFloat(percent) / 100, in: context)
            : frame.minX
        let filled = NSRect(x: rect.minX, y: rect.minY, width: max(reach - rect.minX, 0), height: rect.height)
        let empty = NSRect(x: reach, y: rect.minY, width: max(rect.maxX - reach, 0), height: rect.height)

        context.saveGState()
        context.addPath(body)
        context.clip()
        secondary.setFill()
        context.fill(empty)
        (key.tint.lowPowerFill ? NSColor.systemYellow : ink).setFill()
        context.fill(filled)
        context.restoreGState()

        secondary.setFill()
        context.addPath(nub)
        context.fillPath()

        let content = percentInsideContent(key, body: frame, shape: shape)

        // Cut the digits and badge out of the fill... Cut-outs show the menu
        // bar through the fill, which reads well on the ink fill and on yellow
        // over a dark menu bar, but not on yellow over a light one, so there
        // they are drawn in ink instead.
        let cutsOut = !key.tint.lowPowerFill
            || NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        context.saveGState()
        context.addPath(body)
        context.clip()
        context.clip(to: filled)
        if cutsOut {
            context.setBlendMode(.destinationOut)
            NSColor.black.setFill()
        } else {
            ink.setFill()
        }
        context.addPath(content.all)
        context.fillPath()
        context.restoreGState()

        // ...and draw them solid over the empty track.
        context.saveGState()
        context.addPath(body)
        context.clip()
        context.clip(to: empty)
        ink.setFill()
        context.addPath(content.all)
        context.fillPath()
        context.restoreGState()

        // A warning colors the badge wherever it sits, as on the other icons.
        if key.tint.warningBadge, let badge = content.badge {
            NSColor.systemRed.setFill()
            context.addPath(badge)
            context.fillPath()
        }
    }

    /// Digits followed by the badge, centered in the body as one group.
    private static func percentInsideContent(
        _ key: PercentInsideKey,
        body: NSRect,
        shape: PercentInsideShape
    ) -> (all: CGPath, badge: CGPath?) {
        let fontSize = body.height * PercentInsideMetrics.fontScale
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)
        let capHeight = font.capHeight
        let digits = glyphPath(
            key.percent.map(String.init) ?? "--",
            font: font,
            tracking: PercentInsideMetrics.tracking * fontSize
        )
        let digitInk = digits.boundingBoxOfPath

        // Lay the group out from x = 0 with the baseline at y = 0.
        let local = CGMutablePath()
        local.addPath(digits, transform: CGAffineTransform(translationX: -digitInk.minX, y: 0))
        var groupWidth = digitInk.width
        var badgeLocal: CGPath?

        let badgeSource: NSBezierPath? = switch key.badge {
        case .none: nil
        case .chargingBolt: shape.bolt
        case .pluggedHolding: shape.plug
        }
        if let badgeSource {
            let source = badgeSource.cgPath
            let bounds = source.boundingBoxOfPath
            let scale = capHeight * PercentInsideMetrics.badgeHeight / bounds.height
            let left = groupWidth + PercentInsideMetrics.badgeGap * fontSize
            // SF Symbols paths point y down; flip them into the canvas and
            // centre the badge on the digits' cap height.
            let place = CGAffineTransform(
                a: scale, b: 0, c: 0, d: -scale,
                tx: left - bounds.minX * scale,
                ty: capHeight / 2 + bounds.midY * scale
            )
            let badge = CGMutablePath()
            badge.addPath(source, transform: place)
            badgeLocal = badge
            local.addPath(badge)
            groupWidth = left + bounds.width * scale
        }

        let available = body.width - 2 * PercentInsideMetrics.sideMargin * body.height
        let fit = min(1, available / groupWidth)
        let final = CGAffineTransform(
            a: fit, b: 0, c: 0, d: fit,
            tx: body.midX - groupWidth * fit / 2,
            ty: body.midY - capHeight * fit / 2
        )

        let all = CGMutablePath()
        all.addPath(local, transform: final)
        let badge = badgeLocal.map { path -> CGPath in
            let placed = CGMutablePath()
            placed.addPath(path, transform: final)
            return placed
        }
        return (all, badge)
    }

    /// Outlines of `text` with tabular digits, baseline at y = 0.
    private static func glyphPath(_ text: String, font: NSFont, tracking: CGFloat) -> CGPath {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: font, .kern: tracking])
        )
        let path = CGMutablePath()
        let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            for (glyph, position) in zip(glyphs, positions) {
                guard let outline = CTFontCreatePathForGlyph(font as CTFont, glyph, nil) else {
                    continue
                }
                path.addPath(outline, transform: CGAffineTransform(translationX: position.x, y: position.y))
            }
        }
        return path
    }

    /// Snaps an x coordinate to the device pixel grid so the straight edge of
    /// the fill stays crisp at 1x and 2x.
    private static func deviceAligned(_ x: CGFloat, in context: CGContext) -> CGFloat {
        let device = context.convertToDeviceSpace(CGPoint(x: x, y: 0))
        return context.convertToUserSpace(CGPoint(x: device.x.rounded(), y: device.y)).x
    }

    private static func transformed(_ path: NSBezierPath, by transform: AffineTransform) -> NSBezierPath {
        let copy = NSBezierPath()
        copy.append(path)
        copy.transform(using: transform)
        return copy
    }

    /// Splits SVG path data before each move-to.
    private static func subpaths(of pathData: String) -> [String] {
        let starts = pathData.indices.filter { pathData[$0] == "M" }
        return zip(starts, starts.dropFirst() + [pathData.endIndex]).map { String(pathData[$0..<$1]) }
    }

    private struct PercentInsideKey: Hashable {
        let percent: Int?
        let badge: Badge
        let tint: Tint
    }

    private struct PercentInsideShape {
        /// The outer outline of the SF Symbols 7 battery, drawn solid.
        let body: NSBezierPath
        let nub: NSBezierPath
        let bolt: NSBezierPath
        let plug: NSBezierPath
    }

    /// Loaded once. The battery asset holds the outer outline, the inner
    /// outline (unused: the body is solid), and the nub.
    private static let percentInsideShape: PercentInsideShape? = {
        guard let battery = assetPathData(named: "battery.0percent.macOS27"),
              let bolt = assetPathData(named: "bolt.fill", symbolIDs: ["Regular-S"])
        else {
            return nil
        }
        let parts = subpaths(of: battery)
        guard parts.count == 3 else {
            return nil
        }
        return PercentInsideShape(
            body: path(from: parts[0]),
            nub: path(from: parts[2]),
            bolt: path(from: bolt),
            plug: path(from: SymbolPaths.plugCore)
        )
    }()

    /// Measured from the macOS 27 system battery at 2x: a 23 pt body with
    /// SF Pro Semibold digits about two thirds of its height, tracked tight.
    private enum PercentInsideMetrics {
        static let canvasSize = NSSize(width: 26, height: 13)
        static let bodyWidth: CGFloat = 23
        /// Opacity of the empty track and the nub, relative to the ink.
        static let trackAlpha: CGFloat = 0.5
        /// Font size as a fraction of the body height.
        static let fontScale: CGFloat = 0.926
        /// Letter spacing and the digit-to-badge gap, in ems.
        static let tracking: CGFloat = -0.078
        static let badgeGap: CGFloat = 0.11
        /// Badge height as a multiple of the digits' cap height.
        static let badgeHeight: CGFloat = 1.05
        /// Clearance on each side, as a fraction of the body height. Wider
        /// content ("100" with a badge) shrinks to fit.
        static let sideMargin: CGFloat = 0.135
        static let cacheLimit = 64

        /// Puts the body flush left on a whole point so its straight edges
        /// stay crisp, centred vertically. SF Symbols paths point y down.
        static func transform(for source: NSRect, in rect: NSRect) -> AffineTransform {
            let scale = bodyWidth / source.width
            return AffineTransform(
                m11: scale, m12: 0, m21: 0, m22: -scale,
                tX: rect.minX - source.minX * scale,
                tY: rect.midY + source.midY * scale
            )
        }

        static func bodyFrame(for source: NSRect, in rect: NSRect) -> NSRect {
            let height = source.height * bodyWidth / source.width
            return NSRect(x: rect.minX, y: rect.midY - height / 2, width: bodyWidth, height: height)
        }
    }

    private enum Metrics {
        static let canvasSize = NSSize(width: 24, height: 13)
        static let sourceBounds = NSRect(x: 9.76562, y: -58.0928, width: 103.88838, height: 45.8594)
        static let fillSourceRect = NSRect(x: 14.9976, y: -52.8574, width: 84.4292, height: 35.392)
        static let fillCornerRadius: CGFloat = 12.06
        // Wider round strokes erase the plug's concave details. Raster tests
        // guard the resulting shape at 1x and 2x.
        static let plugHaloStrokeWidth: CGFloat = 1.25

        static func symbolTransform(in rect: NSRect) -> AffineTransform {
            symbolTransform(in: rect, sourceBounds: sourceBounds)
        }

        static func assetSymbolTransform(in rect: NSRect) -> AffineTransform {
            symbolTransform(in: rect, sourceBounds: sourceBounds)
        }

        private static func symbolTransform(in rect: NSRect, sourceBounds: NSRect) -> AffineTransform {
            let drawingRect = rect.insetBy(dx: 0.35, dy: 1.25)
            let scale = min(drawingRect.width / sourceBounds.width, drawingRect.height / sourceBounds.height)
            let targetWidth = sourceBounds.width * scale
            let targetHeight = sourceBounds.height * scale
            let targetMinX = drawingRect.midX - targetWidth / 2
            let targetMinY = drawingRect.midY - targetHeight / 2

            let tx = targetMinX - sourceBounds.minX * scale
            let ty = targetMinY + sourceBounds.maxY * scale
            return AffineTransform(m11: scale, m12: 0, m21: 0, m22: -scale, tX: tx, tY: ty)
        }

        static func fillRect(level: Double) -> NSRect {
            NSRect(
                x: fillSourceRect.minX,
                y: fillSourceRect.minY,
                width: max(fillSourceRect.width * level, 0.001),
                height: fillSourceRect.height
            )
        }
    }

    private struct ImageKey: Hashable {
        let assetName: String
        let badge: Badge
        var tint: Tint = .none
    }

    private enum SymbolPaths {
        static let shell = "M28.1631-12.2334L86.2613-12.2334C93.877-12.2334 97.8257-13.27 100.75-16.1455C103.626-19.0698 104.613-22.9277 104.613-30.6309L104.613-39.6953C104.613-47.3984 103.626-51.3018 100.75-54.1773C97.7803-57.0562 93.877-58.0928 86.2613-58.0928L27.709-58.0928C20.5962-58.0928 16.5986-57.0108 13.7197-54.1319C10.7988-51.211 9.76562-47.3076 9.76562-40.1948L9.76562-30.6309C9.76562-22.9277 10.7534-19.0244 13.6743-16.1455C16.5986-13.27 20.502-12.2334 28.1631-12.2334ZM27.1797-14.4058C21.6626-14.4058 17.7359-15.481 15.3501-17.8667C12.9644-20.2524 11.9834-24.085 11.9834-29.6475L11.9834-40.2212C11.9834-46.1504 12.9644-50.1157 15.3047-52.5049C17.6905-54.936 21.7535-55.917 27.6372-55.917L87.2447-55.917C92.7617-55.917 96.6431-54.8452 99.0288-52.4595C101.415-50.0703 102.441-46.2412 102.441-40.6753L102.441-29.6475C102.441-24.085 101.369-20.2524 99.0288-17.8667C96.6431-15.4356 92.7617-14.4058 87.2447-14.4058ZM107.692-26.8618C110.227-27.0117 113.654-30.2891 113.654-35.1631C113.654-40.0371 110.227-43.3145 107.692-43.4644Z"
        static let boltHalo = "M38.1294-31.7896C38.1294-29.4975 40.0034-27.7212 42.3374-27.7212L51.9189-27.7212L45.833-11.3653C44.0669-6.4497 49.9605-3.12644 53.2632-7.11865L75.8248-35.5019C76.6333-36.5127 76.9991-37.5859 76.9991-38.5366C76.9991-40.8252 75.1704-42.6016 72.833-42.6016L63.2095-42.6016L69.2955-58.9609C71.0616-63.8765 65.168-67.1997 61.8652-63.2075L39.3037-34.8242C38.4951-33.8135 38.1294-32.7402 38.1294-31.7896Z"
        static let boltCore = "M41.2017-31.7896C41.2017-31.1729 41.6719-30.8003 42.3374-30.8003L56.3042-30.8003L48.7032-10.2749C48.0899-8.59181 49.7867-7.72071 50.8565-9.04835L73.418-37.3794C73.8086-37.8711 73.9165-38.2266 73.9165-38.5366C73.9165-39.1533 73.4497-39.5259 72.8296-39.5259L58.8174-39.5259L66.4185-60.0478C67.0318-61.7309 65.3804-62.6055 64.2652-61.2778L41.7036-32.9014C41.313-32.4097 41.2017-32.0996 41.2017-31.7896Z"
        // Copied from the retired `powerplug` artwork to preserve its shape and
        // placement.
        static let plugCore = "M53.3478-8.40215L61.74073-8.40215C63.60501 -8.40215 64.65695 -9.5071 64.65695 -11.38877L64.65695-19.40228C64.65695 -22.47528 65.59915 -24.16667 68.16479 -26.10912C71.83881 -28.94384 73.9165 -33.27056 73.9165 -37.99321L73.9165-48.42509C73.9165 -50.18682 72.8349 -51.25793 71.08925 -51.26014L67.18817-51.26234L67.18817-59.86107C67.18817 -60.96537 66.30972 -61.92311 65.11015 -61.92311C63.93802 -61.92311 63.00026 -60.96537 63.00026 -59.86107L63.00026-51.26234L51.9718-51.26234L51.9718-59.86107C51.9718 -60.96537 51.06598 -61.92311 49.92573 -61.92311C48.7536 -61.92311 47.81584 -60.96537 47.81584 -59.86107L47.81584-51.26234L43.8806-51.26014C42.21946 -51.25793 41.2017 -50.18682 41.2017 -48.42509L41.2017-37.99321C41.2017 -33.27056 43.33647 -28.94384 46.98305 -26.10912C49.57841 -24.16667 50.46124 -22.47528 50.46124 -19.40228L50.46124-11.38877C50.46124 -9.5071 51.51096 -8.40215 53.3478 -8.40215Z"
    }
}
