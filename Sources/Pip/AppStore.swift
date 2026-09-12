import AppKit
import Observation

@MainActor @Observable
final class AppStore {
    var preferences: Preferences { didSet { savePreferences() } }
    var conversations: [Conversation] = []
    var activeID: UUID?
    var location: PanelLocation = .hidden
    var historyVisible = false
    var historyIndex = 0
    var models: [ModelOption] = []
    var connected = false
    var connecting = false
    var accountLabel = "Not connected"
    var signedIn = false
    var connectionError: String?
    var shortcutError: String?
    var requests: [PendingRequest] = []
    var focusRevision = 0
    var pluginStatus = "Checking Codex tools…"
    var classifierStatus: String?
    var voiceError: String?
    var sourceApplication: String?
    let client = CodexClient()
    let dictation = DictationService()
    @ObservationIgnored var onPresentationChange: (() -> Void)?
    @ObservationIgnored var onSettingsChange: (() -> Void)?
    @ObservationIgnored var onMenuChange: (() -> Void)?
    @ObservationIgnored private var sends: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var loadedThreads = Set<String>()
    @ObservationIgnored private var classifierConfiguration: JSONValue = .object([:])
    @ObservationIgnored private var voiceGeneration = 0
    @ObservationIgnored private var voiceStarting = false
    @ObservationIgnored private var voiceTarget: UUID?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let historyURL: URL

    init(defaults: UserDefaults = .standard, historyURL: URL = PipPaths.support.appendingPathComponent("history.json")) {
        self.defaults = defaults; self.historyURL = historyURL
        if let data = defaults.data(forKey: "PipPreferences"), let prefs = try? JSONDecoder().decode(Preferences.self, from: data) { preferences = prefs }
        else { preferences = Preferences() }
        if preferences.codexPath.isEmpty { preferences.codexPath = PipPaths.codexExecutable }
        if preferences.workingDirectory.isEmpty { preferences.workingDirectory = PipPaths.workspace.path }
        let url = historyURL
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([Conversation].self, from: data) {
            conversations = saved.map { original in
                var c = original
                if c.state.isWorking { c.state = .stopped; c.activity = "Interrupted when Pip closed"; c.turnID = nil }
                return c
            }
        }
        client.onNotification = { [weak self] method, params in self?.notification(method, params) }
        client.onServerRequest = { [weak self] id, method, params in self?.serverRequest(id: id, method: method, params: params) }
        client.onDisconnect = { [weak self] reason in
            guard let self else { return }
            self.connected = false; self.connectionError = reason; self.loadedThreads.removeAll()
            for i in self.conversations.indices where self.conversations[i].state.isWorking {
                self.conversations[i].state = .stopped; self.conversations[i].turnID = nil; self.conversations[i].error = "Connection to Codex ended. Reconnect to continue."
            }
            self.requests.removeAll()
            self.changed(); self.persist()
        }
    }

    var active: Conversation? { conversations.first { $0.id == activeID } }
    var history: [Conversation] { conversations.filter { !$0.messages.isEmpty || !$0.draft.isEmpty }.sorted { $0.updated > $1.updated } }
    var selectedModel: ModelOption? { models.first { $0.id == preferences.model } }
    var activeRequests: [PendingRequest] { requests.filter { $0.conversationID == activeID } }
    var draft: String {
        get { active?.draft ?? "" }
        set { ensureConversation(); update(activeID!) { $0.draft = newValue }; if !newValue.isEmpty { historyVisible = false } }
    }
    var voiceBusy: Bool { voiceStarting || dictation.isRecording || dictation.isTranscribing }
    var busyCount: Int { conversations.filter { $0.state.isWorking }.count }

