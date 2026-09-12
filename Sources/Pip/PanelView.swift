import SwiftUI

struct PanelView: View {
    @Bindable var store: AppStore
    @Namespace private var glass
    var body: some View {
        GlassEffectContainer(spacing: 20) {
            Group {
                if store.location == .corner { corner }
                else { center }
            }
            .padding(store.location == .corner ? 16 : 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: store.location == .corner ? 24 : 30))
            .glassEffectID("pip-surface", in: glass)
        }
        .padding(12)
        .animation(.smooth(duration: 0.25), value: store.location == .corner)
        .preferredColorScheme(nil)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pip assistant")
    }

    private var center: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                PipMark(working: store.active?.state.isWorking == true)
                Text("Pip").font(.system(size: 14, weight: .semibold))
                if store.historyVisible { Text("/  History").foregroundStyle(.secondary).font(.callout) }
                else if let title = store.active?.title, title != "New conversation" { Text("/  " + title).lineLimit(1).font(.callout).foregroundStyle(.secondary) }
                Spacer(minLength: 8)
                Button { store.newConversation() } label: { PipIcon(.compose) }.accessibilityLabel("New conversation").help("New conversation · \(store.preferences.newConversation.label)")
                Button { store.minimize() } label: { PipIcon(.collapse) }.accessibilityLabel("Collapse to corner").help("Collapse to corner")
            }.buttonStyle(.plain)

            if store.historyVisible { history }
            else if !(store.active?.messages.isEmpty ?? true) || !store.activeRequests.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            ForEach(store.active?.messages ?? []) { message in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(message.role == "user" ? "YOU" : "PIP")
                                        .font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(.tertiary)
                                    MarkdownText(text: message.text)
                                        .font(.system(size: 15)).textSelection(.enabled)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                            ForEach(store.activeRequests) { request in RequestView(store: store, request: request) }
                            if let error = store.active?.error { PipLabel(error, icon: .warning).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                            Color.clear.frame(height: 1).id("tail")
                        }.padding(.vertical, 6)
                    }
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: store.active?.messages.last?.text) { _, _ in proxy.scrollTo("tail", anchor: .bottom) }
                    .onChange(of: store.activeID) { _, _ in proxy.scrollTo("tail", anchor: .bottom) }
                }
                Divider().opacity(0.5)
            }

            composer
            if let error = store.voiceError ?? store.connectionError { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2) }
            footer
        }
    }
    private var composer: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack(alignment: .topLeading) {
                if store.draft.isEmpty {
                    Text(store.dictation.isRecording ? "Listening…" : store.dictation.isTranscribing ? "Transcribing…" : store.active?.state.isWorking == true ? "Add a thought…" : "Ask Pip anything…")
                        .font(.system(size: 19)).foregroundStyle(.tertiary).padding(.top, 6).allowsHitTesting(false)
                }
                PromptInput(store: store).frame(height: 52)
            }
            if store.dictation.isRecording { PipIcon(.voice, size: 22).foregroundStyle(.tint).font(.title2) }
            else if store.dictation.isTranscribing { ProgressView().controlSize(.small) }
            else {
                Button { store.submit() } label: { PipIcon(.send).font(.system(size: 15, weight: .semibold)).frame(width: 26, height: 26) }
                    .buttonStyle(.glassProminent).buttonBorderShape(.circle)
                    .disabled(store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !store.historyVisible)
                    .accessibilityLabel("Send prompt").help("Send prompt")
            }
        }
    }
    private var footer: some View {
        HStack(spacing: 10) {
            Circle().fill(store.connected && store.signedIn ? Color.green : Color.orange).frame(width: 5, height: 5)
            Menu {
                ForEach(store.models) { model in
                    Button { store.preferences.model = model.id } label: {
                        if model.id == store.preferences.model { PipLabel(model.name, icon: .check) }
                        else { Text(model.name) }
                    }
                }
            } label: { Text(store.selectedModel?.name ?? "Connect Codex").lineLimit(1) }.menuStyle(.borderlessButton).fixedSize()
            Menu {
                ForEach(store.selectedModel?.efforts ?? [], id: \.self) { effort in
                    Button { store.preferences.reasoning = effort } label: {
                        if effort == store.preferences.reasoning { PipLabel(effort.capitalized, icon: .check) }
                        else { Text(effort.capitalized) }
                    }
                }
            } label: { Text(store.preferences.reasoning.capitalized) }.menuStyle(.borderlessButton).fixedSize()
            Button { store.toggleFast() } label: { PipIcon(store.preferences.fast && store.selectedModel?.supportsFast == true ? .fast : .slow) }
                .buttonStyle(.plain).foregroundStyle(store.preferences.fast ? Color.orange : Color.secondary)
                .disabled(store.selectedModel?.supportsFast != true).accessibilityLabel("Fast mode").help("Fast mode · \(store.preferences.toggleFast.label)")
            Spacer(minLength: 2)
            if store.active?.state.isWorking == true {
                ProgressView().controlSize(.mini)
                Text(store.active?.activity.isEmpty == false ? store.active!.activity : "Working").lineLimit(1)
                Button("Stop") { store.stopActive() }.buttonStyle(.plain)
            } else { Text("↑ History").foregroundStyle(.tertiary) }
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .onChange(of: store.preferences.model) { _, _ in store.validateModel() }
    }
    private var history: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(Array(store.history.enumerated()), id: \.element.id) { index, conversation in
                        Button { store.select(conversation.id) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack { Text(conversation.title).fontWeight(.medium).lineLimit(1); Spacer(); if conversation.state.isWorking { ProgressView().controlSize(.mini) } }
                                Text(conversation.historyPreview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(store.historyIndex == index ? Color.primary.opacity(0.07) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain).id(index)
                    }
                }
            }.onChange(of: store.historyIndex) { _, index in proxy.scrollTo(index, anchor: .center) }
        }
    }
    private var corner: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                PipMark(working: store.active?.state.isWorking == true)
                Button { store.show() } label: {
                    Text(store.activeRequests.isEmpty ? (store.active?.state.isWorking == true ? "Pip is working" : "Pip") : "Pip needs your attention")
                        .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                }.buttonStyle(.plain)
                Spacer()
                if store.active?.state.isWorking == true {
                    Button { store.stopActive() } label: { PipIcon(.stop) }.accessibilityLabel("Stop work").help("Stop work")
                } else { Button { store.endConversation() } label: { PipIcon(.close) }.accessibilityLabel("Dismiss conversation").help("Dismiss conversation") }
            }.buttonStyle(.plain)
            if store.active?.state.isWorking == true && store.activeRequests.isEmpty {
                // The collapsed capsule stays small; clicking anywhere restores it.
                EmptyView()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !store.activeRequests.isEmpty { ForEach(store.activeRequests) { RequestView(store: store, request: $0) } }
                        else if let error = store.active?.error { Text(error).foregroundStyle(.red) }
                        else { MarkdownText(text: store.active?.lastReply.isEmpty == false ? store.active!.lastReply : "Done.").textSelection(.enabled) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.font(.system(size: 13))
                HStack {
                    Button { store.show() } label: { Text("\(store.preferences.summon.label)  Reply") }.buttonStyle(.plain)
                    Spacer()
                    Text("esc  Dismiss when focused").foregroundStyle(.tertiary)
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if store.active?.state.isWorking == true && store.activeRequests.isEmpty { store.show() } }
    }
}

struct PipMark: View {
    var working = false
    var body: some View {
        PipIcon(.pip, size: 18)
            .accessibilityHidden(false)
            .foregroundStyle(.primary).accessibilityLabel(working ? "Working" : "Pip")
    }
}

struct MarkdownText: View {
    let text: String
    var body: some View {
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
