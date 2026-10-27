import Darwin
import Foundation

/// An asynchronous, cancellable boundary for the read-only pmset invocation.
/// The blocking pipe read never runs on the main actor or cooperative pool.
enum BoundedProcessOutput {
    static func read(executable: URL, arguments: [String], timeout: TimeInterval = 3) async -> String? {
        let invocation = Invocation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: invocation.run(executable: executable, arguments: arguments))
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0, timeout)) {
                    invocation.cancel()
                }
            }
        } onCancel: {
            invocation.cancel()
        }
    }

    /// All process ownership and cancellation flags are protected by the lock.
    private final class Invocation: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false

        func run(executable: URL, arguments: [String]) -> String? {
            let child = Process()
            child.executableURL = executable
            child.arguments = arguments
            let pipe = Pipe()
            child.standardOutput = pipe
            child.standardError = FileHandle.nullDevice
            lock.lock()
            guard !cancelled else { lock.unlock(); return nil }
            process = child
            do {
                try child.run()
            } catch {
                process = nil
                lock.unlock()
                return nil
            }
            lock.unlock()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            child.waitUntilExit()
            lock.lock()
            process = nil
            let succeeded = !cancelled && child.terminationStatus == 0
            lock.unlock()
            return succeeded ? String(data: data, encoding: .utf8) : nil
        }

        func cancel() {
            lock.lock()
            cancelled = true
            if let process, process.isRunning { process.terminate() }
            let needsReap = process != nil
            lock.unlock()
            guard needsReap else { return }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2) { [self] in
                lock.lock()
                defer { lock.unlock() }
                if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
}
