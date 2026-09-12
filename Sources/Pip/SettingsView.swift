import SwiftUI
import AVFoundation

struct SettingsView: View {
    @Bindable var store: AppStore
    @Bindable var appUpdater: AppUpdater
    let onboarding: Bool
    var onComplete: () -> Void
    @State private var page = 0
    @State private var setupError: String?
    var body: some View {
        VStack(spacing: 0) {
            if onboarding {
                VStack(spacing: 12) {
                    PipIcon(.pip, size: 44).padding(.top, 16)
                    Text("Hello, Pip.").font(.system(size: 32, weight: .semibold, design: .rounded))
                    Text("Your Codex assistant, a shortcut away.").foregroundStyle(.secondary)
                    HStack(spacing: 6) { ForEach(0..<3) { index in Capsule().fill(index == page ? Color.primary : Color.primary.opacity(0.15)).frame(width: index == page ? 22 : 7, height: 5) } }.padding(.top, 6)
                }.padding(20)
                Form {
                    if page == 0 { connectionSection }
                    else if page == 1 { shortcutSection; voiceSection }
                    else { toolsSection }
                }.formStyle(.grouped)
                HStack {
                    if page > 0 { Button("Back") { page -= 1 }.buttonStyle(.glass) }
                    Spacer()
                    if page < 2 { Button("Continue") { page += 1 }.buttonStyle(.glassProminent).disabled(page == 0 && !store.signedIn) }
                    else { Button("Start using Pip") { store.preferences.setupComplete = true; onComplete() }.buttonStyle(.glassProminent) }
                }.padding(24)
            } else {
                TabView {
                    Form { connectionSection; modelSection; behaviorSection; updatesSection }.formStyle(.grouped).tabItem { PipLabel("General", icon: .settings) }
                    Form { voiceSection }.formStyle(.grouped).tabItem { PipLabel("Voice", icon: .voice) }
                    Form { shortcutSection; extraShortcuts }.formStyle(.grouped).tabItem { PipLabel("Shortcuts", icon: .keyboard) }
                    Form { toolsSection }.formStyle(.grouped).tabItem { PipLabel("Tools", icon: .tools) }
                }.padding(16)
            }
        }
        .frame(minWidth: 580, minHeight: 570)
        .onChange(of: store.preferences.model) { _, _ in store.validateModel() }
    }
    private var updatesSection: some View {
        Section("Updates") {
            LabeledContent("Version", value: appUpdater.version)
            Toggle("Automatically check for updates", isOn: $appUpdater.automaticallyChecks)
                .disabled(!appUpdater.isEnabled)
            Toggle("Download updates and install when I quit", isOn: $appUpdater.automaticallyDownloads)
                .disabled(!appUpdater.isEnabled || !appUpdater.automaticallyChecks)
            Button("Check for Updates…") { appUpdater.checkForUpdates() }
                .disabled(!appUpdater.canCheckForUpdates)
            Text(appUpdater.status).font(.caption).foregroundStyle(.secondary)
            Link("Release history", destination: URL(string: "https://github.com/dakdevs/pip/releases")!)
        }
    }
    private var connectionSection: some View {
        Section("Connect Codex") {
            LabeledContent("Account", value: store.accountLabel)
            HStack {
                if store.connecting { ProgressView().controlSize(.small) }
                Button(store.connected ? "Reconnect" : "Connect") { Task { await store.connect() } }.disabled(store.connecting || store.busyCount > 0)
                if !store.signedIn { Button("Sign in with ChatGPT") { Task { await store.signIn() } }.disabled(store.connecting) }
                Spacer()
                Link("Get Codex", destination: URL(string: "https://developers.openai.com/codex/cli")!)
            }
            HStack {
                TextField("Codex executable", text: $store.preferences.codexPath)
                Button("Choose…") { choosePath(directory: false) { store.preferences.codexPath = $0 } }
            }
            if let error = store.connectionError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if !store.models.isEmpty {
                Picker("Model", selection: $store.preferences.model) { ForEach(store.models) { Text($0.name).tag($0.id) } }
            }
        }
    }
    private var modelSection: some View {
        Section("Model settings") {
            Picker("Reasoning effort", selection: $store.preferences.reasoning) { ForEach(store.selectedModel?.efforts ?? [], id: \.self) { Text($0.capitalized).tag($0) } }
            Toggle("Fast mode", isOn: $store.preferences.fast).disabled(store.selectedModel?.supportsFast != true)
            Text("Applies to new submissions in every conversation. Fast mode uses your subscription allowance more quickly. Running work keeps the settings it started with.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var behaviorSection: some View {
        Section("Completed actions") {
            Toggle("Automatically dismiss completed actions", isOn: $store.preferences.autoDismiss)
            Picker("Completion classifier", selection: $store.preferences.classifierModel) {
                Text("Unavailable").tag("")
                ForEach(store.models) { Text($0.name).tag($0.id) }
            }.disabled(!store.preferences.autoDismiss)
            Text("Checks the first turn only. Answers, findings, questions, and uncertain results stay visible. Dismissed conversations remain in history.").font(.caption).foregroundStyle(.secondary)
            if let status = store.classifierStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
        }
    }
    private var voiceSection: some View {
        Section("Hold to talk") {
            Text("Hold your shortcut, speak, then release. Pip transcribes on this Mac using Parakeet.").foregroundStyle(.secondary)
            Picker("Dictation key while composing", selection: $store.preferences.dictationKey) {
                Text("Right Option").tag(UInt16(61)); Text("Left Option").tag(UInt16(58))
                Text("Right Control").tag(UInt16(62)); Text("Left Control").tag(UInt16(59))
            }
            Toggle("Submit when I release the key", isOn: $store.preferences.autoSubmit)
            HStack {
                Button(voiceSetupButtonTitle) {
                    setupError = nil
                    Task { do { try await store.dictation.prepare() } catch { setupError = error.localizedDescription } }
                }.disabled(store.dictation.isPreparing || store.voiceBusy)
                if store.dictation.isPreparing { ProgressView().controlSize(.small) }
            }
            if let progress = store.dictation.downloadProgress,
               store.dictation.setupPhase == .downloading || store.dictation.setupPhase == .compiling {
                ProgressView(value: progress)
                if let completed = store.dictation.downloadedFiles,
                   let total = store.dictation.totalFiles {
                    Text("\(completed) of \(total) files").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("\(Int((progress * 100).rounded()))% complete").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(store.dictation.status).font(.caption).foregroundStyle(.secondary)
            if let error = setupError ?? store.dictation.error { Text(error).font(.caption).foregroundStyle(.red) }
            Text(voiceSetupHelp).font(.caption).foregroundStyle(.secondary)
            Button("Microphone settings…") { openSettings("Privacy_Microphone") }.buttonStyle(.link)
        }
    }
    private var voiceSetupButtonTitle: String {
        if store.dictation.isReady { return "Reload voice model" }
        if store.dictation.hasCachedModel { return "Load downloaded dictation" }
        if store.dictation.setupPhase == .failed { return "Try dictation setup again" }
        return "Set up on-device dictation"
    }
    private var voiceSetupHelp: String {
        if store.dictation.hasCachedModel {
            return "The downloaded model stays on this Mac and loads automatically when Pip starts. Escape cancels recording without sending."
        }
        return "Setup requests microphone access and downloads the voice model once. Escape cancels recording without sending."
    }
    private var shortcutSection: some View {
        Section("Open Pip") {
            LabeledContent("Open / hold to dictate") { ShortcutRecorder(shortcut: $store.preferences.summon) }
            Text("Tap to open or collapse. Hold to start recording. Release to finish.").font(.caption).foregroundStyle(.secondary)
            Text("Command–Space is also Spotlight’s default. Disable or change Spotlight’s shortcut in System Settings to use it for Pip, or choose another shortcut here.").font(.caption).foregroundStyle(.secondary)
            Button("Keyboard shortcuts…") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts")!) }.buttonStyle(.link)
            if let error = store.shortcutError { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }
    private var extraShortcuts: some View {
        Section("While composing") {
            LabeledContent("New conversation") { ShortcutRecorder(shortcut: $store.preferences.newConversation) }
            LabeledContent("Less reasoning") { ShortcutRecorder(shortcut: $store.preferences.lessReasoning) }
            LabeledContent("More reasoning") { ShortcutRecorder(shortcut: $store.preferences.moreReasoning) }
            LabeledContent("Toggle Fast mode") { ShortcutRecorder(shortcut: $store.preferences.toggleFast) }
            LabeledContent("History", value: "↑ from an empty prompt")
            LabeledContent("Minimize / dismiss", value: "Escape while focused")
        }
    }
    @ViewBuilder private var toolsSection: some View {
        Section("Codex capabilities") {
            Text("Pip uses the tools and plugins configured in your Codex installation. When an action needs access, its request appears in the conversation.").foregroundStyle(.secondary)
            Text(store.pluginStatus).font(.caption).textSelection(.enabled)
            Button("Refresh tool status") { Task { await store.refreshPlugins() } }.disabled(!store.connected)
            HStack {
                Button("Accessibility settings…") { openSettings("Privacy_Accessibility") }
                Button("Screen recording settings…") { openSettings("Privacy_ScreenCapture") }
            }.buttonStyle(.link)
            Text("Computer-use permissions belong to the Codex helper that performs the action. macOS may ask you to enable that helper when it is first used.").font(.caption).foregroundStyle(.secondary)
        }
        Section("Files and commands") {
            HStack {
                TextField("Working folder", text: $store.preferences.workingDirectory)
                Button("Choose…") { choosePath(directory: true) { store.preferences.workingDirectory = $0 } }
            }
            Toggle("Full access to files and commands", isOn: $store.preferences.fullAccess)
            Text(store.preferences.fullAccess ? "Codex can run commands and change files without additional app approval. macOS permissions still apply." : "Codex can work in the selected folder and ask when it needs more access.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func choosePath(directory: Bool, onChoose: (String) -> Void) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = directory; panel.canChooseFiles = !directory; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { onChoose(url.path) }
    }
    private func openSettings(_ anchor: String) { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!) }
}
