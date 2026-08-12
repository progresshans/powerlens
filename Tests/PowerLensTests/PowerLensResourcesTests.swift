import Foundation
import Testing
@testable import PowerLens

struct PowerLensResourcesTests {
    @Test
    func buildDirectoryCandidatesCoverNativeAndSwiftBuildLayouts() throws {
        let fileManager = FileManager.default
        let buildRoot = fileManager.temporaryDirectory
            .appendingPathComponent("PowerLensResourcesTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(".build", isDirectory: true)
        let nativeBundle = buildRoot
            .appendingPathComponent("arm64-apple-macosx/debug/PowerLens_PowerLens.bundle", isDirectory: true)
        let swiftBuildBundle = buildRoot
            .appendingPathComponent("out/Products/Debug/PowerLens_PowerLens.bundle", isDirectory: true)

        try fileManager.createDirectory(at: nativeBundle, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: swiftBuildBundle, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: buildRoot.deletingLastPathComponent())
        }

        let candidatePaths = Set(
            PowerLensResources.buildDirectoryCandidates(buildRoot: buildRoot)
                .map(canonicalPath)
        )

        #expect(candidatePaths.contains(
            canonicalPath(buildRoot.appendingPathComponent("debug/PowerLens_PowerLens.bundle"))
        ))
        #expect(candidatePaths.contains(
            canonicalPath(nativeBundle)
        ))
        #expect(candidatePaths.contains(
            canonicalPath(swiftBuildBundle)
        ))
    }

    private func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
