import Foundation
import XCTest
@testable import Pip

@MainActor
final class ConversationStateTests: XCTestCase {
    private var defaults: UserDefaults!
    private var defaultsSuite: String!
    private var historyURL: URL!

    override func setUp() {
        super.setUp()
        defaultsSuite = "PipTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)!
        historyURL = FileManager.default.temporaryDirectory.appendingPathComponent("pip-history-\(UUID().uuidString).json")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuite)
        try? FileManager.default.removeItem(at: historyURL)
        super.tearDown()
    }

    func testNewConversationLeavesRunningWorkInBackground() {
        let store = makeStore()
        store.show()
        let first = try! XCTUnwrap(store.activeID)
        store.update(first) { $0.messages = [Message(role: "user", text: "Work")]; $0.state = .running }

        store.newConversation()

        XCTAssertNotEqual(store.activeID, first)
        XCTAssertEqual(store.conversations.first(where: { $0.id == first })?.state, .running)
        XCTAssertEqual(store.conversations.count, 2)
    }

    func testEscapeMinimizesWorkingConversationAndEndsCompletedOne() {
        let store = makeStore()
        store.show()
        let id = try! XCTUnwrap(store.activeID)
        store.update(id) { $0.messages = [Message(role: "user", text: "Work")]; $0.state = .running }
        store.escape()
        XCTAssertEqual(store.activeID, id)
        assertLocation(store.location, is: .corner)

        store.show()
        store.update(id) { $0.state = .complete }
        store.escape()
        XCTAssertNil(store.activeID)
        assertLocation(store.location, is: .hidden)
    }

    func testHistorySelectionRestoresExistingConversation() {
        let store = makeStore()
        var older = Conversation()
        older.messages = [Message(role: "user", text: "Older")]
        older.updated = Date(timeIntervalSince1970: 1)
        var newer = Conversation()
        newer.messages = [Message(role: "user", text: "Newer")]
        newer.updated = Date()
        store.conversations = [older, newer]
        store.activeID = newer.id
        store.draft = ""

        store.historyMove(-1)
        XCTAssertTrue(store.historyVisible)
        store.submit()

        XCTAssertEqual(store.activeID, newer.id)
        XCTAssertFalse(store.historyVisible)
        assertLocation(store.location, is: .center)
    }

    func testFirstTurnDismissalEligibilityRequiresSuccessfulToolAction() {
        var conversation = Conversation()
        conversation.state = .complete
        conversation.userMessageCount = 1
        conversation.usedTools = true
        conversation.messages = [Message(role: "assistant", text: "Done", isFinal: true)]
        XCTAssertTrue(conversation.eligibleForDismissal)

        conversation.toolFailed = true
        XCTAssertFalse(conversation.eligibleForDismissal)
        conversation.toolFailed = false
        conversation.userMessageCount = 2
        XCTAssertFalse(conversation.eligibleForDismissal)
    }

    func testGlobalPreferencesSurviveThreadSwitching() {
        let store = makeStore()
        var first = Conversation(); first.messages = [Message(role: "user", text: "First")]
        var second = Conversation(); second.messages = [Message(role: "user", text: "Second")]
        store.conversations = [first, second]
        store.activeID = first.id
        store.preferences.fast = true
        store.preferences.reasoning = "high"

        store.select(second.id)

        XCTAssertTrue(store.preferences.fast)
        XCTAssertEqual(store.preferences.reasoning, "high")
        XCTAssertEqual(store.activeID, second.id)
    }

    func testWaitingRequestStaysAssociatedWhenStartingNewConversation() {
        let store = makeStore()
        var conversation = Conversation()
        conversation.threadID = "thread-1"
        conversation.messages = [Message(role: "user", text: "Need access")]
        conversation.state = .running
        store.conversations = [conversation]
        store.activeID = conversation.id
        store.serverRequest(
            id: .string("request-1"),
            method: "item/tool/requestUserInput",
            params: .object([
                "threadId": .string("thread-1"), "turnId": .string("turn-1"), "itemId": .string("item-1"),
                "isBlocking": .bool(true), "questions": .array([])
            ])
        )

        store.newConversation()

        XCTAssertEqual(store.requests.count, 1)
        XCTAssertEqual(store.requests.first?.conversationID, conversation.id)
        XCTAssertEqual(store.conversations.first(where: { $0.id == conversation.id })?.state, .waiting)
    }

    private func makeStore() -> AppStore { AppStore(defaults: defaults, historyURL: historyURL) }

    private func assertLocation(_ actual: PanelLocation, is expected: PanelLocation, file: StaticString = #filePath, line: UInt = #line) {
        switch (actual, expected) {
        case (.hidden, .hidden), (.center, .center), (.corner, .corner): break
        default: XCTFail("Unexpected panel location", file: file, line: line)
        }
    }
}
