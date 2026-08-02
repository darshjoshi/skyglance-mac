import AppKit
import OverheadKit
import SwiftUI

/// SwiftUI's App lifecycle installs a full main menu (Edit/View/Window/Help) and
/// a Dock icon that a menu bar app has no use for. This line is what removes
/// both — and it is now the *only* thing that removes them, because
/// `LSUIElement` is deliberately false in the Info.plist.
///
/// That looks backwards for a menu bar app, and it is load-bearing: with
/// `LSUIElement` true, macOS never registers the app with Location Services, so
/// `requestWhenInUseAuthorization()` shows no dialog and the authorisation
/// status stays `.notDetermined` forever. Setting the policy here instead gets
/// the same accessory behaviour *and* a working "Use My Location", at the cost
/// of a brief Dock icon during launch, before this runs.
final class AgentDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // `SkyGlance --render <path>` draws the panel offscreen and exits. A
        // menu-bar panel can't be screenshotted on a headless or sleeping
        // display, so this is the only way to actually look at the UI.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
            // The panel is used against a dark menu bar far more often than a
            // light one, and Canvas colours resolve through NSAppearance rather
            // than the SwiftUI environment — so it has to be set here to be seen.
            if args.contains("--dark") {
                NSApp.appearance = NSAppearance(named: .darkAqua)
            }
            Task { @MainActor in
                let model = SkyModel()
                // `--at "lat,lon"` renders somewhere other than the configured
                // location, without disturbing it. This is how the README
                // screenshot is made somewhere public rather than someone's house.
                if let a = args.firstIndex(of: "--at"), a + 1 < args.count,
                   case .success(let c) = LocationInput.parse(args[a + 1]) {
                    model.previewOnly(at: c)
                }
                // Give the first poll time to land so the render shows real sky.
                // `--warmup <seconds>` waits longer: trails are built from
                // recorded polls, so they cannot be seen at all in a cold render.
                let warmup = args.firstIndex(of: "--warmup")
                    .flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil } ?? 9
                try? await Task.sleep(nanoseconds: UInt64(warmup * 1_000_000_000))
                // --render-select <hex|first> exercises the detail card, which
                // is otherwise unreachable without a live click.
                if args.contains("--render-select") {
                    model.select(model.nearest.first?.id)
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                }
                print("model at render: overhead=\(model.overhead.count) inbound=\(model.inbound.count) nearest=\(model.nearest.count) total=\(model.totalCount)")
                // NSApp.appearance alone is not enough: SwiftUI's semantic colours
                // resolve from the view environment, which ImageRenderer defaults
                // to light no matter what the app appearance says.
                let renderer = ImageRenderer(
                    content: PanelView(model: model)
                        .environment(\.colorScheme, args.contains("--dark") ? .dark : .light)
                        // The real panel sits on the menu-bar window material,
                        // which ImageRenderer does not draw. Without a backdrop
                        // a dark-mode render is white text on white. Flat greys
                        // rather than a semantic colour: NSColor resolves against
                        // the drawing appearance and comes out light regardless.
                        .background(args.contains("--dark")
                                    ? Color(white: 0.13) : Color(white: 0.98)))
                renderer.scale = 2
                guard let image = renderer.nsImage,
                      let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    FileHandle.standardError.write(Data("render failed\n".utf8))
                    exit(1)
                }
                try? png.write(to: URL(fileURLWithPath: args[i + 1]))
                print("rendered \(png.count) bytes to \(args[i + 1])")
                exit(0)
            }
        }
    }
}

