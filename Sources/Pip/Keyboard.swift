import AppKit
import Carbon
import SwiftUI

@MainActor
final class GlobalShortcut {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var down = false
    init() {
        var events = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)), EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                if GetEventKind(event) == UInt32(kEventHotKeyPressed) {
                    if !owner.down { owner.down = true; owner.onPress?() }
                } else { owner.down = false; owner.onRelease?() }
            }
            return noErr
        }, events.count, &events, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func register(_ shortcut: Shortcut) -> Bool {
        if let reference { UnregisterEventHotKey(reference) }; reference = nil; down = false
        var modifiers: UInt32 = 0
        if shortcut.flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if shortcut.flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if shortcut.flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if shortcut.flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), modifiers, EventHotKeyID(signature: 0x50697021, id: 1), GetApplicationEventTarget(), 0, &reference)
        return status == noErr
    }
}

struct PromptInput: NSViewRepresentable {
    @Bindable var store: AppStore
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let input = PromptTextView()
        input.store = store; input.delegate = context.coordinator
        input.font = .systemFont(ofSize: 19, weight: .regular)
        input.textColor = .labelColor; input.insertionPointColor = .labelColor
        input.drawsBackground = false; input.isRichText = false; input.isAutomaticQuoteSubstitutionEnabled = false
        input.isAutomaticDashSubstitutionEnabled = false; input.isAutomaticTextReplacementEnabled = false
        input.textContainerInset = NSSize(width: 0, height: 6)
        input.isVerticallyResizable = true; input.isHorizontallyResizable = false
        input.autoresizingMask = [.width]; input.textContainer?.widthTracksTextView = true
        input.textContainer?.lineFragmentPadding = 0
        input.minSize = NSSize(width: 0, height: 35)
        input.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = input
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        guard let input = view.documentView as? PromptTextView else { return }
        input.store = store
        if input.string != store.draft { input.string = store.draft; input.setSelectedRange(NSRange(location: input.string.utf16.count, length: 0)) }
        if context.coordinator.focusRevision != store.focusRevision {
            context.coordinator.focusRevision = store.focusRevision
            DispatchQueue.main.async { if store.location == .center { view.window?.makeFirstResponder(input) } }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(store) }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        let store: AppStore
        var focusRevision = -1
        init(_ store: AppStore) { self.store = store }
        func textDidChange(_ notification: Notification) { if let input = notification.object as? NSTextView { store.draft = input.string } }
    }
}

@MainActor final class PromptTextView: NSTextView {
    weak var store: AppStore?
    private var dictationHeld = false
    override func keyDown(with event: NSEvent) {
        guard let store else { super.keyDown(with: event); return }
        if handleShortcut(event) { return }
        if event.keyCode == 53 { store.escape(); return }
        if event.keyCode == 36 && !event.modifierFlags.contains(.shift) && !hasMarkedText() { store.submit(); return }
        if event.keyCode == 126 && string.isEmpty { store.historyMove(-1); return }
        if event.keyCode == 125 && store.historyVisible { store.historyMove(1); return }
        super.keyDown(with: event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, handleShortcut(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
    private func handleShortcut(_ event: NSEvent) -> Bool {
        guard let store else { return false }
        let prefs = store.preferences
        if prefs.newConversation.matches(event) { store.newConversation(); return true }
        if prefs.toggleFast.matches(event) { store.toggleFast(); return true }
        if prefs.lessReasoning.matches(event) { store.stepReasoning(-1); return true }
        if prefs.moreReasoning.matches(event) { store.stepReasoning(1); return true }
        return false
    }
    override func flagsChanged(with event: NSEvent) {
        guard let store, event.keyCode == store.preferences.dictationKey else { super.flagsChanged(with: event); return }
        let flag: NSEvent.ModifierFlags = [54,55].contains(event.keyCode) ? .command : [59,62].contains(event.keyCode) ? .control : .option
        let held = event.modifierFlags.contains(flag)
        if held && !dictationHeld { dictationHeld = true; store.beginVoice() }
        if !held && dictationHeld { dictationHeld = false; store.finishVoice() }
        super.flagsChanged(with: event)
    }
    override func resignFirstResponder() -> Bool {
        if dictationHeld { store?.cancelVoice() }
        dictationHeld = false
        return super.resignFirstResponder()
    }
}

struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut
    @State private var recording = false
    @State private var monitor: Any?
    var body: some View {
        Button(recording ? "Press a shortcut…" : shortcut.label) {
            recording = true
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 { finish(); return nil }
                let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
                guard !modifiers.isEmpty else { NSSound.beep(); return nil }
                shortcut = Shortcut(keyCode: event.keyCode, modifiers: modifiers.rawValue)
                finish(); return nil
            }
        }
        .monospaced().disabled(recording)
        .onDisappear { finish() }
    }
    private func finish() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil; recording = false }
}
