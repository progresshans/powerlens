import Foundation
import Testing
@testable import PowerLens

struct BoundedProcessOutputTests {
    @Test
    func successfulOutputIsReturned() async {
        #expect(await BoundedProcessOutput.read(executable: URL(fileURLWithPath: "/usr/bin/printf"),
                                                arguments: ["powermode 2\n"]) == "powermode 2\n")
    }

    @Test
    func timeoutTerminatesAStalledRead() async {
        let start = ContinuousClock.now
        let output = await BoundedProcessOutput.read(executable: URL(fileURLWithPath: "/bin/sleep"),
                                                    arguments: ["20"], timeout: 0.05)
        #expect(output == nil)
        #expect(start.duration(to: .now) < .seconds(5))
    }

    @Test
    func cancellationReachesTheProcessBoundary() async throws {
        let start = ContinuousClock.now
        let task = Task {
            await BoundedProcessOutput.read(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["20"], timeout: 10)
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        #expect(await task.value == nil)
        #expect(start.duration(to: .now) < .seconds(5))
    }
}
