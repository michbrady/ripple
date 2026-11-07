import Foundation

public struct ProcessResult: Sendable {
    public var status: Int32
    public var output: String
    public var error: String
}

/// Collects a pipe's bytes and hands out complete lines. Pipes call this from other threads.
private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var all = Data()

    func add(_ data: Data, onLine: (String) -> Void) {
        lock.lock()
        all.append(data)
        pending.append(data)
        var lines: [String] = []
        // yt-dlp ends progress lines with a newline when given --newline; \r covers the rest.
        while let index = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            lines.append(String(decoding: pending[pending.startIndex..<index], as: UTF8.self))
            pending.removeSubrange(pending.startIndex...index)
        }
        lock.unlock()
        for line in lines where !line.isEmpty { onLine(line) }
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: all, as: UTF8.self)
    }
}

/// Every program Ripple has started and not yet seen finish, so quitting can stop them.
private final class RunningProcesses: @unchecked Sendable {
    static let shared = RunningProcesses()
    private let lock = NSLock()
    private var all: [ObjectIdentifier: Process] = [:]

    func add(_ p: Process) { lock.lock(); all[ObjectIdentifier(p)] = p; lock.unlock() }
    func remove(_ p: Process) { lock.lock(); all[ObjectIdentifier(p)] = nil; lock.unlock() }
    func terminateAll() {
        lock.lock(); let running = Array(all.values); lock.unlock()
        for p in running where p.isRunning { p.terminate() }
    }
}

public enum ProcessRunner {
    /// Stops every program that is still running. The app calls this when it quits.
    public static func terminateAll() { RunningProcesses.shared.terminateAll() }

    /// Runs a program and waits. Cancelling the surrounding task stops the program.
    /// `onLine` receives each line of standard output as it arrives.
    /// `input` is a file the program reads as its standard input, and `outputFile` a file that receives its standard output
    /// (spumux works that way). `environment` adds to the program's environment.
    public static func run(_ executable: URL, _ arguments: [String], input: URL? = nil, outputFile: URL? = nil,
                           environment: [String: String] = [:], onLine: (@Sendable (String) -> Void)? = nil) async throws -> ProcessResult {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if !environment.isEmpty { process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new } }
        let out = Pipe(), err = Pipe()
        var sink: FileHandle?
        if let outputFile {
            FileManager.default.createFile(atPath: outputFile.path, contents: nil)
            sink = try FileHandle(forWritingTo: outputFile)
            process.standardOutput = sink
        } else {
            process.standardOutput = out
        }
        defer { try? sink?.close() }
        process.standardError = err
        process.standardInput = try input.map { try FileHandle(forReadingFrom: $0) } ?? FileHandle.nullDevice
        let outBuffer = LineBuffer(), errBuffer = LineBuffer()
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { outBuffer.add(data) { onLine?($0) } }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { errBuffer.add(data) { _ in } }
        }
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    RunningProcesses.shared.remove(finished)
                    continuation.resume(returning: finished.terminationStatus)
                }
                do { RunningProcesses.shared.add(process); try process.run() } catch {
                    RunningProcesses.shared.remove(process)
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        // Bytes that arrived between the last handler call and the exit.
        if let rest = try? out.fileHandleForReading.readToEnd(), !rest.isEmpty { outBuffer.add(rest) { onLine?($0) } }
        if let rest = try? err.fileHandleForReading.readToEnd(), !rest.isEmpty { errBuffer.add(rest) { _ in } }
        try Task.checkCancellation()
        return ProcessResult(status: status, output: outBuffer.text, error: errBuffer.text)
    }
}
