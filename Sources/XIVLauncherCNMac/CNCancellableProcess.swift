import Darwin
import Foundation

final class CNCancellableProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var continuation: CheckedContinuation<Int32, Error>?
    private var cancelled = false

    static func run(executableURL: URL, arguments: [String]) async throws -> Int32 {
        let runner = CNCancellableProcess()
        return try await runner.run(executableURL: executableURL, arguments: arguments)
    }

    private func run(executableURL: URL, arguments: [String]) async throws -> Int32 {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                start(executableURL: executableURL, arguments: arguments, continuation: continuation)
            }
        }, onCancel: { [weak self] in
            self?.cancel()
        })
    }

    private func start(executableURL: URL, arguments: [String],
                       continuation: CheckedContinuation<Int32, Error>) {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.terminationHandler = { [weak self] process in
            self?.complete(status: process.terminationStatus)
        }

        lock.lock()
        guard !cancelled else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.process = process
        self.continuation = continuation
        do {
            try process.run()
            lock.unlock()
        } catch {
            self.process = nil
            self.continuation = nil
            lock.unlock()
            continuation.resume(throwing: error)
        }
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()
        guard let process, process.isRunning else { return }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.forceTerminateIfNeeded()
        }
    }

    private func forceTerminateIfNeeded() {
        lock.lock()
        let process = continuation == nil ? nil : self.process
        lock.unlock()
        guard let process, process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
    }

    private func complete(status: Int32) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        let cancelled = self.cancelled
        self.continuation = nil
        process = nil
        lock.unlock()
        if cancelled {
            continuation.resume(throwing: CancellationError())
        } else {
            continuation.resume(returning: status)
        }
    }
}
