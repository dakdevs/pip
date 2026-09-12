import AppKit
import SwiftUI
import QuartzCore

final class PipPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var escapeAction: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { escapeAction?() }
}

@MainActor final class PanelController: NSObject, NSWindowDelegate {
    let store: AppStore
    let panel: PipPanel
    private var previousLocation: PanelLocation = .hidden
    private var targetFrame = NSRect.zero
    private var localClick: Any?
    private var globalClick: Any?
    private var screen: NSScreen?
    private var transitioning = false
    private var trackingMenus = 0
    private var frontmostApplication: NSRunningApplication?
    init(store: AppStore) {
        self.store = store
        panel = PipPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 190), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.title = "Pip"; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovableByWindowBackground = false; panel.delegate = self
        panel.contentView = NSHostingView(rootView: PanelView(store: store))
        panel.escapeAction = { [weak store] in store?.escape() }
        NotificationCenter.default.addObserver(self, selector: #selector(menuTrackingBegan), name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuTrackingEnded), name: NSMenu.didEndTrackingNotification, object: nil)
        globalClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in if let self, self.trackingMenus == 0 { self.store.minimize() } }
        }
        localClick = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self, self.trackingMenus == 0, event.window != self.panel { self.store.minimize() }
            return event
        }
    }
    func present() {
        let next = store.location
        guard next != .hidden else {
            if previousLocation != .hidden {
                panel.orderOut(nil)
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier { frontmostApplication?.activate() }
            }
            previousLocation = next; return
        }
        if next == .center && previousLocation != .center {
            frontmostApplication = NSWorkspace.shared.frontmostApplication
            if frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                store.sourceApplication = frontmostApplication?.localizedName
            }
            screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        }
        let visible = (screen ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let width: CGFloat = next == .center ? min(680, visible.width - 48) : min(380, visible.width - 36)
        let hasContent = !(store.active?.messages.isEmpty ?? true) || store.historyVisible || !store.activeRequests.isEmpty
        let height: CGFloat
        if next == .center {
            let characters = store.active?.messages.reduce(0) { $0 + $1.text.count } ?? 0
            let contentHeight: CGFloat = store.historyVisible || !store.activeRequests.isEmpty ? 560 : characters < 350 ? 310 : characters < 1100 ? 430 : 560
            height = min(hasContent ? contentHeight : 192, visible.height - 80)
        }
        else if store.active?.state.isWorking == true && store.activeRequests.isEmpty { height = 88 }
        else { height = min(330, visible.height - 48) }
        let frame = next == .center
            ? NSRect(x: visible.midX - width / 2, y: visible.minY + visible.height * 0.64 - height / 2, width: width, height: height)
            : NSRect(x: visible.maxX - width - 18, y: visible.minY + 18, width: width, height: height)
        if previousLocation == .hidden { panel.setFrame(frame, display: true) }
        else if frame != targetFrame {
            transitioning = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.34
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.18, 0.85, 0.22, 1)
                panel.animator().setFrame(frame, display: true)
            } completionHandler: { [weak self] in Task { @MainActor in self?.transitioning = false } }
        }
        targetFrame = frame
        if next == .center && (previousLocation != .center || !panel.isVisible) {
            panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        } else if next == .corner {
            if panel.isKeyWindow { panel.resignKey(); frontmostApplication?.activate() }
            panel.orderFrontRegardless()
        }
        previousLocation = next
    }
    @objc private func menuTrackingBegan(_ notification: Notification) { trackingMenus += 1 }
    @objc private func menuTrackingEnded(_ notification: Notification) {
        trackingMenus = max(0, trackingMenus - 1)
        collapseIfUnfocused()
    }
    func windowDidResignKey(_ notification: Notification) { collapseIfUnfocused() }
    private func collapseIfUnfocused() {
        // Menu popups temporarily participate in key-window routing. Let their
        // tracking notification arrive before treating that as an outside click.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.transitioning, self.trackingMenus == 0,
                  !self.panel.isKeyWindow, self.store.location == .center else { return }
            self.store.minimize()
        }
    }
}
