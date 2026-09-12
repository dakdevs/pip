import Foundation

public enum CodexClientError: LocalizedError, Sendable {
    case notRunning
    case processExited(status: Int32, stderr: String)
    case invalidMessage
    case server(code: Int?, message: String)
    case cancelled
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .notRunning: return "Codex app-server is not running."
        case .processExited(let status, let stderr):
            return stderr.isEmpty ? "Codex app-server exited (status \(status))." : "Codex app-server exited (status \(status)): \(stderr)"
        case .invalidMessage: return "Codex app-server sent an invalid JSON-RPC message."
        case .server(let code, let message):
            return code.map { "Codex app-server error \($0): \(message)" } ?? "Codex app-server error: \(message)"
        case .cancelled: return "The Codex request was cancelled."
        case .timedOut: return "The Codex request timed out."
        }
    }
}

/// A line-delimited JSON-RPC client for `codex app-server`.
@MainActor
public final class CodexClient {
    public var onNotification: ((String, JSONValue) -> Void)?
    public var onServerRequest: ((JSONValue, String, JSONValue) -> Void)?
    /// Called when the app-server exits unexpectedly. It is not called by `stop()`.
    public var onDisconnect: ((String) -> Void)?
    /// Individual JSON-RPC requests are bounded so a dead peer cannot leave UI
    /// state permanently running. Callers can increase this for long operations.
    public var requestTimeout: TimeInterval = 30

    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private var stderr: FileHandle?
    private var stdoutBuffer = Data()
    private var stderrTail = Data()
    private var nextRequestID: Int = 1
    private struct PendingRequest {
        let continuation: CheckedContinuation<JSONValue, Error>
        let timeout: Task<Void, Never>
    }
    private var pending: [String: PendingRequest] = [:]
    private var didFinish = false
    private var connectionGeneration = 0

    public init() {}

    /// Starts the server, performs the required initialize handshake, then
    /// advertises that this client is ready for notifications.
    public func start(executable: String = "/usr/bin/env", arguments: [String] = []) async throws {
        stop()
        connectionGeneration += 1
        let generation = connectionGeneration
        didFinish = false
        stdoutBuffer.removeAll(keepingCapacity: true)
        stderrTail.removeAll(keepingCapacity: true)

        let newProcess = Process()
        if executable == "/usr/bin/env" {
            newProcess.executableURL = URL(fileURLWithPath: executable)
            newProcess.arguments = ["codex", "app-server"] + arguments
        } else {
            newProcess.executableURL = URL(fileURLWithPath: executable)
            newProcess.arguments = ["app-server"] + arguments
        }
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        newProcess.standardInput = input
        newProcess.standardOutput = output
        newProcess.standardError = errors

        var environment = ProcessInfo.processInfo.environment
        let extraPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        environment["PATH"] = [extraPath, environment["PATH"]].compactMap { $0 }.joined(separator: ":")
        newProcess.environment = environment

        newProcess.terminationHandler = { [weak self] process in
            Task { @MainActor in self?.finish(status: process.terminationStatus, generation: generation) }
        }
        try newProcess.run()

        process = newProcess
        stdin = input.fileHandleForWriting
        stdout = output.fileHandleForReading
        stderr = errors.fileHandleForReading
        installReaders(generation: generation)

        _ = try await request("initialize", params: .object([
            "clientInfo": .object([
                "name": .string("pip"),
                "version": .string("1.0")
            ]),
            "capabilities": .object([
                "experimentalApi": .bool(true),
                "mcpServerOpenaiFormElicitation": .bool(true),
                "extensions": .object(["openai/form": .object([:])])
            ])
        ]))
        try send(.object(["method": .string("initialized")]))
    }

