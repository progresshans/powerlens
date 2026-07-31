import Foundation
import Testing
@testable import PowerLens

/// Guards baked fill geometry separately from runtime badge composition.
/// A malformed fill can still load and parse successfully.
struct MenuBarBatteryAssetGeometryTests {
    /// Reference geometry, matching `Metrics.fillSourceRect` in the renderer.
    private static let barLeft = 14.9976
    private static let barFullWidth = 84.4292
    private static let barHeight = 35.3920

    /// Source units. One unit is ≈0.224 pt once the renderer scales the symbol
    /// into its 24×13 pt canvas, so 0.05 u is ≈0.011 pt.
    private static let tolerance = 0.05

    private static let allLevels = Array(stride(from: 0, through: 100, by: 5))

    @Test
    func fillBarLengthIsLinearInBatteryLevel() throws {
        for level in Self.allLevels {
            let boxes = try fillBarBoxes(level: level)

            guard level > 0 else {
                #expect(boxes.isEmpty, "0% must not draw a fill bar")
                continue
            }

            #expect(boxes.count == 1, "\(level)% should draw one unclipped bar")
            let box = try primaryFillBar(level: level)
            #expect(abs(box.minX - Self.barLeft) < Self.tolerance)

            let expected = Self.expectedReach(level: level)
            #expect(
                abs(box.maxX - expected) < Self.tolerance,
                "\(level)% fill reaches \(box.maxX), expected \(expected)"
            )
        }
    }

    @Test
    func fillBarStepsAreUniform() throws {
        let expectedStep = Self.barFullWidth * 0.05
        var previous = Self.barLeft

        for level in Self.allLevels.dropFirst() {
            let box = try primaryFillBar(level: level)
            let step = box.maxX - previous
            #expect(
                abs(step - expectedStep) < Self.tolerance,
                "step \(level - 5)%→\(level)% is \(step), expected \(expectedStep)"
            )
            previous = box.maxX
        }
    }

    @Test
    func everyFillBarSpansTheFullBarHeight() throws {
        for level in Self.allLevels.dropFirst() {
            let box = try primaryFillBar(level: level)
            #expect(
                abs(box.height - Self.barHeight) < Self.tolerance,
                "\(level)% fill height is \(box.height), expected \(Self.barHeight)"
            )
        }
    }

    // MARK: - Asset geometry

    private struct Box {
        var minX: Double
        var maxX: Double
        var minY: Double
        var maxY: Double

        var height: Double { maxY - minY }
    }

    private enum AssetGeometryError: Error {
        case missingAsset(level: Int)
        case malformedAsset(level: Int)
        case missingFillBar(level: Int)
    }

    private static func expectedReach(level: Int) -> Double {
        barLeft + barFullWidth * Double(level) / 100
    }

    private func primaryFillBar(level: Int) throws -> Box {
        let boxes = try fillBarBoxes(level: level)
        guard let first = boxes.first else {
            throw AssetGeometryError.missingFillBar(level: level)
        }
        return first
    }

    /// Returns the fill-bar subpaths of an asset, in document order.
    ///
    /// Its extrema are on-curve endpoints, so coordinate bounds are exact. The
    /// shell and terminal cap are excluded by their dimensions.
    private func fillBarBoxes(level: Int) throws -> [Box] {
        let path = try ultralightPath(level: level)

        return subpaths(of: path).map(boundingBox(of:)).filter { box in
            box.minY > -53.0 && box.maxY < -17.0 && box.minX > 13.5 && box.maxX < 105.0
        }
    }

    private func ultralightPath(level: Int) throws -> String {
        // `.process("Resources")` flattens the asset folder into the bundle root.
        guard let url = PowerLensResources.bundle.url(
            forResource: "battery.\(level)percent",
            withExtension: "svg"
        ) else {
            throw AssetGeometryError.missingAsset(level: level)
        }

        let svg = try String(contentsOf: url, encoding: .utf8)

        guard let groupRange = svg.range(of: "<g id=\"Ultralight-S\"") else {
            throw AssetGeometryError.malformedAsset(level: level)
        }
        let group = svg[groupRange.lowerBound...]
        guard let attributeRange = group.range(of: " d=\""),
              let end = group[attributeRange.upperBound...].firstIndex(of: "\"")
        else {
            throw AssetGeometryError.malformedAsset(level: level)
        }

        return String(group[attributeRange.upperBound..<end])
    }

    private func subpaths(of path: String) -> [String] {
        path.split(separator: "M").map { "M\($0)" }
    }

    private func boundingBox(of subpath: String) -> Box {
        var values: [Double] = []
        var index = subpath.startIndex

        while index < subpath.endIndex {
            let character = subpath[index]
            guard character.isNumber || character == "-" || character == "+" else {
                index = subpath.index(after: index)
                continue
            }

            // A sign only leads a literal; digits and one decimal point follow.
            var end = subpath.index(after: index)
            while end < subpath.endIndex, subpath[end].isNumber || subpath[end] == "." {
                end = subpath.index(after: end)
            }
            if let value = Double(subpath[index..<end]) {
                values.append(value)
            }
            index = end
        }

        let xs = stride(from: 0, to: values.count, by: 2).map { values[$0] }
        let ys = stride(from: 1, to: values.count, by: 2).map { values[$0] }

        return Box(
            minX: xs.min() ?? 0,
            maxX: xs.max() ?? 0,
            minY: ys.min() ?? 0,
            maxY: ys.max() ?? 0
        )
    }
}
