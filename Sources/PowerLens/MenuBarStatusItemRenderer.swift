import AppKit
import Foundation

@MainActor
enum MenuBarStatusItemRenderer {
    enum Badge {
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
        let normalizedLevel = normalizedBatteryLevel(level)
        let image = cachedAssetImage(level: normalizedLevel, badge: badge)
            ?? batteryImage(level: normalizedLevel, badge: badge)
        image.isTemplate = true
        return image
    }

    static func assetIdentifier(level: Double?, badge: Badge) -> String {
        let asset = assetLocation(level: normalizedBatteryLevel(level), badge: badge)
        return "\(asset.folder)/\(asset.name)"
    }

    static func canLoadAsset(level: Double?, badge: Badge) -> Bool {
        let asset = assetLocation(level: normalizedBatteryLevel(level), badge: badge)
        return assetPathData(for: AssetKey(folder: asset.folder, name: asset.name)) != nil
    }

    private static var assetImageCache: [AssetKey: NSImage] = [:]
    private static var assetPathDataCache: [AssetKey: String] = [:]

    private static func assetImage(pathData: String) -> NSImage {
        NSImage(size: Metrics.canvasSize, flipped: false) { rect in
            drawAsset(pathData: pathData, in: rect)
            return true
        }
    }

    private static func cachedAssetImage(level: Double, badge: Badge) -> NSImage? {
        let asset = assetLocation(level: level, badge: badge)
        let key = AssetKey(folder: asset.folder, name: asset.name)

        if let image = assetImageCache[key] {
            return image
        }

        guard let pathData = assetPathData(for: key) else {
            return nil
        }

        let image = assetImage(pathData: pathData)
        image.isTemplate = true
        assetImageCache[key] = image
        return image
    }

    private static func batteryImage(level: Double, badge: Badge) -> NSImage {
        NSImage(size: Metrics.canvasSize, flipped: false) { rect in
            drawBattery(in: rect, level: level, badge: badge)
            return true
        }
    }

    private static func drawAsset(pathData: String, in rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }

