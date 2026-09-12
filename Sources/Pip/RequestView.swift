import SwiftUI

struct RequestView: View {
    let store: AppStore
    let request: PendingRequest
    @State private var answers: [String: String] = [:]
    @State private var booleans: [String: Bool] = [:]
    @State private var selections: [String: Set<String>] = [:]
    private var schema: JSONValue { request.params["requestedSchema"] ?? .object([:]) }
    private var fields: [(key: String, value: JSONValue)] { (schema["properties"]?.objectValue ?? [:]).sorted { $0.key < $1.key } }
    private var questions: [JSONValue] { request.params["questions"]?.a ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PipLabel(request.title, icon: request.isQuestion ? .question : .permission)
                .font(.system(size: 14, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            if request.isQuestion {
                ForEach(Array(questions.enumerated()), id: \.offset) { _, question in
                    let id = question["id"]?.s ?? ""
                    VStack(alignment: .leading, spacing: 8) {
                        Text(question["question"]?.s ?? "").font(.callout)
                        ForEach(Array((question["options"]?.a ?? []).enumerated()), id: \.offset) { _, option in
                            Button {
                                answers[id] = option["label"]?.s ?? ""
                            } label: {
                                PipLabel(option["label"]?.s ?? "", icon: answers[id] == option["label"]?.s ? .selected : .unselected)
                            }.buttonStyle(.plain)
                            if let description = option["description"]?.stringValue { Text(description).font(.caption).foregroundStyle(.secondary) }
                        }
                        if question["isSecret"]?.boolValue == true { SecureField("Your answer", text: answerBinding(id)) }
                        else { TextField("Your answer", text: answerBinding(id)) }
                    }
                }
                Button("Send answer") {
                    let result = Dictionary(uniqueKeysWithValues: questions.compactMap { q -> (String, JSONValue)? in
                        guard let id = q["id"]?.stringValue else { return nil }
                        return (id, .object(["answers": .array([.string(answers[id] ?? "")])]))
                    })
                    store.resolve(request, result: .object(["answers": .object(result)]))
                }.buttonStyle(.glassProminent).disabled(questions.contains { (answers[$0["id"]?.s ?? ""] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            } else if request.isElicitation {
                if let raw = request.params["url"]?.stringValue, let url = URL(string: raw), ["http","https"].contains(url.scheme ?? "") { Link("Open authorization page", destination: url) }
                ForEach(fields, id: \.key) { field in
                    let name = field.value["title"]?.stringValue ?? field.key
                    if field.value["type"]?.s == "boolean" {
                        Toggle(name, isOn: Binding(get: { booleans[field.key] ?? field.value["default"]?.boolValue ?? false }, set: { booleans[field.key] = $0 }))
                    } else if field.value["type"]?.s == "array" {
                        ForEach(formChoices(field.value["items"] ?? .object([:])), id: \.value) { choice in
                            Button { toggle(choice.value, for: field.key) } label: {
                                PipLabel(choice.label, icon: (selections[field.key] ?? []).contains(choice.value) ? .selected : .unselected)
                            }.buttonStyle(.plain)
                        }
                    } else {
                        let choices = formChoices(field.value)
                        if !choices.isEmpty {
                            Picker(name, selection: answerBinding(field.key)) {
                                Text("Choose…").tag("")
                                ForEach(choices, id: \.value) { Text($0.label).tag($0.value) }
                            }
                        } else { TextField(name, text: answerBinding(field.key)) }
                    }
                }
                if !supportedForm { Text("This access request uses an unsupported form. You can decline it and continue in Codex.").font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button("Decline") { store.resolve(request, result: .object(["action": .string("decline")])) }.buttonStyle(.glass)
                    Spacer()
                    Button("Allow") { store.resolve(request, result: .object(["action": .string("accept"), "content": .object(formContent)])) }
                        .buttonStyle(.glassProminent).disabled(!supportedForm || !requiredFieldsPresent || !allFieldsValid)
                }
            } else {
                if let command = request.params["command"]?.stringValue { Text(command).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                if let kind = request.params["kind"]?.stringValue { Text(kind == "writeStdin" ? "Allow input to an existing terminal" : "Allow command execution").font(.caption).foregroundStyle(.secondary) }
                if let reason = request.params["reason"]?.stringValue { Text(reason).font(.callout).textSelection(.enabled) }
                if let host = request.params["networkApprovalContext"]?["host"]?.stringValue { Text("Network access: \(host)").font(.caption).foregroundStyle(.secondary) }
                if let path = request.params["grantRoot"]?.stringValue ?? request.params["cwd"]?.stringValue { Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                if request.method == "item/permissions/requestApproval" {
                    Text(request.params["permissions"]?.pretty ?? "").font(.caption.monospaced()).textSelection(.enabled)
                    HStack {
                        Button("Decline") { store.resolve(request, result: .object(["permissions": .object([:]), "scope": .string("turn")])) }
                        Spacer()
                        Button("Allow for this turn") { store.resolve(request, result: .object(["permissions": request.params["permissions"] ?? .object([:]), "scope": .string("turn")])) }
                    }.buttonStyle(.glass)
                } else {
                    if availableDecisions.isEmpty { Text("This request uses an unsupported approval format. Resolve it in Codex.").font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        if availableDecisions.contains("decline") { Button("Decline") { approve("decline") }.buttonStyle(.glass) }
                        Spacer()
                        if availableDecisions.contains("acceptForSession") { Button("Allow this session") { approve("acceptForSession") }.buttonStyle(.glass) }
                        if availableDecisions.contains("accept") { Button("Allow once") { approve("accept") }.buttonStyle(.glassProminent) }
                    }
                }
            }
        }
        .padding(14)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
        .textFieldStyle(.roundedBorder)
        .accessibilityElement(children: .contain)
    }
    private func approve(_ decision: String) { store.resolve(request, result: .object(["decision": .string(decision)])) }
    private var availableDecisions: [String] {
        if let decisions = request.params["availableDecisions"]?.arrayValue { return decisions.compactMap(\.stringValue) }
        if request.method.contains("commandExecution") || request.method.contains("fileChange") { return ["accept", "acceptForSession", "decline", "cancel"] }
        return []
    }
    private func answerBinding(_ key: String) -> Binding<String> {
        Binding(get: { answers[key] ?? defaultText(for: fields.first(where: { $0.key == key })?.value) }, set: { answers[key] = $0 })
    }
    private func defaultText(for field: JSONValue?) -> String {
        field?["default"]?.stringValue ?? field?["default"]?.intValue.map(String.init) ?? ""
    }
    private func toggle(_ value: String, for key: String) {
        var selected = selections[key] ?? []
        if selected.contains(value) { selected.remove(value) } else { selected.insert(value) }
        selections[key] = selected
    }
    private func formChoices(_ field: JSONValue) -> [(value: String, label: String)] {
        if let values = field["oneOf"]?.arrayValue { return values.compactMap { v in guard let value = v["const"]?.stringValue else { return nil }; return (value, v["title"]?.stringValue ?? value) } }
        let names = field["enumNames"]?.a ?? []
        return (field["enum"]?.a ?? []).enumerated().compactMap { index, value in guard let text = value.stringValue else { return nil }; return (text, names.indices.contains(index) ? names[index].s : text) }
    }
    private var supportedForm: Bool {
        request.params["mode"]?.s != "url" && fields.allSatisfy {
            let type = $0.value["type"]?.s ?? "string"
            if ["string", "boolean", "integer", "number"].contains(type) { return true }
            return type == "array" && $0.value["items"]?["type"]?.s == "string" && !formChoices($0.value["items"] ?? .object([:])).isEmpty
        }
    }
    private var requiredFieldsPresent: Bool {
        (schema["required"]?.a ?? []).allSatisfy { key in
            guard let type = schema["properties"]?[key.s]?["type"]?.s else { return !(answers[key.s] ?? "").isEmpty }
            if type == "boolean" { return true }
            if type == "array" { return !(selections[key.s] ?? []).isEmpty }
            let text = answers[key.s] ?? defaultText(for: schema["properties"]?[key.s])
            if type == "number" || type == "integer" { return validNumber(text, field: schema["properties"]?[key.s], integer: type == "integer") }
            return !text.isEmpty
        }
    }
    private var allFieldsValid: Bool {
        fields.allSatisfy { field in
            let type = field.value["type"]?.s
            guard type == "number" || type == "integer" else { return true }
            let text = answers[field.key] ?? defaultText(for: field.value)
            return text.isEmpty || validNumber(text, field: field.value, integer: type == "integer")
        }
    }
    private func validNumber(_ text: String, field: JSONValue?, integer: Bool) -> Bool {
        guard let value = Double(text), value.isFinite, !integer || Int(text) != nil else { return false }
        if let minimum = field?["minimum"]?.doubleValue, value < minimum { return false }
        if let maximum = field?["maximum"]?.doubleValue, value > maximum { return false }
        return true
    }
    private var formContent: [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for field in fields {
            switch field.value["type"]?.s {
            case "boolean": result[field.key] = .bool(booleans[field.key] ?? field.value["default"]?.boolValue ?? false)
            case "array": result[field.key] = .array((selections[field.key] ?? []).sorted().map(JSONValue.string))
            case "integer", "number": if let n = Double(answers[field.key] ?? defaultText(for: field.value)), n.isFinite { result[field.key] = .number(n) }
            default:
                let text = answers[field.key] ?? defaultText(for: field.value)
                if !text.isEmpty { result[field.key] = .string(text) }
            }
        }
        return result
    }
}
