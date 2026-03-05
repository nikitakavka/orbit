import Foundation
import Darwin

public struct ProcessExecutionResult {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public let durationMs: Int
}

public enum ProcessExecutionError: Error, LocalizedError {
    case launchFailed(String)
    case timedOut(command: String, timeoutSeconds: Int)
    case outputTooLarge(command: String, maxBytes: Int)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let message):
            return message
        case let .timedOut(command, timeoutSeconds):
            return "Command timed out after \(timeoutSeconds)s: \(command)"
        case let .outputTooLarge(command, maxBytes):
            return "Command output exceeded safety cap (\(maxBytes) bytes): \(command)"
        }
    }
}

public enum CommandExecutor {
    private static let defaultMaxOutputBytes = 500 * 1024 * 1024
    private static let minMaxOutputBytes = 256 * 1024
    private static let readChunkSize = 64 * 1024

    public static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        timeoutSeconds: Int? = nil,
        maxOutputBytes: Int? = nil
    ) async throws -> ProcessExecutionResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                final class BufferBox {
                    var data = Data()
                }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                if let environment {
                    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
                }

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                let start = Date()
                let commandString = ([executable] + arguments).joined(separator: " ")
                let outputLimitBytes = max(Self.minMaxOutputBytes, maxOutputBytes ?? Self.defaultMaxOutputBytes)

                let terminationSemaphore = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in
                    terminationSemaphore.signal()
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: ProcessExecutionError.launchFailed(error.localizedDescription))
                    return
                }

                let stdoutHandle = stdoutPipe.fileHandleForReading
                let stderrHandle = stderrPipe.fileHandleForReading

                let stdoutBuffer = BufferBox()
                let stderrBuffer = BufferBox()

                final class CaptureState {
                    let lock = NSLock()
                    var totalCapturedBytes = 0
                    var outputTooLargeTriggered = false
                }

                let captureState = CaptureState()

                func appendChunk(_ chunk: Data, into buffer: inout Data) -> (overflow: Bool, shouldTerminate: Bool) {
                    captureState.lock.lock()
                    defer { captureState.lock.unlock() }

                    let remaining = outputLimitBytes - captureState.totalCapturedBytes
                    if remaining <= 0 {
                        let shouldTerminate = !captureState.outputTooLargeTriggered
                        captureState.outputTooLargeTriggered = true
                        return (true, shouldTerminate)
                    }

                    if chunk.count > remaining {
                        buffer.append(chunk.prefix(remaining))
                        captureState.totalCapturedBytes += remaining
                        let shouldTerminate = !captureState.outputTooLargeTriggered
                        captureState.outputTooLargeTriggered = true
                        return (true, shouldTerminate)
                    }

                    buffer.append(chunk)
                    captureState.totalCapturedBytes += chunk.count
                    return (false, false)
                }

                let ioGroup = DispatchGroup()

                ioGroup.enter()
                DispatchQueue.global(qos: .utility).async {
                    defer { ioGroup.leave() }

                    while true {
                        guard let chunk = try? stdoutHandle.read(upToCount: Self.readChunkSize),
                              !chunk.isEmpty else {
                            break
                        }

                        let writeResult = appendChunk(chunk, into: &stdoutBuffer.data)
                        if writeResult.shouldTerminate, process.isRunning {
                            process.terminate()
                        }
                        if writeResult.overflow { break }
                    }
                }

                ioGroup.enter()
                DispatchQueue.global(qos: .utility).async {
                    defer { ioGroup.leave() }

                    while true {
                        guard let chunk = try? stderrHandle.read(upToCount: Self.readChunkSize),
                              !chunk.isEmpty else {
                            break
                        }

                        let writeResult = appendChunk(chunk, into: &stderrBuffer.data)
                        if writeResult.shouldTerminate, process.isRunning {
                            process.terminate()
                        }
                        if writeResult.overflow { break }
                    }
                }

                let timedOut: Bool
                if let timeoutSeconds, timeoutSeconds > 0 {
                    timedOut = terminationSemaphore.wait(timeout: .now() + .seconds(timeoutSeconds)) == .timedOut
                } else {
                    terminationSemaphore.wait()
                    timedOut = false
                }

                captureState.lock.lock()
                let outputTooLargeAtWait = captureState.outputTooLargeTriggered
                captureState.lock.unlock()

                if (timedOut || outputTooLargeAtWait), process.isRunning {
                    process.terminate()
                    let exitedAfterTerminate = terminationSemaphore.wait(timeout: .now() + .seconds(2)) == .success

                    if !exitedAfterTerminate, process.isRunning {
                        let pid = process.processIdentifier
                        if pid > 0 {
                            _ = kill(pid, SIGKILL)
                        }
                        _ = terminationSemaphore.wait(timeout: .now() + .seconds(2))
                    }
                }

                ioGroup.wait()

                captureState.lock.lock()
                let outputTooLarge = captureState.outputTooLargeTriggered
                captureState.lock.unlock()

                let end = Date()
                let duration = Int(end.timeIntervalSince(start) * 1000)

                let stdout = String(data: stdoutBuffer.data, encoding: .utf8) ?? ""
                let stderr = String(data: stderrBuffer.data, encoding: .utf8) ?? ""

                if outputTooLarge {
                    continuation.resume(throwing: ProcessExecutionError.outputTooLarge(command: commandString, maxBytes: outputLimitBytes))
                    return
                }

                if timedOut {
                    continuation.resume(throwing: ProcessExecutionError.timedOut(command: commandString, timeoutSeconds: timeoutSeconds ?? 0))
                    return
                }

                continuation.resume(returning: ProcessExecutionResult(
                    stdout: stdout,
                    stderr: stderr,
                    exitCode: process.terminationStatus,
                    durationMs: duration
                ))
            }
        }
    }
}
