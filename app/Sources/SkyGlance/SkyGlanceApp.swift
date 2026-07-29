import AppKit
import OverheadKit
import SwiftUI

/// SwiftUI's App lifecycle installs a full main menu (Edit/View/Window/Help) that
/// an accessory app has no use for. LSUIElement keeps it off screen; this also
/// pins the activation policy so the app can never take over the menu bar.
final class AgentDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // `swift run SkyGlance` produces a bare executable with no Info.plist, and
        // UserNotifications traps on a process with no bundle identity. Say so
        // plainly — the raw crash gives no hint that the fix is a build script.
        guard Bundle.main.bundleIdentifier != nil else {
            FileHandle.standardError.write(Data("""
                SkyGlance must run from an app bundle, not as a bare executable.
                macOS refuses notifications to a process with no bundle identity.

                    ./build-app.sh && open build/SkyGlance.app

                """.utf8))
            exit(1)
        }

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

@main
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
}
