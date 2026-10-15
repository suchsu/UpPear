import AppKit
import ScreenCaptureKit
import SwiftUI

@main
struct UpPearApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = UpdateModel(isFixture: ProcessInfo.processInfo.arguments.contains("--ui-smoke"))

    var body: some Scene {
        Window("UpPear", id: "main") {
            MainWindow(model: model)
                .frame(minWidth: 940, minHeight: 600)
                .task {
                    model.start()
                    await openSmokeStatusMenuIfRequested()
                    await captureSmokeIfRequested()
                }
        }
        .defaultSize(width: 1160, height: 740)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于 UpPear") { delegate.showAbout() }
            }
            CommandGroup(after: .newItem) {
                Button("检查软件更新") { model.checkNow() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.isChecking || model.isUpgrading)
            }
            CommandGroup(replacing: .appTermination) {
                Button("退出 UpPear") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command).disabled(model.isUpgrading)
            }
        }
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            Label(model.updateCount > 0 ? "\(model.updateCount)" : "UpPear", systemImage: "arrow.up.circle")
                .accessibilityIdentifier("uppear-status-item")
                .accessibilityLabel("UpPear，\(model.updateCount) 个可用更新")
        }
        Settings { SettingsView(model: model) }
    }

    @MainActor private func openSmokeStatusMenuIfRequested() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard model.isFixture, arguments.contains("--open-status-menu") else { return }

        let logURL: URL? = arguments.firstIndex(of: "--status-menu-log").flatMap { index in
            arguments.indices.contains(index + 1) ? URL(fileURLWithPath: arguments[index + 1]) : nil
        }
        func record(_ message: String) {
            guard let logURL else { return }
            let line = Data((message + "\n").utf8)
            try? FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: logURL.path),
               let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                _ = try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: logURL, options: .atomic)
            }
        }

        // This explicit smoke-only hook opens UpPear's own MenuBarExtra for
        // accessibility validation. It never runs in normal launches.
        record("arguments=\(arguments.joined(separator: " "))")
        try? await Task.sleep(for: .seconds(2))

        func statusButtons(in view: NSView) -> [NSStatusBarButton] {
            var buttons = (view as? NSStatusBarButton).map { [$0] } ?? []
            for child in view.subviews {
                buttons.append(contentsOf: statusButtons(in: child))
            }
            return buttons
        }

        let candidates = NSApplication.shared.windows.flatMap { window in
            (window.contentView.map(statusButtons(in:)) ?? []).map { (window, $0) }
        }
        record("status-buttons=\(candidates.count) windows=\(NSApplication.shared.windows.map { NSStringFromClass(type(of: $0)) }.joined(separator: ","))")
        guard let (window, button) = candidates.first else {
            record("result=status-button-not-found")
            return
        }

        record("button-window=\(NSStringFromClass(type(of: window))) frame=\(NSStringFromRect(button.frame)) title=\(button.title)")
        record("result=performClick-started")
        button.performClick(nil)
        record("result=performClick-returned")
    }

    @MainActor private func captureSmokeIfRequested() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard model.isFixture, let index = arguments.firstIndex(of: "--capture"), arguments.indices.contains(index + 1) else { return }
        let destination = URL(fileURLWithPath: arguments[index + 1])
        let diagnostic = destination.appendingPathExtension("log")
        var captured = false

        func record(_ message: String) {
            let line = Data((message + "\n").utf8)
            if FileManager.default.fileExists(atPath: diagnostic.path),
               let handle = try? FileHandle(forWritingTo: diagnostic) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                _ = try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: diagnostic, options: .atomic)
            }
        }

        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // NavigationSplitView sets the native window title from the selected filter,
        // so it may be "可用更新", "Homebrew", or "Sparkle" instead of "UpPear".
        // Resolve the visible main window by its SwiftUI scene identifier when
        // available, then fall back to the key/visible window in this smoke-only app.
        // Capture only this process's matching window with ScreenCaptureKit so
        // SwiftUI's layer-backed content is fully composited in the PNG.
        record("arguments=\(arguments.joined(separator: " "))")
        record("app-windows=\(NSApplication.shared.windows.map { "{class:\(NSStringFromClass(type(of: $0))),title:\($0.title),id:\($0.identifier?.rawValue ?? "nil"),number:\($0.windowNumber),visible:\($0.isVisible),frame:\(NSStringFromRect($0.frame))}" }.joined(separator: ";"))")
        for attempt in 1...40 {
            let visibleWindows = NSApplication.shared.windows.filter(\.isVisible)
            let window = visibleWindows.first(where: { $0.identifier?.rawValue == "main" })
                ?? visibleWindows.first(where: \.isKeyWindow)
                ?? visibleWindows.first

            if let window {
                record("attempt=\(attempt) title=\(window.title) id=\(window.identifier?.rawValue ?? "nil") number=\(window.windowNumber) key=\(window.isKeyWindow) bounds=\(NSStringFromRect(window.frame)) content=\(NSStringFromRect(window.contentView?.bounds ?? .zero))")
                window.displayIfNeeded()
                do {
                    let shareableContent = try await SCShareableContent.currentProcess
                    guard let shareableWindow = shareableContent.windows.first(where: {
                        $0.windowID == CGWindowID(window.windowNumber)
                    }) else {
                        record("attempt=\(attempt) current-process-window-not-found")
                        _ = try? await Task.sleep(for: .milliseconds(250))
                        continue
                    }
                    let filter = SCContentFilter(desktopIndependentWindow: shareableWindow)
                    let configuration = SCStreamConfiguration()
                    let scale = NSScreen.screens.first(where: { $0.frame.intersects(window.frame) })?.backingScaleFactor ?? 1
                    configuration.width = Int(window.frame.width * scale)
                    configuration.height = Int(window.frame.height * scale)
                    configuration.showsCursor = false
                    let image = try await SCScreenshotManager.captureImage(
                        contentFilter: filter,
                        configuration: configuration
                    )
                    let representation = NSBitmapImageRep(cgImage: image)
                    if let png = representation.representation(using: .png, properties: [:]) {
                        do {
                            try FileManager.default.createDirectory(
                                at: destination.deletingLastPathComponent(),
                                withIntermediateDirectories: true
                            )
                            try png.write(to: destination, options: .atomic)
                            record("captured=\(image.width)x\(image.height) bytes=\(png.count) path=\(destination.path)")
                            captured = true
                            break
                        } catch {
                            record("write-error=\(error)")
                            break
                        }
                    } else {
                        record("attempt=\(attempt) png-encoding-failed")
                    }
                } catch {
                    record("attempt=\(attempt) capture-error=\(error)")
                }
            } else {
                record("attempt=\(attempt) no-visible-app-window windows=\(NSApplication.shared.windows.map { "{title:\($0.title),id:\($0.identifier?.rawValue ?? "nil"),visible:\($0.isVisible),number:\($0.windowNumber)}" }.joined(separator: ";"))")
            }

            try? await Task.sleep(for: .milliseconds(250))
        }

        record(captured ? "result=success" : "result=failure")
        if arguments.contains("--exit-after-capture") { NSApplication.shared.terminate(nil) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func showAbout() {
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: "UpPear",
            .applicationVersion: "1.0.0",
            .credits: NSAttributedString(string: "作者：suchsu\n基于 Pearcleaner 5.4.3 的更新功能\n原作者：Alin Lupascu / alienator88\nApache 2.0 + Commons Clause\nSparkle 2.8.0 · MIT\n\nUpPear 是独立社区衍生项目。")
        ])
    }
}