/// The real entry point, so the bundle check happens before AppKit or SwiftUI
/// touch anything.
///
/// `swift run SkyGlance` produces a bare executable with no `Info.plist`, and
/// several of the frameworks this app depends on abort outright on a process
/// with no bundle identity — with an uncaught `NSInternalInconsistencyException`
/// that gives no hint the fix is a build script. Checking inside
/// `applicationDidFinishLaunching` is too late: the app is already dead by then.
@main
enum Entry {
    static func main() {
        guard Bundle.main.bundleIdentifier != nil else {
            FileHandle.standardError.write(Data("""

                SkyGlance must run from an app bundle, not as a bare executable.
                macOS denies bundle-scoped APIs to a process with no identity.

                    ./build-app.sh && open build/SkyGlance.app


                """.utf8))
            exit(1)
        }
        guard !anotherCopyIsRunning() else { exit(0) }
        SkyGlanceApp.main()
    }

    /// Two copies at different paths — a Homebrew install and a build directory,
    /// say — share a bundle identifier but not a location, so LaunchServices
    /// happily runs both. The result is two identical menu bar items, two poll
    /// loops, and double the load on volunteer-run feeds.
    ///
    /// `--render` deliberately spawns a second process, so it is exempt.
    private static func anotherCopyIsRunning() -> Bool {
        guard !CommandLine.arguments.contains("--render"),
              let id = Bundle.main.bundleIdentifier else { return false }
        let mine = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != mine && !$0.isTerminated }
        guard let existing = others.first else { return false }

        // Silent exit would look like the app failing to launch, which is the
        // same failure-looks-normal trap as everywhere else in this project.
        let alert = NSAlert()
        alert.messageText = "SkyGlance is already running"
        alert.informativeText = """
            Another copy is running from \
            \(existing.bundleURL?.path ?? "an unknown location").
            Look for the ✈ in your menu bar.

            Quit that one first if you meant to run this copy instead.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        return true
    }
}

struct SkyGlanceApp: App {
    @NSApplicationDelegateAdaptor(AgentDelegate.self) private var delegate
    @StateObject private var model = SkyModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // .window style gives a real SwiftUI panel instead of an NSMenu, which is
        // what lets the dome exist at all — NSMenu has no layout engine.
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            // The label is instantiated at launch (unlike the panel content, which
            // .window style defers until first click), so it is the only reliable
            // place to notice that setup has never been done.
            Text("✈ \(model.menuBarText)")
                .task {
                    model.refreshNotificationPermission()
                    if !model.isConfigured { openWindow(id: Self.setupWindowID) }
                    await demoPopupIfRequested()
                }
        }
        .menuBarExtraStyle(.window)

        // Setup is a real window, not a sheet on the panel. A sheet presented from
        // a MenuBarExtra(.window) can appear detached or take the panel down with
        // it — and on first run the panel isn't open anyway, so there is nothing
        // to present from.
        Window("SkyGlance Setup", id: SkyGlanceApp.setupWindowID) {
            SetupView(model: model, isFirstRun: !model.isConfigured) {
                NSApp.keyWindow?.close()
            }
            .onAppear {
                // The app is .accessory, so it has to be pulled forward
                // explicitly or the window opens behind whatever you were doing.
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }

    static let setupWindowID = "setup"

    /// `SkyGlance --demo-popup [seconds]` waits for a poll to land and then shows
    /// a popup for the nearest aircraft.
    ///
    /// The `⋯` menu has the same command, but a menu inside a `MenuBarExtra`
    /// panel cannot be driven by accessibility scripting, so there is no way to
    /// look at this thing repeatedly without a flag. Same reason `--render`
    /// exists.
    @MainActor
    private func demoPopupIfRequested() async {
        let args = CommandLine.arguments
        guard args.contains("--demo-popup") else { return }
        // `--at "lat,lon"` works here as it does for --render, so a screenshot
        // for the README is taken over somewhere public rather than over
        // whoever is running it.
        if let a = args.firstIndex(of: "--at"), a + 1 < args.count,
           case .success(let c) = LocationInput.parse(args[a + 1]) {
            model.previewOnly(at: c)
        }
        let wait = args.firstIndex(of: "--demo-popup")
            .flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil } ?? 10
        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        model.showTestPopup()
    }
}
