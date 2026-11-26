import AppKit
import SwiftUI
import DhikrCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let ambient = AmbientPanel()
    let controller = SessionController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        terminateSiblingInstances()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "ٱللَّٰه"
            button.font = NSFont(name: "GeezaPro", size: 15) ?? .menuBarFont(ofSize: 0)
            button.action = #selector(statusItemClicked)
            button.target = self
            // left click toggles the ambient panel; right click shows the app menu
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        controller.onCountChange = { [weak self] count in
            // the menu bar itself is the ambient display: live count during sessions
            self?.statusItem.button?.title = count > 0 ? "ٱللَّٰه \(count)" : "ٱللَّٰه"
        }
        ambient.onSpace = { [controller] in controller.tap() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, let item = self.statusItem else { return }
            let visible = item.isVisible
            let msg = "statusItem.isVisible=\(visible) length=\(item.length)"
            NSLog(msg)
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Dhikr", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? (msg + "\n").write(to: dir.appendingPathComponent("visibility.log"),
                atomically: true, encoding: .utf8)
        }
        controller.onSessionStarted = { [weak self] in
            // voice sessions only: tap-mode users need the panel open to tap.
            // give the session view a beat to materialize, then fade away —
            // from here the menu bar count is the ambient display
            guard let self, self.controller.voiceAvailable else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
                self?.ambient.close()
            }
        }
        controller.onMilestone = { Feedback.milestone() }
        controller.onTargetReached = { Feedback.targetReached() }
        ReminderManager.shared.requestAuthorization()
        ReminderManager.shared.reschedule()
        attachVoiceIfPossible()
    }

    /// Voice recognition: load the CoreML transcriber (~150ms, 131MB models) on a
    /// background thread, then wire the recognition pipeline into the controller.
    private func attachVoiceIfPossible() {
        Task.detached(priority: .userInitiated) { [controller] in
            do {
                let transcriber = try NawahCoreMLTranscriber.bundled()
                let vad: VADScoring
                let agcEnabled: Bool
                do {
                    vad = try SileroVAD.bundled()
                    agcEnabled = true
                } catch {
                    NSLog("Silero VAD unavailable: \(error) — falling back to energy VAD")
                    vad = EnergyVAD()
                    // AGC raises the measured noise floor into the energy VAD's
                    // trigger range; the fallback keeps the proven raw pipeline.
                    agcEnabled = false
                }
                let recognizer = NawahRecognizer(vad: vad, transcriber: transcriber, agcEnabled: agcEnabled)
                await MainActor.run {
                    controller.attachRecognizer(recognizer)
                }
            } catch {
                NSLog("Voice recognition unavailable: \(error) — tap mode still works")
            }
        }
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            ambient.toggle(below: statusItem, content: SessionPanelView(controller: controller))
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        let quit = NSMenuItem(title: "Quit Dhikr", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        // popUp anchored inside the button — reliable unlike the menu/performClick/nil dance
        if let button = statusItem.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 6), in: button)
        }
    }

    /// catch-all: ANY graceful termination path (AppleEvent quit, system shutdown,
    /// activity monitor Quit) removes the icon here — quitGracefully is not the
    /// only way the app can exit
    func applicationWillTerminate(_ notification: Notification) {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }

    @objc private func quit() {
        quitGracefully()
    }

    /// Deterministic quit, orchestrated here because the status item lives here.
    /// 1. remove the menu bar icon FIRST — instant feedback, and no ghost icon:
    ///    macOS frequently fails to clean up status items when a process dies,
    ///    so we never rely on death-cleanup
    /// 2. stop capture off the terminate path so AVFoundation teardown can't
    ///    deadlock AppKit termination
    /// 3. graceful terminate + hard exit fallback — death within ~2s regardless
    func quitGracefully() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
        controller.shutdownAudio()
        NSApp.terminate(nil)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            exit(0)
        }
    }

    /// Exactly one instance may live. A leftover instance is worse than useless:
    /// LaunchServices dedupes `open` by bundle id, so a zombie makes the app
    /// "refuse to start" — every new launch no-ops into the dead one. The fresh
    /// instance therefore retires any others at launch, gracefully then forcibly.
    private func terminateSiblingInstances() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let siblings = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != me }
        for sibling in siblings {
            NSLog("retiring older Dhikr instance pid \(sibling.processIdentifier)")
            sibling.terminate()
        }
        guard !siblings.isEmpty else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                where app.processIdentifier != me {
                app.forceTerminate()
            }
        }
    }
}
