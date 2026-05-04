import Foundation

enum PowerLensResources {
    private static let bundleName = "PowerLens_PowerLens.bundle"

    static let bundle: Bundle = {
        let candidateURLs = resourceBundleCandidates()

        for url in candidateURLs where FileManager.default.fileExists(atPath: url.path) {
            if let bundle = Bundle(url: url) {
                return bundle
            }
        }

        let searchedPaths = candidateURLs.map(\.path).joined(separator: "\n")
        Swift.fatalError("could not load resource bundle. searched:\n\(searchedPaths)")
    }()

    private static func resourceBundleCandidates() -> [URL] {
        var candidates: [URL] = []

        append(Bundle.main.resourceURL?.appendingPathComponent(bundleName), to: &candidates)
        append(Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/\(bundleName)"), to: &candidates)
        append(Bundle.main.bundleURL.appendingPathComponent(bundleName), to: &candidates)

        if let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent() {
            append(executableDirectory.appendingPathComponent(bundleName), to: &candidates)

            var parent = executableDirectory
            for _ in 0..<8 {
                parent.deleteLastPathComponent()
                append(parent.appendingPathComponent(bundleName), to: &candidates)
            }
        }

        candidates.append(contentsOf: buildDirectoryCandidates())

        return candidates
    }

    private static func buildDirectoryCandidates() -> [URL] {
        let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let buildRoot = workingDirectory.appendingPathComponent(".build", isDirectory: true)
        var candidates: [URL] = []

        for configuration in ["debug", "release"] {
            append(buildRoot.appendingPathComponent(configuration, isDirectory: true).appendingPathComponent(bundleName), to: &candidates)
        }

        guard let platformDirectories = try? FileManager.default.contentsOfDirectory(
            at: buildRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return candidates
        }

        for platformDirectory in platformDirectories {
            let isDirectory = (try? platformDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory else {
                continue
            }

            for configuration in ["debug", "release"] {
                append(platformDirectory.appendingPathComponent(configuration, isDirectory: true).appendingPathComponent(bundleName), to: &candidates)
            }
        }

        return candidates
    }

    private static func append(_ url: URL?, to candidates: inout [URL]) {
        guard let url, !candidates.contains(url) else {
            return
        }

        candidates.append(url)
    }
}
