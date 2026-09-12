import AppKit
import Observation

struct Shortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt
    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }
    static let summon = Shortcut(keyCode: 49, modifiers: NSEvent.ModifierFlags.command.rawValue)
    static let newConversation = Shortcut(keyCode: 45, modifiers: NSEvent.ModifierFlags.command.rawValue)
    static let fast = Shortcut(keyCode: 3, modifiers: NSEvent.ModifierFlags.command.rawValue)
    static let lessReasoning = Shortcut(keyCode: 123, modifiers: NSEvent.ModifierFlags.command.rawValue)
    static let moreReasoning = Shortcut(keyCode: 124, modifiers: NSEvent.ModifierFlags.command.rawValue)
    func matches(_ event: NSEvent) -> Bool {
        event.keyCode == keyCode && event.modifierFlags.intersection([.command, .option, .control, .shift]) == flags
    }
    var label: String {
        let names: [UInt16: String] = [49:"Space",45:"N",3:"F",123:"←",124:"→",126:"↑",125:"↓",36:"Return",53:"Esc",0:"A",1:"S",2:"D",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",31:"O",32:"U",34:"I",35:"P",37:"L",38:"J",40:"K",46:"M",48:"Tab"]
        return (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "") + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + (names[keyCode] ?? "Key \(keyCode)")
    }
}

struct Preferences: Codable, Equatable {
    var model = ""
    var reasoning = "medium"
    var fast = false
    var autoSubmit = true
    var autoDismiss = true
    var classifierModel = ""
    var codexPath = ""
    var workingDirectory = ""
    var fullAccess = false
    var setupComplete = false
    var summon = Shortcut.summon
    var newConversation = Shortcut.newConversation
    var toggleFast = Shortcut.fast
    var lessReasoning = Shortcut.lessReasoning
    var moreReasoning = Shortcut.moreReasoning
    var dictationKey: UInt16 = 61
}

struct ModelOption: Identifiable {
    let id: String
    let name: String
    let efforts: [String]
    let defaultEffort: String
    let supportsFast: Bool
    let isDefault: Bool
    init?(_ json: JSONValue) {
        guard let id = json["id"]?.stringValue else { return nil }
        self.id = id
        name = json["displayName"]?.stringValue ?? id
        efforts = json["supportedReasoningEfforts"]?.arrayValue?.compactMap { $0["reasoningEffort"]?.stringValue } ?? ["medium"]
        defaultEffort = json["defaultReasoningEffort"]?.stringValue ?? "medium"
        supportsFast = json["serviceTiers"]?.arrayValue?.contains { $0["id"]?.stringValue == "priority" } ?? false
        isDefault = json["isDefault"]?.boolValue ?? false
    }
}

enum RunState: String, Codable { case idle, starting, running, waiting, complete, failed, stopped
    var isWorking: Bool { self == .starting || self == .running || self == .waiting }
}

struct Message: Codable, Identifiable {
    var id: String
    var role: String
    var text: String
    var isFinal = false
    init(id: String = UUID().uuidString, role: String, text: String, isFinal: Bool = false) {
        self.id = id; self.role = role; self.text = text; self.isFinal = isFinal
    }
}

struct Conversation: Identifiable, Codable {
    var id = UUID()
    var threadID: String?
    var title = "New conversation"
    var messages: [Message] = []
    var draft = ""
    var updated = Date()
    var state: RunState = .idle
    var turnID: String?
    var activity = ""
    var unread = false
    var userMessageCount = 0
    var usedTools = false
    var toolFailed = false
    var error: String?
    var lastReply: String { messages.last(where: { $0.role == "assistant" && $0.isFinal })?.text ?? messages.last(where: { $0.role == "assistant" })?.text ?? "" }
    var historyPreview: String { lastReply.isEmpty ? (messages.first?.text ?? "") : lastReply }
    var eligibleForDismissal: Bool { state == .complete && userMessageCount == 1 && usedTools && !toolFailed && !lastReply.isEmpty }
}

struct PendingRequest: Identifiable {
    var id = UUID()
    let rpcID: JSONValue
    let method: String
    let params: JSONValue
    var conversationID: UUID?
    var isQuestion: Bool { method == "item/tool/requestUserInput" }
    var isElicitation: Bool { method == "mcpServer/elicitation/request" }
    var title: String { params["message"]?.stringValue ?? params["reason"]?.stringValue ?? (isQuestion ? "Pip needs your input" : "Permission needed") }
}

enum PanelLocation { case hidden, center, corner }

enum PipPaths {
    static var support: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pip", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }
    static var workspace: URL {
        let url = support.appendingPathComponent("Workspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static var codexExecutable: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [home + "/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/Applications/ChatGPT.app/Contents/Resources/codex", "/Applications/Codex.app/Contents/Resources/codex"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? ""
    }
}

extension JSONValue {
    var pretty: String { (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
    var s: String { stringValue ?? "" }
    var a: [JSONValue] { arrayValue ?? [] }
}
