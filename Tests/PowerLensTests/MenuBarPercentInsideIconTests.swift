import AppKit
import Foundation
import Testing
@testable import PowerLens

/// Raster coverage for the macOS 27 battery with the percentage inside.
@MainActor
struct MenuBarPercentInsideIconTests {
    private typealias Renderer = MenuBarStatusItemRenderer
    private static let factor = 2

    @Test
    func imagesAreCachedPerShownPercentBadgeAndTint() {
        let first = Renderer.percentInsideImage(level: 63.6, badge: .chargingBolt)

        #expect(first === Renderer.percentInsideImage(level: 64.4, badge: .chargingBolt))
        #expect(first !== Renderer.percentInsideImage(level: 65, badge: .chargingBolt))
        #expect(first !== Renderer.percentInsideImage(level: 64, badge: .none))
        #expect(first !== Renderer.percentInsideImage(level: 64, badge: .chargingBolt, tint: .init(lowPowerFill: true)))
        #expect(Renderer.percentInsideImage(level: nil, badge: .none) !== Renderer.percentInsideImage(level: 0, badge: .none))
    }

    @Test
    func shownPercentIsRoundedAndClamped() {
        #expect(Renderer.percentInsideValue(level: 89.5) == 90)
        #expect(Renderer.percentInsideValue(level: 89.4) == 89)
        #expect(Renderer.percentInsideValue(level: 104) == 100)
        #expect(Renderer.percentInsideValue(level: -3) == 0)
        #expect(Renderer.percentInsideValue(level: nil) == nil)
        #expect(Renderer.percentInsideValue(level: .nan) == nil)
    }

    @Test
    func onlyTintedImagesOptOutOfTemplateRendering() {
        #expect(Renderer.percentInsideImage(level: 50, badge: .none).isTemplate)
        #expect(!Renderer.percentInsideImage(level: 50, badge: .none, tint: .init(lowPowerFill: true)).isTemplate)
        #expect(!Renderer.percentInsideImage(level: 50, badge: .chargingBolt, tint: .init(warningBadge: true)).isTemplate)
    }

    @Test
    func accessibilityDescriptionReadsThePercent() {
        #expect(Renderer.percentInsideImage(level: 90, badge: .none).accessibilityDescription == "90%")
        #expect(Renderer.percentInsideImage(level: nil, badge: .none).accessibilityDescription == nil)
    }

    @Test
    func fillReachesItsShareOfTheBodyAndTheRestIsTrack() throws {
        let body = try #require(Renderer.percentInsideBodyFrame)

        for level in [20, 35, 50, 65, 80] {
            let bitmap = try render(Renderer.percentInsideImage(level: Double(level), badge: .none))
            let row = topRow(body)
            let solid = (0..<bitmap.width).filter { bitmap.alpha(x: $0, y: row) > 0.9 }
            let fillEnd = try #require(solid.max()) + 1
            let expected = (body.minX + body.width * CGFloat(level) / 100) * CGFloat(Self.factor)

            #expect(abs(CGFloat(fillEnd) - expected) <= 1, "\(level)% fill ends at \(fillEnd) px, expected \(expected)")
            let track = bitmap.alpha(x: fillEnd + 2, y: row)
            #expect(track > 0.35 && track < 0.65, "\(level)% track alpha is \(track)")
        }
    }

    @Test
    func emptyAndMissingLevelsDrawNoFill() throws {
        let body = try #require(Renderer.percentInsideBodyFrame)

        for level in [0, nil] as [Double?] {
            let bitmap = try render(Renderer.percentInsideImage(level: level, badge: .none))
            let row = topRow(body)
            let solid = (0..<bitmap.width).filter { bitmap.alpha(x: $0, y: row) > 0.9 }
            #expect(solid.isEmpty, "\(String(describing: level)) drew fill at columns \(solid)")
        }
    }

    @Test
    func missingLevelShowsAPlaceholderInsteadOfZero() throws {
        let missing = try render(Renderer.percentInsideImage(level: nil, badge: .none))
        let zero = try render(Renderer.percentInsideImage(level: 0, badge: .none))

        #expect(changedPixelCount(missing, zero) > 10)
    }