    func update(_ id: UUID, _ change: (inout Conversation) -> Void) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        change(&conversations[index])
    }
    func ensureConversation() {
        if active == nil { let c = Conversation(); conversations.append(c); activeID = c.id }
    }
    func show() {
        ensureConversation(); location = .center
        if let id = activeID { update(id) { $0.unread = false } }
        focusRevision += 1; changed()
    }
    func newConversation() {
        cancelVoice()
        if let current = active, current.messages.isEmpty && current.draft.isEmpty { show(); return }
        let c = Conversation(); conversations.append(c); activeID = c.id
        historyVisible = false; show(); persist()
    }
    func minimize() {
        guard location == .center else { return }
        if voiceBusy { cancelVoice() }
        historyVisible = false
        if active?.messages.isEmpty == true && draft.isEmpty { location = .hidden }
        else { location = .corner }
        changed(); persist()
    }
    func escape() {
        if voiceBusy { cancelVoice(); return }
        if historyVisible { historyVisible = false; focusRevision += 1; changed(); return }
        if active?.state.isWorking == true { minimize() } else { endConversation() }
    }
    func endConversation() {
        if active?.state.isWorking == true { minimize(); return }
        activeID = nil; location = .hidden; historyVisible = false; changed(); persist()
    }
    func select(_ id: UUID) {
        cancelVoice(); activeID = id; historyVisible = false; show()
        Task { await loadConversation(id) }
    }
    func historyMove(_ direction: Int) {
        guard draft.isEmpty, !history.isEmpty else { return }
        if !historyVisible { historyVisible = true; historyIndex = 0 }
        else { historyIndex = min(max(0, historyIndex + direction), history.count - 1) }
        changed()
    }
    func stepReasoning(_ direction: Int) {
        guard let model = selectedModel, !model.efforts.isEmpty else { return }
        let index = model.efforts.firstIndex(of: preferences.reasoning) ?? 0
        preferences.reasoning = model.efforts[min(max(0, index + direction), model.efforts.count - 1)]
    }
    func toggleFast() { if selectedModel?.supportsFast == true { preferences.fast.toggle() } }
    func validateModel() {
        guard let model = selectedModel else { return }
        if !model.efforts.contains(preferences.reasoning) { preferences.reasoning = model.defaultEffort }
    }
    func changed() { onPresentationChange?(); onMenuChange?() }
    func savePreferences() {
        if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: "PipPreferences") }
        onSettingsChange?()
    }
    func persist() {
        do {
            let url = historyURL
            try JSONEncoder().encode(conversations.filter { !$0.messages.isEmpty || !$0.draft.isEmpty }).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { connectionError = "History could not be saved: \(error.localizedDescription)" }
        onMenuChange?()
    }

    func connect() async {
        guard !connecting else { return }
        connecting = true; connected = false; connectionError = nil
        defer { connecting = false; changed() }
        do {
            guard !preferences.codexPath.isEmpty else { throw PipError.message("Choose a Codex executable in Settings. Install Codex first if needed.") }
            try await client.start(executable: preferences.codexPath)
            connected = true; loadedThreads.removeAll()
            await refreshAccount()
            let result = try await client.request("model/list")
            models = (result["data"]?.a ?? []).filter { $0["hidden"]?.boolValue != true }.compactMap(ModelOption.init)
            if !models.contains(where: { $0.id == preferences.model }) { preferences.model = models.first(where: \.isDefault)?.id ?? models.first?.id ?? "" }
            validateModel()
            if preferences.classifierModel.isEmpty { preferences.classifierModel = models.first { $0.id.localizedCaseInsensitiveContains("luna") }?.id ?? "" }
            let config = try await client.request("config/read", params: .object(["includeLayers": .bool(false)]))
            let namesOnly: (JSONValue?) -> JSONValue = { value in .object(Dictionary(uniqueKeysWithValues: (value?.objectValue ?? [:]).keys.map { ($0, .null) })) }
            classifierConfiguration = .object(["plugins": namesOnly(config["config"]?["plugins"]), "mcp_servers": namesOnly(config["config"]?["mcp_servers"])])
            Task { await refreshPlugins() }
        } catch { connectionError = error.localizedDescription; connected = false }
    }
    func refreshAccount() async {
        do {
            let result = try await client.request("account/read")
            let account = result["account"]
            signedIn = account?["type"]?.s == "chatgpt"
            accountLabel = signedIn ? "Codex · \(account?["planType"]?.s.capitalized ?? "Signed in")" : "Sign in with ChatGPT"
        } catch { connectionError = error.localizedDescription }
    }
    func signIn() async {
        do {
            if !connected { await connect() }
            let result = try await client.request("account/login/start", params: .object(["type": .string("chatgpt")]))
            if let raw = result["authUrl"]?.stringValue, let url = URL(string: raw), ["https","http"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
        } catch { connectionError = error.localizedDescription }
    }
    func refreshPlugins() async {
        do {
            let result = try await client.request("mcpServerStatus/list", params: .object(["limit": .number(100)]))
            let entries = result["data"]?.a ?? []
            let names = entries.compactMap { $0["name"]?.stringValue }
            let computer = names.filter { $0.localizedCaseInsensitiveContains("computer") || $0.localizedCaseInsensitiveContains("cua") }
            pluginStatus = computer.isEmpty ? "No computer-use server reported. Enable the computer-use plugin in Codex, then reconnect." : "Computer-use servers: " + computer.joined(separator: ", ") + ". Access is requested when a task uses them."
        } catch { pluginStatus = "Tool inventory unavailable: \(error.localizedDescription). Existing Codex configuration is inherited." }
    }
    func threadParams() -> [String: JSONValue] {
        ["model": .string(preferences.model), "cwd": .string(preferences.workingDirectory),
         "approvalPolicy": .string(preferences.fullAccess ? "never" : "on-request"),
         "sandbox": .string(preferences.fullAccess ? "danger-full-access" : "workspace-write"),
         "developerInstructions": .string("You are Pip, an ambient macOS assistant powered by Codex. Use available Codex tools naturally to complete requests, including computer use for inspecting relevant windows when requested. Do not claim you saw a window without inspecting it. Be concise. For a completed action, briefly state the outcome. For informational requests, provide the useful findings. Ask for necessary clarification or access using available tools. The UI can minimize without ending your work. The app remembered which application was frontmost when invoked; when supplied, treat that as a window-selection hint, not as inspected content.")]
    }
    func loadConversation(_ id: UUID) async {
        guard let c = conversations.first(where: { $0.id == id }), let threadID = c.threadID, !loadedThreads.contains(threadID), connected else { return }
        do {
            var params = threadParams(); params["threadId"] = .string(threadID)
            let result = try await client.request("thread/resume", params: .object(params))
            if let turns = result["thread"]?["turns"]?.arrayValue {
                let messages = Self.messages(from: turns)
                if !messages.isEmpty {
                    update(id) { conversation in
                        // A submission may be queued while resume is in flight.
                        // It is not part of Codex's transcript until turn/start.
                        let pending = conversation.state == .starting && conversation.turnID == nil ? conversation.messages.last(where: { $0.role == "user" }) : nil
                        conversation.messages = messages
                        if let pending { conversation.messages.append(pending) }
                        conversation.userMessageCount = max(conversation.userMessageCount, conversation.messages.filter { $0.role == "user" }.count)
                    }
                }
            }
            loadedThreads.insert(threadID)
        } catch { update(id) { $0.error = error.localizedDescription; $0.state = .failed }; changed() }
    }
    func submit() {
        if historyVisible {
            let list = history; if list.indices.contains(historyIndex) { select(list[historyIndex].id) }; return
        }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        ensureConversation(); guard let id = activeID else { return }
        guard connected && signedIn else { connectionError = "Connect and sign in to Codex in Settings first."; return }
        update(id) {
            $0.messages.append(Message(role: "user", text: text)); $0.draft = ""; $0.userMessageCount += 1
            if $0.title == "New conversation" { $0.title = String(text.prefix(72)) }
            if !$0.state.isWorking { $0.state = .starting; $0.toolFailed = false; $0.usedTools = false }
            $0.error = nil; $0.updated = Date()
        }
        persist(); changed()
        let previous = sends[id]
        sends[id] = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.send(text, to: id)
        }
    }
    private func send(_ text: String, to id: UUID) async {
        do {
            guard var c = conversations.first(where: { $0.id == id }) else { return }
            let threadID: String
            if let existing = c.threadID {
                threadID = existing; await loadConversation(id)
                guard loadedThreads.contains(existing) else { throw PipError.message("Could not restore this conversation. Try again after reconnecting.") }
            } else {
                let result = try await client.request("thread/start", params: .object(threadParams()))
                guard let value = result["thread"]?["id"]?.stringValue else { throw PipError.message("Codex did not return a conversation ID.") }
                threadID = value; loadedThreads.insert(value); update(id) { $0.threadID = value }
            }
            c = conversations.first { $0.id == id }!
            let input: JSONValue = .array([.object(["type": .string("text"), "text": .string(text), "text_elements": .array([])])])
            if let turnID = c.turnID, c.state.isWorking {
                _ = try await client.request("turn/steer", params: .object(["threadId": .string(threadID), "expectedTurnId": .string(turnID), "input": input]))
            } else {
                let result = try await client.request("turn/start", params: .object([
                    "threadId": .string(threadID), "input": input, "model": .string(preferences.model),
                    "effort": .string(preferences.reasoning), "serviceTier": preferences.fast && selectedModel?.supportsFast == true ? .string("priority") : .string("default"),
                    "approvalPolicy": .string(preferences.fullAccess ? "never" : "on-request"),
                    "cwd": .string(preferences.workingDirectory),
                    "sandboxPolicy": preferences.fullAccess ? .object(["type": .string("dangerFullAccess")]) : .object(["type": .string("workspaceWrite"), "writableRoots": .array([.string(preferences.workingDirectory)])]),
                    "additionalContext": .object(["pip-foreground": .object(["kind": .string("application"), "value": .string("The application in front when Pip was invoked was \(sourceApplication ?? "unknown"). This is only an application-selection hint. Inspect it with tools if the user refers to its content.")])])
                ]))
                // A very fast turn may finish before this RPC response reaches the UI.
                if conversations.first(where: { $0.id == id })?.state == .starting {
                    update(id) { $0.turnID = result["turn"]?["id"]?.stringValue; $0.state = .running }
                }
            }
        } catch {
            update(id) { $0.error = error.localizedDescription; if $0.turnID == nil { $0.state = .failed }; $0.draft = text }
        }
        changed(); persist()
    }
    func stopActive() {
        guard let c = active, let thread = c.threadID, let turn = c.turnID else { return }
        Task {
            do { _ = try await client.request("turn/interrupt", params: .object(["threadId": .string(thread), "turnId": .string(turn)])) }
            catch { update(c.id) { $0.error = error.localizedDescription }; changed() }
        }
    }

    func notification(_ method: String, _ params: JSONValue) {
        if method == "account/login/completed" || method == "account/updated" { Task { await refreshAccount() }; return }
        guard let threadID = params["threadId"]?.stringValue else { return }
        guard let id = conversations.first(where: { $0.threadID == threadID })?.id else { return }
        switch method {
        case "turn/started":
            update(id) { $0.turnID = params["turn"]?["id"]?.stringValue; $0.state = .running; $0.activity = "Thinking" }
        case "item/agentMessage/delta":
            let itemID = params["itemId"]?.s ?? "response"
            update(id) { c in
                if let i = c.messages.firstIndex(where: { $0.id == itemID }) { c.messages[i].text += params["delta"]?.s ?? "" }
                else { c.messages.append(Message(id: itemID, role: "assistant", text: params["delta"]?.s ?? "")) }
            }
        case "item/started", "item/completed":
            guard let item = params["item"] else { break }
            let type = item["type"]?.s ?? ""
            if type == "agentMessage" && method == "item/completed" {
                let itemID = item["id"]?.s ?? UUID().uuidString
                update(id) { c in
                    let message = Message(id: itemID, role: "assistant", text: item["text"]?.s ?? "", isFinal: item["phase"]?.s != "commentary")
                    if let index = c.messages.firstIndex(where: { $0.id == itemID }) { c.messages[index] = message }
                    else { c.messages.append(message) }
                }
            } else if !["userMessage", "reasoning", "agentMessage", "plan"].contains(type) {
                update(id) {
                    $0.usedTools = true
                    $0.activity = activityLabel(type, item: item)
                    if item["status"]?.s == "failed" || item["error"] != nil && item["error"] != .null { $0.toolFailed = true }
                }
            }
        case "turn/completed":
            let status = params["turn"]?["status"]?.s ?? "failed"
            update(id) {
                $0.turnID = nil; $0.updated = Date(); $0.activity = ""
                $0.state = status == "completed" ? .complete : status == "interrupted" ? .stopped : .failed
                $0.error = params["turn"]?["error"]?["message"]?.stringValue
                $0.unread = id != activeID || location != .center
            }
            requests.removeAll { $0.conversationID == id }
            persist()
            if preferences.autoDismiss { Task { await classifyCompletion(id) } }
        case "error":
            update(id) { $0.error = params["error"]?["message"]?.s ?? "Codex encountered an error."; $0.toolFailed = true }
        default: break
        }
        changed()
    }
    func serverRequest(id: JSONValue, method: String, params: JSONValue) {
        let supported = ["item/tool/requestUserInput", "mcpServer/elicitation/request", "item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/permissions/requestApproval"]
        guard supported.contains(method) else {
            client.respondError(id: id, code: -32601, message: "Pip does not support this server request: \(method)")
            connectionError = "Codex requested an unsupported capability (\(method))."
            changed(); return
        }
        let thread = params["threadId"]?.s
        let conversationID = conversations.first { $0.threadID == thread }?.id
        let request = PendingRequest(rpcID: id, method: method, params: params, conversationID: conversationID)
        requests.append(request)
        if let conversationID { update(conversationID) { if params["isBlocking"]?.boolValue != false { $0.state = .waiting }; $0.unread = true } }
        changed()
    }
    func resolve(_ request: PendingRequest, result: JSONValue) {
        client.respond(id: request.rpcID, result: result)
        requests.removeAll { $0.id == request.id }
        if let id = request.conversationID, !requests.contains(where: { $0.conversationID == id }) { update(id) { if $0.state == .waiting { $0.state = .running } } }
        changed()
    }

    private func classifyCompletion(_ id: UUID) async {
        guard connected, let c = conversations.first(where: { $0.id == id }), c.eligibleForDismissal,
              let classifier = models.first(where: { $0.id == preferences.classifierModel }) else { return }
        do {
            let dismiss = try await CompletionClassifier().shouldDismiss(
                request: c.messages.first(where: { $0.role == "user" })?.text ?? "", response: c.lastReply,
                model: classifier.id, effort: classifier.efforts.first ?? classifier.defaultEffort,
                fast: classifier.supportsFast, executable: preferences.codexPath, config: classifierConfiguration)
            guard dismiss, preferences.autoDismiss,
                  let current = conversations.first(where: { $0.id == id }), current.eligibleForDismissal,
                  current.draft.isEmpty, current.updated == c.updated else { return }
            if activeID == id && !voiceBusy { endConversation() }
            else { update(id) { $0.unread = false }; persist(); changed() }
        } catch { classifierStatus = "Kept response visible: \(error.localizedDescription)" }
    }

    func beginVoice() {
        guard !voiceBusy else { return }
        ensureConversation(); voiceTarget = activeID; voiceGeneration += 1
        let generation = voiceGeneration; voiceStarting = true; voiceError = nil
        Task {
            do {
                try await dictation.start()
                guard generation == voiceGeneration else { dictation.cancel(); return }
                voiceStarting = false; changed()
            } catch { if generation == voiceGeneration { voiceStarting = false; voiceError = error.localizedDescription; changed() } }
        }
    }
    func finishVoice() {
        if voiceStarting { cancelVoice(); return }
        guard dictation.isRecording else { return }
        let generation = voiceGeneration; let target = voiceTarget
        Task {
            do {
                let text = try await dictation.finish()
                guard generation == voiceGeneration, activeID == target, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                draft = draft.isEmpty ? text : draft + " " + text
                if preferences.autoSubmit { submit() }
            } catch { if generation == voiceGeneration { voiceError = error.localizedDescription } }
            changed()
        }
    }
    func cancelVoice() { voiceGeneration += 1; voiceStarting = false; dictation.cancel(); voiceTarget = nil; changed() }

    static func messages(from turns: [JSONValue]) -> [Message] {
        turns.flatMap { turn in
            (turn["items"]?.a ?? []).compactMap { item -> Message? in
                let type = item["type"]?.s ?? ""
                let id = item["id"]?.stringValue ?? UUID().uuidString
                if type == "userMessage" {
                    let text = (item["content"]?.a ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
                    return Message(id: id, role: "user", text: text)
                }
                if type == "agentMessage" { return Message(id: id, role: "assistant", text: item["text"]?.s ?? "", isFinal: item["phase"]?.s != "commentary") }
                return nil
            }
        }
    }
}

enum PipError: LocalizedError { case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

private func activityLabel(_ type: String, item: JSONValue) -> String {
    switch type {
    case "mcpToolCall": return "Using \(item["tool"]?.s ?? "a tool")"
    case "commandExecution": return "Running a command"
    case "fileChange": return "Updating files"
    case "webSearch": return "Searching the web"
    case "imageGeneration": return "Creating an image"
    default: return "Working"
    }
}