        context.saveGState()
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)

        draw(pathData: pathData, transform: Metrics.assetSymbolTransform(in: rect))

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

    private static func drawBolt(transform: AffineTransform, context: CGContext) {
        let haloPath = path(from: SymbolPaths.boltHalo)
        haloPath.transform(using: transform)

        context.saveGState()
        context.setBlendMode(.destinationOut)
        NSColor.black.setFill()
        haloPath.fill()
        context.restoreGState()

        draw(pathData: SymbolPaths.boltCore, transform: transform)
    }

    private static func drawPlug(transform: AffineTransform, context: CGContext) {
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

        draw(pathData: SymbolPaths.plugCore, transform: transform)
    }

    private static func draw(pathData: String, transform: AffineTransform) {
        let path = path(from: pathData)
        path.transform(using: transform)
        NSColor.black.setFill()
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

    private static func assetPathData(for asset: AssetKey) -> String? {
        if let pathData = assetPathDataCache[asset] {
            return pathData
        }

        guard let url = PowerLensResources.bundle.url(
            forResource: asset.name,
            withExtension: "svg",
            subdirectory: "MenuBarBattery/\(asset.folder)"
        ) ?? PowerLensResources.bundle.url(forResource: asset.name, withExtension: "svg"),
            let svg = try? String(contentsOf: url, encoding: .utf8)
        else {
            return nil
        }

        guard let pathData = smallPathData(from: svg) else {
            return nil
        }

        assetPathDataCache[asset] = pathData
        return pathData
    }

    private static func assetLocation(level: Double, badge: Badge) -> (folder: String, name: String) {
        let roundedLevel = roundedAssetLevel(level)

        switch badge {
        case .none:
            return ("default", "battery.\(roundedLevel)percent")
        case .chargingBolt:
            return ("bolt", "battery.\(roundedLevel)percent.bolt")
        case .pluggedHolding:
            return ("powerplug", "battery.\(roundedLevel)percent.powerplug")
        }
    }

    private static func roundedAssetLevel(_ level: Double) -> Int {
        let percentage = min(max(level * 100, 0), 100)
        return min(max(Int((percentage / 5).rounded()) * 5, 0), 100)
    }

    private static func smallPathData(from svg: String) -> String? {
        for symbolID in ["Ultralight-S", "Thin-S", "Regular-S"] {
            if let pathData = pathData(from: svg, symbolID: symbolID) {
                return pathData
            }
        }

        return nil
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

    private enum Metrics {
        static let canvasSize = NSSize(width: 24, height: 13)
        static let sourceBounds = NSRect(x: 9.76562, y: -58.0928, width: 103.88838, height: 45.8594)
        static let fillSourceRect = NSRect(x: 14.9976, y: -52.8574, width: 84.4292, height: 35.392)
        static let fillCornerRadius: CGFloat = 12.06
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

    private struct AssetKey: Hashable {
        let folder: String
        let name: String
    }

    private enum SymbolPaths {
        static let shell = "M28.1631-12.2334L86.2613-12.2334C93.877-12.2334 97.8257-13.27 100.75-16.1455C103.626-19.0698 104.613-22.9277 104.613-30.6309L104.613-39.6953C104.613-47.3984 103.626-51.3018 100.75-54.1773C97.7803-57.0562 93.877-58.0928 86.2613-58.0928L27.709-58.0928C20.5962-58.0928 16.5986-57.0108 13.7197-54.1319C10.7988-51.211 9.76562-47.3076 9.76562-40.1948L9.76562-30.6309C9.76562-22.9277 10.7534-19.0244 13.6743-16.1455C16.5986-13.27 20.502-12.2334 28.1631-12.2334ZM27.1797-14.4058C21.6626-14.4058 17.7359-15.481 15.3501-17.8667C12.9644-20.2524 11.9834-24.085 11.9834-29.6475L11.9834-40.2212C11.9834-46.1504 12.9644-50.1157 15.3047-52.5049C17.6905-54.936 21.7535-55.917 27.6372-55.917L87.2447-55.917C92.7617-55.917 96.6431-54.8452 99.0288-52.4595C101.415-50.0703 102.441-46.2412 102.441-40.6753L102.441-29.6475C102.441-24.085 101.369-20.2524 99.0288-17.8667C96.6431-15.4356 92.7617-14.4058 87.2447-14.4058ZM107.692-26.8618C110.227-27.0117 113.654-30.2891 113.654-35.1631C113.654-40.0371 110.227-43.3145 107.692-43.4644Z"
        static let boltHalo = "M38.1294-31.7896C38.1294-29.4975 40.0034-27.7212 42.3374-27.7212L51.9189-27.7212L45.833-11.3653C44.0669-6.4497 49.9605-3.12644 53.2632-7.11865L75.8248-35.5019C76.6333-36.5127 76.9991-37.5859 76.9991-38.5366C76.9991-40.8252 75.1704-42.6016 72.833-42.6016L63.2095-42.6016L69.2955-58.9609C71.0616-63.8765 65.168-67.1997 61.8652-63.2075L39.3037-34.8242C38.4951-33.8135 38.1294-32.7402 38.1294-31.7896Z"
        static let boltCore = "M41.2017-31.7896C41.2017-31.1729 41.6719-30.8003 42.3374-30.8003L56.3042-30.8003L48.7032-10.2749C48.0899-8.59181 49.7867-7.72071 50.8565-9.04835L73.418-37.3794C73.8086-37.8711 73.9165-38.2266 73.9165-38.5366C73.9165-39.1533 73.4497-39.5259 72.8296-39.5259L58.8174-39.5259L66.4185-60.0478C67.0318-61.7309 65.3804-62.6055 64.2652-61.2778L41.7036-32.9014C41.313-32.4097 41.2017-32.0996 41.2017-31.7896Z"
        static let plugCore = "M58.74219-9.53412L63.914-9.53412C66.65028-9.53412 68.03344-10.86952 68.03344-13.48348L68.03344-22.63233C68.03344-25.04741 69.53688-26.3544 71.73193-27.86027C75.67088-30.61628 77.6855-34.76452 77.6855-39.08326L77.6855-44.1407C77.6855-46.72628 76.30233-48.00481 73.56611-48.03326L71.76198-48.06166L71.76198-57.92086C71.76198-59.62557 70.31865-60.96101 68.54463-60.96101C66.74049-60.96101 65.29716-59.62557 65.29716-57.92086L65.29716-48.06166L57.38908-48.06166L57.38908-57.92086C57.38908-59.62557 55.97586-60.96101 54.20184-60.96101C52.3977-60.96101 50.95437-59.62557 50.95437-57.92086L50.95437-48.06166L49.09014-48.03326C46.29375-48.00481 44.9707-46.72628 44.9707-44.1407L44.9707-39.08326C44.9707-34.76452 46.95525-30.61628 50.92432-27.86027C53.11931-26.3544 54.6228-25.04741 54.6228-22.63233L54.6228-13.48348C54.6228-10.86952 55.97586-9.53412 58.74219-9.53412Z"
    }
}