    @Test
    func digitsAreCutOutOfTheFillAndSolidOverTheTrack() throws {
        let body = try #require(Renderer.percentInsideBodyFrame)
        let inner = innerPixels(body)
        let full = try render(Renderer.percentInsideImage(level: 100, badge: .none))
        let empty = try render(Renderer.percentInsideImage(level: 0, badge: .none))

        #expect(inner.filter { full.alpha(x: $0.x, y: $0.y) < 0.1 }.count > 30, "100% shows no cut-out digits")
        #expect(inner.allSatisfy { empty.alpha(x: $0.x, y: $0.y) > 0.4 }, "0% cuts something out of the track")
        #expect(inner.filter { empty.alpha(x: $0.x, y: $0.y) > 0.9 }.count > 30, "0% shows no solid digits")
    }

    @Test
    func digitsSplitAtTheFillEdge() throws {
        let body = try #require(Renderer.percentInsideBodyFrame)
        let bitmap = try render(Renderer.percentInsideImage(level: 50, badge: .none))
        let reach = Int(((body.minX + body.width / 2) * CGFloat(Self.factor)).rounded())
        let inner = innerPixels(body)
        let overFill = inner.filter { $0.x < reach - 1 }
        let overTrack = inner.filter { $0.x > reach }

        #expect(overFill.contains { bitmap.alpha(x: $0.x, y: $0.y) < 0.1 }, "digits over the fill are not cut out")
        #expect(overTrack.contains { bitmap.alpha(x: $0.x, y: $0.y) > 0.9 }, "digits over the track are not solid")
        #expect(!overTrack.contains { bitmap.alpha(x: $0.x, y: $0.y) < 0.3 }, "something over the track is cut out")
    }

    @Test
    func widestContentStaysCentredAndClearOfTheBodyEnds() throws {
        let body = try #require(Renderer.percentInsideBodyFrame)
        let scale = CGFloat(Self.factor)
        let bodyMinX = Int((body.minX * scale).rounded())
        let bodyMaxX = Int((body.maxX * scale).rounded())
        let centreRow = Int(((Renderer.percentInsideCanvasSize.height - body.midY) * scale).rounded())
        // Tall enough for whole digits, so a "1" is measured with its flag.
        let rows = (centreRow - 8)...(centreRow + 8)

        for badge in [Renderer.Badge.none, .chargingBolt, .pluggedHolding] {
            let bitmap = try render(Renderer.percentInsideImage(level: 100, badge: badge))
            var holes: [Int] = []
            for y in rows {
                // Only count cut-outs between the body's own edges in this row.
                let solid = (bodyMinX..<bodyMaxX).filter { bitmap.alpha(x: $0, y: y) > 0.5 }
                guard let left = solid.min(), let right = solid.max() else {
                    continue
                }
                holes += (left...right).filter { bitmap.alpha(x: $0, y: y) < 0.5 }
            }
            let first = try #require(holes.min())
            let last = try #require(holes.max())
            let leftMargin = first - bodyMinX
            let rightMargin = bodyMaxX - (last + 1)

            #expect(leftMargin >= Self.factor, "\(badge): content \(leftMargin) px from the left end")
            #expect(rightMargin >= Self.factor, "\(badge): content \(rightMargin) px from the right end")
            #expect(abs(leftMargin - rightMargin) <= 2, "\(badge): margins \(leftMargin) / \(rightMargin) px")
        }
    }

    @Test
    func badgeWidensTheCutOut() throws {
        let body = try #require(Renderer.percentInsideBodyFrame)
        let inner = innerPixels(body)
        let plain = try render(Renderer.percentInsideImage(level: 90, badge: .none))
        let charging = try render(Renderer.percentInsideImage(level: 90, badge: .chargingBolt))
        let holes: (Bitmap) -> Int = { bitmap in inner.filter { bitmap.alpha(x: $0.x, y: $0.y) < 0.1 }.count }

        #expect(holes(charging) > holes(plain))
    }

    @Test
    func lowPowerModeFillsYellowAndKeepsTheTrackInk() throws {
        let body = try #require(Renderer.percentInsideBodyFrame)
        let bitmap = try render(Renderer.percentInsideImage(level: 50, badge: .none, tint: .init(lowPowerFill: true)))
        let row = topRow(body)
        let fill = bitmap.pixel(x: Int(body.minX * CGFloat(Self.factor)) + 10, y: row)
        let track = bitmap.pixel(x: Int(body.maxX * CGFloat(Self.factor)) - 8, y: row)

        #expect(fill.r > 0.8 && fill.g > 0.6 && fill.b < 0.35 && fill.a > 0.9, "fill is \(fill)")
        // The light appearance's text color is near black.
        #expect(max(track.r, track.g, track.b) < 0.3 && track.a > 0.35 && track.a < 0.65, "track is \(track)")
    }

