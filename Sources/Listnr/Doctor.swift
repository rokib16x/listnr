import ArgumentParser
import AVFoundation
import CoreGraphics
import Foundation

enum CheckStatus {
    case ok
    case warn(String)
    case fail(String)
}

struct Check {
    let name: String
    let status: CheckStatus
    let remediation: String?
}

enum DoctorReport {
    static func run() -> [Check] {
        [
            checkAppleSilicon(),
            checkMicrophone(),
            checkScreenRecording(),
            checkHeadsetHint(),
        ]
    }

    static func checkAppleSilicon() -> Check {
        var size = 0
        sysctlbyname("hw.optional.arm64", nil, &size, nil, 0)
        var arm64: Int32 = 0
        if size == MemoryLayout<Int32>.size {
            sysctlbyname("hw.optional.arm64", &arm64, &size, nil, 0)
        }
        if arm64 == 1 {
            return Check(name: "apple silicon", status: .ok, remediation: nil)
        }
        return Check(
            name: "apple silicon",
            status: .fail("Intel Mac detected"),
            remediation: "Listnr requires Apple Silicon (M1 or newer) for on-device WhisperKit / ANE"
        )
    }

    static func checkMicrophone() -> Check {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return Check(name: "microphone", status: .ok, remediation: nil)
        case .notDetermined:
            return Check(
                name: "microphone",
                status: .warn("not yet requested, will prompt on first capture"),
                remediation: "run `listnr setup` or start a session once; macOS will prompt"
            )
        case .denied, .restricted:
            return Check(
                name: "microphone",
                status: .fail("denied"),
                remediation: "System Settings → Privacy & Security → Microphone → enable for your terminal / Listnr"
            )
        @unknown default:
            return Check(name: "microphone", status: .fail("unknown state"), remediation: nil)
        }
    }

    /// System / speaker capture on modern macOS goes through ScreenCaptureKit / TCC screen recording.
    static func checkScreenRecording() -> Check {
        if CGPreflightScreenCaptureAccess() {
            return Check(name: "screen recording (system audio)", status: .ok, remediation: nil)
        }
        return Check(
            name: "screen recording (system audio)",
            status: .fail("not granted"),
            remediation: "System Settings → Privacy & Security → Screen & System Audio Recording → enable for your terminal / Listnr. Needed to capture speaker output (teammates)."
        )
    }

    static func checkHeadsetHint() -> Check {
        Check(
            name: "headset",
            status: .warn("use a closed headset for clean multi-speaker notes"),
            remediation: "Open speakers leak remote voices into the mic and hurt You vs Speaker 1/2/3 separation"
        )
    }

    static func print(_ checks: [Check]) {
        for c in checks {
            let (mark, label): (String, String) = {
                switch c.status {
                case .ok: return ("✓", "ok")
                case .warn(let msg): return ("!", msg)
                case .fail(let msg): return ("✗", msg)
                }
            }()
            Swift.print("\(mark) \(c.name): \(label)")
            if let r = c.remediation {
                Swift.print("    → \(r)")
            }
        }
    }

    /// Hard fails block startup. Warnings do not.
    static func allOK(_ checks: [Check]) -> Bool {
        checks.allSatisfy {
            if case .fail = $0.status { return false }
            return true
        }
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check Apple Silicon, microphone, and system-audio (screen recording) permissions."
    )

    func run() throws {
        let checks = DoctorReport.run()
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
            throw ExitCode(1)
        }
    }
}
