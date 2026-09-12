import AppKit
import SwiftUI

@main
struct PipApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = PipAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor final class PipAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = AppStore()
    private var panel: PanelController!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private let shortcut = GlobalShortcut()
    private var holdTask: Task<Void, Never>?
    private var held = false
    private var shortcutBeganOpen = false
    private var holdStartedVoice = false
    private var registeredShortcut: Shortcut?

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = PanelController(store: store)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = PipIconName.menuBar.image()
        statusItem.button?.toolTip = "Pip"
        let menu = NSMenu(); menu.delegate = self; statusItem.menu = menu
        store.onPresentationChange = { [weak self] in self?.panel.present() }
        store.onMenuChange = { [weak self] in self?.updateStatus() }
        store.onSettingsChange = { [weak self] in self?.registerShortcut() }
        shortcut.onPress = { [weak self] in self?.shortcutPressed() }
        shortcut.onRelease = { [weak self] in self?.shortcutReleased() }
        registerShortcut()
        // Standard editing commands support the native text views and setup fields.
        let mainMenu = NSMenu()
        let appMenu = NSMenu(); appMenu.addItem(withTitle: "Quit Pip", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem(); appItem.submenu = appMenu; mainMenu.addItem(appItem)
        let edit = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", Selector(("undo:")), "z"), ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] { edit.addItem(withTitle: title, action: action, keyEquivalent: key) }
        let editItem = NSMenuItem(); editItem.submenu = edit; mainMenu.addItem(editItem); NSApp.mainMenu = mainMenu
        if !store.preferences.setupComplete { openSettings(onboarding: true) }
        Task { await store.connect() }
        Task { try? await store.dictation.loadCachedModel() }
        if ProcessInfo.processInfo.arguments.contains("--show") { store.show() }
    }
    private func registerShortcut() {
        guard registeredShortcut != store.preferences.summon else { return }
        registeredShortcut = store.preferences.summon
        store.shortcutError = shortcut.register(store.preferences.summon) ? nil : "This shortcut is unavailable. Choose another or change the conflicting macOS shortcut."
    }
    private func shortcutPressed() {
        held = true
        shortcutBeganOpen = store.location == .center
        holdStartedVoice = false
        if settingsWindow?.isKeyWindow == true { settingsWindow?.orderOut(nil) }
        if !shortcutBeganOpen { store.show() }
        holdTask?.cancel()
        holdTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled, let self, self.held else { return }
            self.holdStartedVoice = true
            self.store.beginVoice()
        }
    }
    private func shortcutReleased() {
        held = false; holdTask?.cancel(); holdTask = nil
        if holdStartedVoice { store.finishVoice() }
        else if shortcutBeganOpen { store.minimize() }
    }
    private func updateStatus() {
        let attention = !store.requests.isEmpty
        let unread = store.conversations.contains { $0.unread }
        statusItem.button?.image = PipIconName.menuBar.image()
        statusItem.button?.toolTip = attention ? "Pip needs attention" : "Pip"
        statusItem.button?.title = attention ? " !" : store.busyCount > 0 ? " \(store.busyCount)" : unread ? " ·" : ""
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        add(menu, "Open Pip", #selector(openPip))
        add(menu, "New Conversation", #selector(newConversation))
        menu.addItem(.separator())
        let history = store.history
        if history.isEmpty { let empty = NSMenuItem(title: "Your conversations will appear here", action: nil, keyEquivalent: ""); empty.isEnabled = false; menu.addItem(empty) }
        for conversation in history.prefix(30) {
            let prefix = store.requests.contains { $0.conversationID == conversation.id } ? "◉ " : conversation.state.isWorking ? "◌ " : conversation.unread ? "● " : ""
            let item = NSMenuItem(title: prefix + String(conversation.title.prefix(65)), action: #selector(openConversation(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = conversation.id.uuidString
            item.state = conversation.id == store.activeID ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        add(menu, "Settings…", #selector(showSettings))
        add(menu, "Setup…", #selector(showSetup))
        add(menu, "Quit Pip", #selector(quit))
    }
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) { let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item) }
    @objc private func openPip() { store.show() }
    @objc private func newConversation() { store.newConversation() }
    @objc private func openConversation(_ sender: NSMenuItem) { if let value = sender.representedObject as? String, let id = UUID(uuidString: value) { store.select(id) } }
    @objc private func showSettings() { openSettings(onboarding: false) }
    @objc private func showSetup() { openSettings(onboarding: true) }
    @objc private func quit() { NSApp.terminate(nil) }
    private func openSettings(onboarding: Bool) {
        store.minimize()
        if settingsWindow == nil {
            settingsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 650), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            settingsWindow?.isReleasedWhenClosed = false; settingsWindow?.minSize = NSSize(width: 620, height: 600)
            settingsWindow?.titlebarAppearsTransparent = true; settingsWindow?.center()
        }
        settingsWindow?.title = onboarding ? "Welcome to Pip" : "Pip Settings"
        settingsWindow?.contentView = NSHostingView(rootView: SettingsView(store: store, onboarding: onboarding) { [weak self] in self?.settingsWindow?.close(); self?.store.show() })
        settingsWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if store.busyCount > 0 {
            let alert = NSAlert(); alert.messageText = "Quit while Pip is working?"; alert.informativeText = "Running work will stop. Your conversations stay in history."
            alert.addButton(withTitle: "Keep Working"); alert.addButton(withTitle: "Quit Pip")
            if alert.runModal() != .alertSecondButtonReturn { return .terminateCancel }
        }
        store.cancelVoice(); store.persist(); store.client.stop(); return .terminateNow
    }
}
