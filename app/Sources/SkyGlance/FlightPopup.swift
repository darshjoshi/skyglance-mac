import AppKit
import OverheadKit
import SwiftUI

/// Where the ✈ actually is on screen, and whether anyone is there to look at it.
///
/// Both answers are needed before a popup is worth showing, and both can fail in
/// ways that must send the alert back to the notification path rather than put a
/// card somewhere useless.
enum MenuBarAnchor {

    /// The screen rect of this app's status item.
    ///
    /// `MenuBarExtra` exposes no `NSStatusItem`, so there is no public API for
    /// this. The status item's window is found by class *name* rather than type:
    /// `NSStatusBarWindow` is private, and matching a string cannot fail to
    /// compile or link — if Apple renames it this returns nil and the caller
    /// falls back, which is the behaviour we want anyway.
    ///
    /// Read fresh every time. The item's width tracks its text, so `✈ 73 · CRJ7
    /// 4s` is far wider than `✈ 5`, and a cached frame would drift.
    static func statusItemFrame() -> CGRect? {
        guard let frame = NSApp.windows.first(where: {
            String(describing: type(of: $0)) == "NSStatusBarWindow"
        })?.frame else { return nil }

        // A hidden item — pushed under the notch, or swallowed by a menu bar
        // manager — still has a window, just not one on any screen. Anchoring to
        // it would drop the card off the edge of the display.
        guard NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) else { return nil }
        return frame
    }

    /// Places a popup of `size` under the status item, centred on it, and nudged
    /// back inside the screen if the item sits near a corner.
    static func popupOrigin(for size: CGSize, below item: CGRect) -> CGPoint {
        let screen = NSScreen.screens.first { $0.frame.intersects(item) } ?? NSScreen.main
        let gap: CGFloat = 6
        var x = item.midX - size.width / 2
        let y = item.minY - gap - size.height

        if let visible = screen?.visibleFrame {
            let margin: CGFloat = 8
            x = min(max(x, visible.minX + margin), visible.maxX - size.width - margin)
        }
        return CGPoint(x: x, y: y)
    }
}

/// Whether the person is at the machine right now.
///
/// A popup for an aircraft that passes in sixty seconds is worthless to someone
/// who is not looking, and a card that appears over a locked screen or a
/// presentation is worse than worthless. There is no public API for Focus modes,
/// but an idle or locked Mac covers nearly every case where one would matter.
enum UserPresence {
    static let idleLimit: TimeInterval = 5 * 60

    static func isPresent(idleSeconds: TimeInterval = secondsSinceLastInput(),
                          screenLocked: Bool = isScreenLocked()) -> Bool {
        !screenLocked && idleSeconds < idleLimit
    }

    static func secondsSinceLastInput() -> TimeInterval {
        // `~0` is the documented "any event type" wildcard. Asking about a single
        // type would report someone typing as idle if they had not moved the
        // mouse, which is exactly backwards.
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    static func isScreenLocked() -> Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return info["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}

/// What a popup needs to draw itself. Assembled once when the alert fires, then
/// the photo arrives later and is filled in without disturbing anything else.
struct FlightPopupContent: Equatable {
    let id: String
    let headline: String
    let detail: String
    let typeLabel: String
    var operatorName: String?
    var route: String?
    let trackDegrees: Double?
    let categoryTint: Color
    var photoURL: String?
}

/// Owns the panel. One at a time: a second interesting aircraft replaces the
/// card rather than stacking, because two overlapping cards under one menu bar
/// icon is noise, not information.
@MainActor
final class FlightPopupPresenter: ObservableObject {
    @Published private(set) var content: FlightPopupContent?
    /// Driven by the panel so the card can animate in rather than blink on.
    @Published var isRevealed = false
    /// Hovering holds the card open; the timer resumes when the pointer leaves.
    @Published var isHovered = false { didSet { if !isHovered { scheduleDismiss() } } }

    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    private var onOpenPanel: (() -> Void)?

    static let size = CGSize(width: 300, height: 208)
    static let dwell: TimeInterval = 12

    /// Reduce Motion means no scale and no slide — a cross-fade only. Read at
    /// show time so toggling it in System Settings takes effect immediately.
    var prefersReducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    init(onOpenPanel: (() -> Void)? = nil) {
        self.onOpenPanel = onOpenPanel
    }

    /// Returns false when there is nowhere to anchor, so the caller can post a
    /// normal notification instead of silently dropping the alert.
    @discardableResult
    func show(_ content: FlightPopupContent) -> Bool {
        guard let item = MenuBarAnchor.statusItemFrame() else { return false }

        self.content = content
        let panel = existingPanel()
        panel.setFrame(CGRect(origin: MenuBarAnchor.popupOrigin(for: Self.size, below: item),
                              size: Self.size),
                       display: false)
        panel.orderFrontRegardless()

        isRevealed = false
        withAnimation(prefersReducedMotion
                      ? .easeOut(duration: 0.18)
                      : .spring(response: 0.34, dampingFraction: 0.72)) {
            isRevealed = true
        }
        scheduleDismiss()
        return true
    }

    /// The photo lands after the card is already up. Only the image changes, so
    /// nothing reflows.
    func attachPhoto(_ url: String, to id: String) {
        guard content?.id == id else { return }
        withAnimation(.easeInOut(duration: 0.3)) { content?.photoURL = url }
    }

    /// Operator and route arrive from a lookup that can take a second or two.
    /// The card is up by then; these rows are laid out from the start so filling
    /// them in does not move anything.
    func attachRoute(operatorName: String?, route: String?, to id: String) {
        guard content?.id == id, operatorName != nil || route != nil else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            content?.operatorName = operatorName
            content?.route = route
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        withAnimation(prefersReducedMotion
                      ? .easeIn(duration: 0.15)
                      : .easeIn(duration: 0.2)) {
            isRevealed = false
        }
        // Outlive the animation before pulling the window, or the card vanishes
        // mid-fade.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 260_000_000)
            guard let self, !self.isRevealed else { return }
            self.panel?.orderOut(nil)
            self.content = nil
        }
    }

    func openMainPanel() {
        onOpenPanel?()
        dismiss()
    }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.dwell * 1_000_000_000))
            guard let self, !Task.isCancelled, !self.isHovered else { return }
            self.dismiss()
        }
    }

    private func existingPanel() -> NSPanel {
        if let panel { return panel }
        // .nonactivatingPanel is what keeps the keyboard where it was. Without
        // it a popup would steal focus mid-sentence, which would make this
        // strictly worse than the banner it replaces.
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: Self.size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        // Follow the user across Spaces and sit above a full-screen app —
        // otherwise the card fires into a desktop nobody is looking at.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: FlightPopupView(presenter: self))
        self.panel = panel
        return panel
    }
}
