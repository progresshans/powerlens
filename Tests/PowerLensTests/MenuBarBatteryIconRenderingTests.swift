import AppKit
import Foundation
import Testing
@testable import PowerLens

/// Raster-level regression coverage for composed menu bar icons.
///
/// Alpha masks catch geometry changes that total inked area cannot.
@MainActor
struct MenuBarBatteryIconRenderingTests {
    private static let levels = Array(stride(from: 0, through: 100, by: 5))
    private static let alphaTolerance: UInt8 = 8
    private static let maximumEquivalentChangedPixels = 1

    @Test
    func fillGrowsWithEveryStepWithoutABadge() {
        let masses = renderedMasks(badge: .none, factor: 2).map(\.alphaMass)

        for (index, level) in Self.levels.enumerated().dropFirst() {
            #expect(
                masses[index] > masses[index - 1],
                "\(level)% has alpha mass \(masses[index]), not more than \(level - 5)%'s \(masses[index - 1])"
            )
        }
    }

    @Test
    func fillNeverShrinksAsTheLevelRises() {
        for badge in [MenuBarStatusItemRenderer.Badge.chargingBolt, .pluggedHolding] {
            for factor in [1, 2] {
                let masses = renderedMasks(badge: badge, factor: factor).map(\.alphaMass)
                for (index, level) in Self.levels.enumerated().dropFirst() {
                    #expect(
                        masses[index] >= masses[index - 1],
                        "\(badge) at \(level)% (\(factor)x) has alpha mass \(masses[index]), less than \(level - 5)%'s \(masses[index - 1])"
                    )
                }
            }
        }
    }

    @Test
    func chargingIconSeparatesLevelsBehindTheBolt() {
        // The original defect rendered 60%, 65% and 70% identically. Each pair
        // must now change at several pixel positions.
        let masks = renderedMasks(badge: .chargingBolt, factor: 2)
        let at60 = try? index(of: 60)
        let at65 = try? index(of: 65)
        let at70 = try? index(of: 70)
        guard let i60 = at60, let i65 = at65, let i70 = at70 else {
            Issue.record("level indices unavailable")
            return
        }

        let changed60To65 = changedPixelCount(masks[i60], masks[i65])
        let changed65To70 = changedPixelCount(masks[i65], masks[i70])

        #expect(
            changed60To65 >= 8,
            "60% and 65% differ at only \(changed60To65) pixels"
        )
        #expect(
            changed65To70 >= 8,
            "65% and 70% differ at only \(changed65To70) pixels"
        )
    }

    @Test
    func badgesHideOnlyAShortRunOfLevels() {
        // A badge can legitimately hide adjacent steps. Full masks still detect
        // equal-area images whose pixels moved.
        let limits: [(MenuBarStatusItemRenderer.Badge, Int, String)] = [
            (.none, 1, "none"),
            (.chargingBolt, 1, "chargingBolt"),
            (.pluggedHolding, 3, "pluggedHolding"),
        ]

        for (badge, limit, label) in limits {
            let run = longestEquivalentRun(renderedMasks(badge: badge, factor: 2))
            #expect(
                run <= limit,
                "\(label) renders \(run) consecutive levels equivalently, limit \(limit)"
            )
        }
    }

    @Test
    func imagesAreCachedPerLevelAndBadge() {
        let first = MenuBarStatusItemRenderer.batteryImage(level: 65, badge: .chargingBolt)
        let repeated = MenuBarStatusItemRenderer.batteryImage(level: 65, badge: .chargingBolt)
        #expect(first === repeated, "the same level and badge must reuse one image")

        // Rounding maps 63–67% onto the 65% asset, so those share the entry too.
        let rounded = MenuBarStatusItemRenderer.batteryImage(level: 66, badge: .chargingBolt)
        #expect(first === rounded)

        for other in [MenuBarStatusItemRenderer.Badge.none, .pluggedHolding] {
            let sibling = MenuBarStatusItemRenderer.batteryImage(level: 65, badge: other)
            #expect(first !== sibling, "\(other) must not share the chargingBolt entry")
        }

        let otherLevel = MenuBarStatusItemRenderer.batteryImage(level: 40, badge: .chargingBolt)
        #expect(first !== otherLevel)
    }

    @Test
    func everyIconIsATemplateImage() {
        for level in Self.levels {
            for badge in [MenuBarStatusItemRenderer.Badge.none, .chargingBolt, .pluggedHolding] {
                #expect(MenuBarStatusItemRenderer.batteryImage(level: Double(level), badge: badge).isTemplate)
            }
        }
    }

    // MARK: - Rasterisation

    private func index(of level: Int) throws -> Int {
        guard let index = Self.levels.firstIndex(of: level) else {
            throw RenderingError.unknownLevel(level)
        }
        return index
    }

    private enum RenderingError: Error {
        case unknownLevel(Int)
    }

    private struct AlphaMask {
        let width: Int
        let height: Int
        let alpha: [UInt8]

        var alphaMass: Int {
            alpha.reduce(into: 0) { total, sample in
                total += Int(sample)
            }
        }
    }

    private func renderedMasks(
        badge: MenuBarStatusItemRenderer.Badge,
        factor: Int
    ) -> [AlphaMask] {
        Self.levels.map { level in
            alphaMask(
                MenuBarStatusItemRenderer.batteryImage(level: Double(level), badge: badge),
                factor: factor
            )
        }
    }

    /// Draws the template image into an offscreen bitmap at the given backing
    /// scale and records its alpha mask. This forces the image's drawing handler
    /// to run, which is where the SVG path is parsed and the badge is composed.
    private func alphaMask(_ image: NSImage, factor: Int) -> AlphaMask {
        let size = MenuBarStatusItemRenderer.canvasSize
        let width = Int(size.width) * factor
        let height = Int(size.height) * factor
        let emptyMask = AlphaMask(
            width: width,
            height: height,
            alpha: Array(repeating: 0, count: width * height)
        )

        guard let rep = NSBitmapImageRep(
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
        ) else {
            Issue.record("could not create a \(factor)x bitmap")
            return emptyMask
        }

        // The point size must be set before the context is built, otherwise the
        // context is configured for a 1x destination of `factor`× the point size
        // and the image renders at the wrong scale.
        rep.size = size

        guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
            Issue.record("could not create a \(factor)x drawing destination")
            return emptyMask
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()

        var alpha: [UInt8] = []
        alpha.reserveCapacity(width * height)
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let colour = rep.colorAt(x: x, y: y) else {
                    Issue.record("could not read pixel (\(x), \(y)) from a \(factor)x bitmap")
                    alpha.append(0)
                    continue
                }
                alpha.append(UInt8(clamping: Int((colour.alphaComponent * 255).rounded())))
            }
        }

        return AlphaMask(width: width, height: height, alpha: alpha)
    }

    private func changedPixelCount(_ lhs: AlphaMask, _ rhs: AlphaMask) -> Int {
        guard lhs.width == rhs.width, lhs.height == rhs.height, lhs.alpha.count == rhs.alpha.count else {
            Issue.record("cannot compare alpha masks with different dimensions")
            return .max
        }

        return zip(lhs.alpha, rhs.alpha).reduce(into: 0) { changed, samples in
            if abs(Int(samples.0) - Int(samples.1)) > Int(Self.alphaTolerance) {
                changed += 1
            }
        }
    }

    private func longestEquivalentRun(_ masks: [AlphaMask]) -> Int {
        guard !masks.isEmpty else {
            return 0
        }

        var longest = 1
        var current = 1
        for index in masks.indices.dropFirst() {
            let changed = changedPixelCount(masks[index - 1], masks[index])
            current = changed <= Self.maximumEquivalentChangedPixels ? current + 1 : 1
            longest = max(longest, current)
        }
        return longest
    }
}
