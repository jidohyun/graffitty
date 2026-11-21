// Capture only the private demo chromium, one image per Movie Maker frame.
// No desktop capture, global mouse events, or Accessibility permission.
import AppKit
import CoreGraphics
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

enum CaptureError: Error { case invalidRequest(String) }

@main struct NativeWindowCapture {
    static func write(_ value: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            .write(to: url, options: .atomic)
    }

    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        Task { @MainActor in
            await run()
            exit(0)
        }
        application.run()
    }

    @MainActor static func run() async {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let arguments = CommandLine.arguments
        if arguments.contains("--request-access") {
            print("Screen Recording access: \(CGRequestScreenCaptureAccess())")
            return
        }
        if arguments.contains("--check") {
            print("Screen Recording access: \(CGPreflightScreenCaptureAccess())")
            exit(CGPreflightScreenCaptureAccess() ? 0 : 2)
        }
        let selfTest = arguments.contains("--self-test")
        guard arguments.count == (selfTest ? 3 : 2) else {
            fputs("Usage: native-window-capture DIRECTORY | --check | --request-access\n", stderr)
            exit(2)
        }
        let directory = URL(fileURLWithPath: arguments.last!, isDirectory: true)
        let response = directory.appendingPathComponent("response.json")
        var previous = -1
        var filter: SCContentFilter?
        var configuration: SCStreamConfiguration?
        var selected: SCWindow?
        var testWindow: NSWindow?
        do {
            guard CGPreflightScreenCaptureAccess() else {
                throw CaptureError.invalidRequest("Screen Recording access is required for the native chromium window")
            }
            try write(["ready": true], to: directory.appendingPathComponent("ready.json"))
            if selfTest {
                let window = NSWindow(contentRect: NSRect(x: 120, y: 200, width: 600, height: 400),
                                      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
                window.title = "Graffitty capture test"
                window.contentView = NSTextField(labelWithString: "Private capture test — no desktop pixels")
                window.makeKeyAndOrderFront(nil)
                application.activate(ignoringOtherApps: true)
                testWindow = window
                try await Task.sleep(nanoseconds: 300_000_000)
                try write(["frame": 0, "pid": ProcessInfo.processInfo.processIdentifier],
                          to: directory.appendingPathComponent("request.json"))
            }
            while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("stop").path) {
                guard let data = try? Data(contentsOf: directory.appendingPathComponent("request.json")),
                      let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let frame = request["frame"] as? Int, frame != previous,
                      let pid = request["pid"] as? Int, pid > 0 else {
                    try await Task.sleep(nanoseconds: 2_000_000)
                    continue
                }
                try write(["frame": frame, "phase": "locate-window"], to: directory.appendingPathComponent("status.json"))
                if filter == nil {
                    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                    let windows = content.windows.filter {
                        Int($0.owningApplication?.processID ?? -1) == pid && $0.windowLayer == 0
                            && $0.frame.width > 200 && $0.frame.height > 100
                    }
                    guard windows.count == 1, let window = windows.first else {
                        throw CaptureError.invalidRequest("Expected exactly one visible demo window for PID \(pid); found \(windows.count)")
                    }
                    selected = window
                    let windowFilter = SCContentFilter(desktopIndependentWindow: window)
                    filter = windowFilter
                    let config = SCStreamConfiguration()
                    config.width = Int(windowFilter.contentRect.width * CGFloat(windowFilter.pointPixelScale))
                    config.height = Int(windowFilter.contentRect.height * CGFloat(windowFilter.pointPixelScale))
                    config.showsCursor = false
                    config.ignoreShadowsSingleWindow = true
                    config.shouldBeOpaque = false
                    configuration = config
                    try write(["pid": pid, "window_id": window.windowID,
                               "width": config.width, "height": config.height,
                               "point_pixel_scale": windowFilter.pointPixelScale,
                               "title": window.title ?? ""], to: directory.appendingPathComponent("window.json"))
                }
                try write(["frame": frame, "phase": "capture-image"], to: directory.appendingPathComponent("status.json"))
                guard Int(selected?.owningApplication?.processID ?? -1) == pid, let filter, let configuration else {
                    throw CaptureError.invalidRequest("Capture target changed")
                }
                // Automation and the replay can change foreground applications.
                // Reassert focus before capturing this private chromium window.
                guard let chromium = NSRunningApplication(processIdentifier: pid_t(pid)) else {
                    throw CaptureError.invalidRequest("The native chromium exited")
                }
                if !chromium.isActive {
                    chromium.activate(options: [])
                    for _ in 0..<50 {
                        if chromium.isActive { break }
                        try await Task.sleep(nanoseconds: 10_000_000)
                    }
                    guard chromium.isActive else {
                        throw CaptureError.invalidRequest("The native chromium could not take focus")
                    }
                    // Allow WindowServer to draw the newly active controls.
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                let path = directory.appendingPathComponent(String(format: "%06d.png", frame))
                guard let destination = CGImageDestinationCreateWithURL(path as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                    throw CaptureError.invalidRequest("Cannot write native window frame")
                }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else {
                    throw CaptureError.invalidRequest("Cannot finalize native window frame")
                }
                try write(["frame": frame, "pid": pid, "width": image.width, "height": image.height], to: response)
                previous = frame
                if selfTest {
                    testWindow?.orderOut(nil)
                    return
                }
            }
        } catch {
            try? write(["error": String(describing: error)], to: response)
            fputs("Native window capture: \(error)\n", stderr)
            exit(1)
        }
    }
}