    @Test
    func lowPowerDigitsAreCutOutOnlyOnADarkMenuBar() throws {
        let body = try #require(Renderer.percentInsideBodyFrame)
        let inner = innerPixels(body)
        let image = Renderer.percentInsideImage(level: 100, badge: .none, tint: .init(lowPowerFill: true))
        let dark = try render(image, appearance: .darkAqua)
        let light = try render(image, appearance: .aqua)
        let holes: (Bitmap) -> Int = { bitmap in inner.filter { bitmap.alpha(x: $0.x, y: $0.y) < 0.1 }.count }
        let inkDigits = inner.filter {
            let pixel = light.pixel(x: $0.x, y: $0.y)
            return pixel.a > 0.9 && max(pixel.r, pixel.g, pixel.b) < 0.3
        }

        #expect(holes(dark) > 30, "dark menu bar: digits should show through the yellow")
        #expect(holes(light) == 0, "light menu bar: pale cut-outs on yellow are hard to read")
        #expect(inkDigits.count > 30, "light menu bar: digits should be drawn in ink")
    }

    @Test
    func warningColorsOnlyTheBadge() throws {
        let plain = try render(Renderer.percentInsideImage(level: 90, badge: .chargingBolt, tint: .init(warningBadge: true)))
        let noBadge = try render(Renderer.percentInsideImage(level: 90, badge: .none, tint: .init(warningBadge: true)))
        let isRed: (Bitmap.Pixel) -> Bool = { $0.a > 0.5 && $0.r > 0.8 && $0.g < 0.4 && $0.b < 0.4 }

        #expect(plain.pixels.filter(isRed).count > 10)
        #expect(noBadge.pixels.filter(isRed).isEmpty)
    }

    // MARK: - Helpers

    private struct Bitmap {
        struct Pixel: CustomStringConvertible {
            let r: CGFloat
            let g: CGFloat
            let b: CGFloat
            let a: CGFloat

            var description: String {
                String(format: "rgba(%.2f, %.2f, %.2f, %.2f)", r, g, b, a)
            }
        }

        let width: Int
        let height: Int
        let pixels: [Pixel]

        func pixel(x: Int, y: Int) -> Pixel {
            pixels[y * width + x]
        }

        func alpha(x: Int, y: Int) -> CGFloat {
            pixel(x: x, y: y).a
        }
    }

    /// Draws the image at `factor`x. Rows run top down, as
    /// `NSBitmapImageRep` stores them.
    private func render(_ image: NSImage, appearance name: NSAppearance.Name = .aqua) throws -> Bitmap {
        let size = image.size
        let width = Int(size.width) * Self.factor
        let height = Int(size.height) * Self.factor
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        rep.size = size
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        let appearance = try #require(NSAppearance(named: name))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        appearance.performAsCurrentDrawingAppearance {
            image.draw(in: NSRect(origin: .zero, size: size))
        }
        NSGraphicsContext.restoreGraphicsState()

        var pixels: [Bitmap.Pixel] = []
        pixels.reserveCapacity(width * height)
        for y in 0..<height {
            for x in 0..<width {
                let colour = try #require(rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                pixels.append(.init(r: colour.redComponent, g: colour.greenComponent, b: colour.blueComponent, a: colour.alphaComponent))
            }
        }
        return Bitmap(width: width, height: height, pixels: pixels)
    }

    /// A row 1 pt inside the body's top edge: above the digits and badge.
    private func topRow(_ body: NSRect) -> Int {
        let pointsFromTop = Renderer.percentInsideCanvasSize.height - body.maxY + 1
        return Int(pointsFromTop * CGFloat(Self.factor))
    }

    /// Pixels well inside the body, clear of its rounded ends and edges.
    private func innerPixels(_ body: NSRect) -> [(x: Int, y: Int)] {
        let scale = CGFloat(Self.factor)
        let inset = body.insetBy(dx: 2, dy: 1.5)
        let canvasHeight = Renderer.percentInsideCanvasSize.height
        let columns = Int((inset.minX * scale).rounded())..<Int((inset.maxX * scale).rounded())
        let rows = Int(((canvasHeight - inset.maxY) * scale).rounded())..<Int(((canvasHeight - inset.minY) * scale).rounded())
        return rows.flatMap { y in columns.map { (x: $0, y: y) } }
    }

    private func changedPixelCount(_ lhs: Bitmap, _ rhs: Bitmap) -> Int {
        zip(lhs.pixels, rhs.pixels).filter { abs($0.a - $1.a) > 0.1 }.count
    }
}
