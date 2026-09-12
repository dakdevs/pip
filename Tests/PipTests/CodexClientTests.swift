import Foundation
import XCTest
@testable import Pip

@MainActor
final class CodexClientTests: XCTestCase {
    func testHandshakeSplitResponseAndServerRequest() async throws {
        let script = try makePeer(named: "split-peer", source: """
        #!/usr/bin/python3
        import json, sys, time
        initial = json.loads(sys.stdin.readline())
        sys.stdout.write(json.dumps({"id": initial["id"], "result": {"server": "ready"}}) + "\\n")
        sys.stdout.flush()
        sys.stdin.readline()
        request = json.loads(sys.stdin.readline())
        reply = json.dumps({"id": request["id"], "result": {"value": "pong"}}) + "\\n"
        midpoint = len(reply) // 2
        sys.stdout.write(reply[:midpoint]); sys.stdout.flush(); time.sleep(0.03)
        sys.stdout.write(reply[midpoint:]); sys.stdout.flush()
        sys.stdout.write(json.dumps({"id": "approval-1", "method": "tool/requestUserInput", "params": {"prompt": "Continue?"}}) + "\\n")
        sys.stdout.flush()
        sys.stdin.readline()
        """)
        defer { try? FileManager.default.removeItem(at: script) }

        let client = CodexClient()
        client.requestTimeout = 2
        let callback = expectation(description: "server request")
        client.onServerRequest = { id, method, params in
            XCTAssertEqual(id.stringValue, "approval-1")
            XCTAssertEqual(method, "tool/requestUserInput")
            XCTAssertEqual(params["prompt"]?.stringValue, "Continue?")
            client.respond(id: id, result: .object(["answer": .string("yes")]))
            callback.fulfill()
        }

        try await client.start(executable: script.path)
        let result = try await client.request("ping")
        XCTAssertEqual(result["value"]?.stringValue, "pong")
        await fulfillment(of: [callback], timeout: 2)
        client.stop()
    }

    func testDisconnectFailsPendingRequestAndNotifiesOwner() async throws {
        let script = try makePeer(named: "disconnect-peer", source: """
        #!/usr/bin/python3
        import json, sys
        initial = json.loads(sys.stdin.readline())
        sys.stdout.write(json.dumps({"id": initial["id"], "result": {}}) + "\\n")
        sys.stdout.flush()
        sys.stdin.readline()
        sys.stdin.readline()
        """)
        defer { try? FileManager.default.removeItem(at: script) }

        let client = CodexClient()
        client.requestTimeout = 2
        let disconnected = expectation(description: "disconnect callback")
        client.onDisconnect = { _ in disconnected.fulfill() }
        try await client.start(executable: script.path)

        do {
            _ = try await client.request("willDisconnect")
            XCTFail("Expected subprocess exit to fail the request")
        } catch let error as CodexClientError {
            guard case .processExited = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        await fulfillment(of: [disconnected], timeout: 2)
    }

    private func makePeer(named name: String, source: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pip-\(name)-\(UUID().uuidString).py")
        try source.data(using: .utf8)!.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}
