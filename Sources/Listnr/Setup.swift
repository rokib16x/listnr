import ArgumentParser
import AVFoundation
import CoreGraphics
import Foundation

/// Carries a permission result out of a completion handler on another thread.
private final class PermissionOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var granted: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }
}

struct Setup: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Walk through first-run permission setup for Listnr."
    )

    func run() throws {
        print("listnr setup")
        print("============")
        print()
        print("Listnr needs two permissions for meeting capture:")
        print("  1. Microphone — your voice (Lane A / You)")
        print("  2. Screen & System Audio Recording — speaker output (Lane B / teammates)")
        print()
        print("These usually attach to your terminal (or the Listnr app), not a cloud service.")
        print("Use a closed headset so teammates do not leak into your mic.")
        print()

        try waitForMicrophone()
        print()
        try waitForScreenRecording()
        print()
        print("✓ permissions look ready. Next: M1 dual capture (`listnr start` will grow).")
        print("  Tip: run `listnr doctor` anytime to re-check.")
    }

    private func waitForMicrophone() throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            print("✓ microphone already granted")
            return
        case .denied, .restricted:
            print("✗ microphone is denied — macOS will not re-prompt.")
            print("  opening Settings → Privacy & Security → Microphone...")
            openSettings("Privacy_Microphone")
            print("  enable your terminal / Listnr, then re-run `listnr setup`.")
            throw ExitCode(1)
        case .notDetermined:
            print("→ requesting microphone access...")
            let semaphore = DispatchSemaphore(value: 0)
            let outcome = PermissionOutcome()
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                outcome.granted = ok
                semaphore.signal()
            }
            semaphore.wait()
            if outcome.granted {
                print("  ✓ microphone granted")
            } else {
                print("  ✗ microphone denied")
                throw ExitCode(1)
            }
        @unknown default:
            print("? microphone in unknown state")
        }
    }

    private func waitForScreenRecording() throws {
        if CGPreflightScreenCaptureAccess() {
            print("✓ screen recording (system audio) already granted")
            return
        }

        print("→ requesting screen / system audio access...")
        let granted = CGRequestScreenCaptureAccess()
        if granted || CGPreflightScreenCaptureAccess() {
            print("  ✓ screen recording granted")
            return
        }

        print("  ✗ not granted yet (macOS often needs a Settings toggle + re-run).")
        print("  opening Settings → Privacy & Security → Screen & System Audio Recording...")
        openSettings("Privacy_ScreenCapture")
        print("  enable your terminal / Listnr, then re-run `listnr setup`.")
        throw ExitCode(1)
    }

    private func openSettings(_ pane: String) {
        let url = "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = [url]
        try? task.run()
    }
}
