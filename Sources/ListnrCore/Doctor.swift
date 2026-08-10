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
            checkSystemAudioOutput(device: OutputDevice.current()),
            checkHeadsetHint(),
        ]
    }

    /// Lane B depends on what the Mac is playing through, not only on the grant.
    ///
    /// A Bluetooth headset has been observed delivering a full session of silent
    /// ScreenCaptureKit buffers: the stream starts, reports its duration, and
    /// every sample is zero. Nothing in the grant or the model explains that, so
    /// the transport is worth naming before a meeting rather than after.
    ///
    /// Deliberately a warning. Bluetooth output is not certain to break Lane B on
    /// every Mac or every device, and blocking startup over a maybe would be
    /// worse than the silence it guards against.
    static func checkSystemAudioOutput(device: OutputDeviceInfo?) -> Check {
        guard let device else {
            return Check(
                name: "system audio output",
                status: .warn("no default output device found"),
                remediation: "System Settings → Sound → Output → pick a device"
            )
        }

        switch device.transport {
        case .bluetooth:
            return Check(
                name: "system audio output",
                status: .warn("\(device.name) is \(device.transport.label)"),
                remediation: "Bluetooth output has been seen to give ScreenCaptureKit silent audio, "
                    + "so remote voices go missing with no error. If Lane B is silent, switch "
                    + "System Settings → Sound → Output to a built-in, wired, or USB device."
            )
        case .virtualDevice:
            return Check(
                name: "system audio output",
                status: .warn("\(device.name) is \(device.transport.label)"),
                remediation: "Loopback and aggregate devices can route speaker audio away from "
                    + "ScreenCaptureKit. If Lane B is silent, select a physical output device."
            )
        case .builtIn, .usb, .airPlay, .other:
            return Check(
                name: "system audio output",
                status: .ok,
                remediation: nil
            )
        }
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

    static func checkMicrophone(hasDevice: Bool = AudioDevices.hasInputDevice()) -> Check {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            // Granted access to a microphone that is not there. A Mac mini or
            // Studio has no built-in mic, so an unpaired headset leaves nothing
            // for Lane A to record, and the permission says nothing about it.
            // A warning, not a failure: capturing only the speaker lane is still
            // a useful thing to do.
            guard hasDevice else {
                return Check(
                    name: "microphone",
                    status: .warn("granted, but no input device is connected"),
                    remediation: "Nothing will be recorded for you (Lane A). Connect a microphone or headset, "
                        + "then check System Settings → Sound → Input."
                )
            }
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
