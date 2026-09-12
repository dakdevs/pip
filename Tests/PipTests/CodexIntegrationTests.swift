import XCTest
@testable import Pip

@MainActor final class CodexIntegrationTests: XCTestCase {
    func testAppStoreSubmissionStreamsRealReply() async throws {
        guard ProcessInfo.processInfo.environment["PIP_TEST_CODEX"] == "1" else { throw XCTSkip("Set PIP_TEST_CODEX=1 for a real Pip submission.") }
        let suite = "PipIntegration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let history = FileManager.default.temporaryDirectory.appendingPathComponent("\(suite).json")
        let store = AppStore(defaults: defaults, historyURL: history)
        defer { store.client.stop(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: history) }
        await store.connect()
        XCTAssertTrue(store.connected, store.connectionError ?? "Not connected")
        XCTAssertTrue(store.signedIn)
        let model = try XCTUnwrap(store.models.first { $0.id.contains("luna") } ?? store.models.first)
        store.preferences.model = model.id
        store.preferences.reasoning = model.efforts.first ?? "low"
        store.preferences.fast = false
        store.preferences.autoDismiss = false
        store.newConversation()
        store.draft = "Reply with exactly: Pip is ready. Do not use any tools."
        store.submit()
        let deadline = ContinuousClock.now + .seconds(90)
        while store.active?.state.isWorking == true, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(store.active?.state, .complete, store.active?.error ?? "Turn did not finish")
        XCTAssertTrue(store.active?.lastReply.contains("Pip is ready.") == true, store.active?.lastReply ?? "No response")
    }

    func testSubscriptionTurnAndCompletionClassifier() async throws {
        guard ProcessInfo.processInfo.environment["PIP_TEST_CODEX"] == "1" else { throw XCTSkip("Set PIP_TEST_CODEX=1 for a small real Codex subscription test.") }
        let client = CodexClient(); client.requestTimeout = 60
        defer { client.stop() }
        try await client.start(executable: PipPaths.codexExecutable)
        let account = try await client.request("account/read")
        XCTAssertEqual(account["account"]?["type"]?.s, "chatgpt")
        let models = try await client.request("model/list")
        let options = models["data"]?.a.compactMap(ModelOption.init) ?? []
        let model = try XCTUnwrap(options.first { $0.id.contains("luna") } ?? options.first)
        let config = try await client.request("config/read", params: .object(["includeLayers": .bool(false)]))
        // Two tiny classification turns exercise authentication, model selection,
        // structured output, streamed completion, and conservative visibility.
        let classifier = CompletionClassifier(timeout: .seconds(60))
        let keepAnswer = try await classifier.shouldDismiss(request: "What is two plus two?", response: "Four.", model: model.id, effort: model.efforts.first ?? "low", fast: false, executable: PipPaths.codexExecutable, config: config["config"] ?? .object([:]))
        XCTAssertFalse(keepAnswer)
        let dismissAction = try await classifier.shouldDismiss(request: "Open Safari.", response: "Opened Safari.", model: model.id, effort: model.efforts.first ?? "low", fast: model.supportsFast, executable: PipPaths.codexExecutable, config: config["config"] ?? .object([:]))
        XCTAssertTrue(dismissAction)
    }
}
