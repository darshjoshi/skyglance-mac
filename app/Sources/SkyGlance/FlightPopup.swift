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
            let low = visible.minX + margin
            let high = visible.maxX - size.width - margin
            // On a screen narrower than the card plus both margins the bounds
            // cross over, and a bare min(max(…)) would return the *lower* bound,
            // pushing the card further off-screen than leaving it alone would.
            x = high >= low ? min(max(x, low), high) : max(x, visible.minX)
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

    /// VoiceOver or Switch Control is driving.
    ///
    /// The card is unreachable for both: it never becomes key, so the VoiceOver
    /// cursor never lands on it, nothing posts an announcement, and its only
    /// pause affordance is `.onHover` — a mouse. Neither user can perceive or
    /// act on it before the dwell expires, so showing one *instead of* a
    /// notification silently removes the alert entirely. Routing them back to
    /// the notification restores exactly what they had before popups existed.
    ///
    /// Read fresh rather than observed. Both are KVO-observable, but they change
    /// rarely and the routing decision re-runs every poll, so a stale value costs
    /// at most one three-second tick — the same trade already made for
    /// `accessibilityDisplayShouldReduceMotion`. Voice Control has no equivalent
    /// flag and cannot be detected.
    static var assistiveTechInUse: Bool {
        NSWorkspace.shared.isVoiceOverEnabled || NSWorkspace.shared.isSwitchControlEnabled
    }
}

/// Which channel an alert should take.
///
/// Pure and parameterised so the decision can be tested — the accessibility
/// routing above is the kind of thing that must not rely on someone remembering
/// to switch VoiceOver on before merging.
enum AlertRouting {
    /// Every condition must hold. Note `menuBarAnchorAvailable`: without it the
    /// channel was chosen before anyone checked whether the popup could actually
    /// be placed, so a hidden menu bar item meant a real notification governed
    /// by the popup's looser budget.
    static func prefersPopup(popupsEnabled: Bool,
                             userIsPresent: Bool,
                             assistiveTechInUse: Bool,
                             menuBarAnchorAvailable: Bool) -> Bool {
        popupsEnabled && userIsPresent && !assistiveTechInUse && menuBarAnchorAvailable
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

    /// Identifies one *showing* of the card, not one aircraft.
    ///
    /// Keying late-arriving enrichment on the aircraft hex alone let a slow
    /// lookup from an earlier card overwrite a later card for the same aircraft.
    /// A token that changes on every `show()` closes that without needing a
    /// timestamp or any comparison beyond equality.
    struct Showing: Equatable {
        fileprivate let sequence: Int
    }

    private var showingSequence = 0
    private var currentShowing = Showing(sequence: 0)

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

    /// Returns the token for this showing, or nil when there is nowhere to
    /// anchor — so the caller can post a normal notification instead of silently
    /// dropping the alert. Pass the token back to `attachPhoto`/`attachRoute` so
    /// a slow lookup cannot land on a card that has since been replaced.
    @discardableResult
    func show(_ content: FlightPopupContent) -> Showing? {
        guard let item = MenuBarAnchor.statusItemFrame() else { return nil }

        showingSequence += 1
        currentShowing = Showing(sequence: showingSequence)
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
        return currentShowing
    }

    /// The photo lands after the card is already up. Only the image changes, so
    /// nothing reflows.
    func attachPhoto(_ url: String, for showing: Showing) {
        guard showing == currentShowing else { return }
        withAnimation(.easeInOut(duration: 0.3)) { content?.photoURL = url }
    }

    /// Operator and route arrive from a lookup that can take a second or two.
    /// The card is up by then; these rows are laid out from the start so filling
    /// them in does not move anything.
    func attachRoute(operatorName: String?, route: String?, for showing: Showing) {
        guard showing == currentShowing, operatorName != nil || route != nil else { return }
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