    public func request(_ method: String, params: JSONValue = .object([:])) async throws -> JSONValue {
        guard process?.isRunning == true, !didFinish else { throw CodexClientError.notRunning }
        let id = JSONValue.number(Double(nextRequestID))
        nextRequestID += 1
        let key = requestKey(id)
        let message: JSONValue = .object([
            "id": id,
            "method": .string(method),
            "params": params
        ])

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let timeout = Task { @MainActor [weak self] in
                    guard let self else { return }
                    let nanoseconds = UInt64(max(0, self.requestTimeout) * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: nanoseconds)
                    guard !Task.isCancelled else { return }
                    self.timeoutRequest(key)
                }
                pending[key] = PendingRequest(continuation: continuation, timeout: timeout)
                do { try send(message) }
                catch {
                    pending.removeValue(forKey: key)?.timeout.cancel()
                    continuation.resume(throwing: error)
                }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.cancelRequest(key) }
        })
    }

    /// Responds to a server-to-client request. The caller chooses the protocol
    /// result so approval and user-input UX can remain outside the transport.
    public func respond(id: JSONValue, result: JSONValue) {
        guard process?.isRunning == true, !didFinish else { return }
        try? send(.object(["id": id, "result": result]))
    }

    /// Returns a JSON-RPC error for a server request the application cannot
    /// safely handle. This keeps unsupported approvals from timing out silently.
    public func respondError(id: JSONValue, code: Int, message: String) {
        guard process?.isRunning == true, !didFinish else { return }
        try? send(.object([
            "id": id,
            "error": .object(["code": .number(Double(code)), "message": .string(message)])
        ]))
    }

    public func stop() {
        guard process != nil || !pending.isEmpty else { return }
        stdout?.readabilityHandler = nil
        stderr?.readabilityHandler = nil
        let activeProcess = process
        process = nil
        stdin = nil
        stdout = nil
        stderr = nil
        didFinish = true
        failPending(CodexClientError.cancelled)
        if activeProcess?.isRunning == true { activeProcess?.terminate() }
    }

    private func installReaders(generation: Int) {
        stdout?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in self?.consumeStdout(data, generation: generation) }
        }
        stderr?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in self?.consumeStderr(data, generation: generation) }
        }
    }

    private func consumeStdout(_ data: Data, generation: Int) {
        guard generation == connectionGeneration else { return }
        // EOF can precede the Process termination callback. That callback is
        // authoritative for the exit status and will fail outstanding work.
        guard !data.isEmpty else { return }
        stdoutBuffer.append(data)
        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            let line = stdoutBuffer.prefix(upTo: newline)
            stdoutBuffer.removeSubrange(...newline)
            let trimmed = line.last == 0x0D ? line.dropLast() : line[...]
            guard !trimmed.isEmpty else { continue }
            handleMessage(Data(trimmed))
        }
    }

    private func consumeStderr(_ data: Data, generation: Int) {
        guard generation == connectionGeneration else { return }
        guard !data.isEmpty else { return }
        stderrTail.append(data)
        let maximumTail = 8_192
        if stderrTail.count > maximumTail { stderrTail.removeFirst(stderrTail.count - maximumTail) }
    }

    private func handleMessage(_ data: Data) {
        guard let message = try? decoder.decode(JSONValue.self, from: data),
              let object = message.objectValue else { return }
        if let id = object["id"] {
            let key = requestKey(id)
            if let request = pending.removeValue(forKey: key) {
                request.timeout.cancel()
                if let error = object["error"]?.objectValue {
                    request.continuation.resume(throwing: CodexClientError.server(
                        code: error["code"]?.intValue,
                        message: error["message"]?.stringValue ?? "Unknown error"
                    ))
                } else if let result = object["result"] {
                    request.continuation.resume(returning: result)
                } else {
                    request.continuation.resume(throwing: CodexClientError.invalidMessage)
                }
            } else if let method = object["method"]?.stringValue {
                onServerRequest?(id, method, object["params"] ?? .object([:]))
            }
        } else if let method = object["method"]?.stringValue {
            onNotification?(method, object["params"] ?? .object([:]))
        }
    }

    private func send(_ message: JSONValue) throws {
        guard let stdin, process?.isRunning == true else { throw CodexClientError.notRunning }
        var data = try encoder.encode(message)
        data.append(0x0A)
        try stdin.write(contentsOf: data)
    }

    private func cancelRequest(_ key: String) {
        guard let request = pending.removeValue(forKey: key) else { return }
        request.timeout.cancel()
        request.continuation.resume(throwing: CodexClientError.cancelled)
    }

    private func timeoutRequest(_ key: String) {
        guard let request = pending.removeValue(forKey: key) else { return }
        request.timeout.cancel()
        request.continuation.resume(throwing: CodexClientError.timedOut)
    }

    private func finish(status: Int32, generation: Int) {
        guard generation == connectionGeneration, !didFinish else { return }
        didFinish = true
        stdout?.readabilityHandler = nil
        stderr?.readabilityHandler = nil
        let tail = sanitizedStderr(stderrTail)
        failPending(CodexClientError.processExited(status: status, stderr: tail))
        onDisconnect?(tail.isEmpty ? "Codex app-server exited (status \(status))." : tail)
    }

    private func failPending(_ error: Error) {
        let continuations = pending.values
        pending.removeAll()
        continuations.forEach {
            $0.timeout.cancel()
            $0.continuation.resume(throwing: error)
        }
    }

    private func requestKey(_ id: JSONValue) -> String {
        switch id {
        case .string(let value): return "s:\(value)"
        case .number(let value): return "n:\(value)"
        default: return "invalid"
        }
    }

    /// Stderr is only included to make a launch failure diagnosable. Redact
    /// common credential forms before it can reach UI or application logs.
    private func sanitizedStderr(_ data: Data) -> String {
        var text = String(decoding: data, as: UTF8.self)
            .unicodeScalars
            .filter { $0.properties.isWhitespace || $0.value >= 0x20 }
            .map(String.init)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = "(?i)(authorization|api[_-]?key|token|password)\\s*[:=]\\s*[^\\s]+"
        text = text.replacingOccurrences(of: pattern, with: "$1=<redacted>", options: String.CompareOptions.regularExpression)
        return text
    }
}
