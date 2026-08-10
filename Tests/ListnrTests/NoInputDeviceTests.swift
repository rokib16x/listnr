import AVFoundation
import XCTest
@testable import ListnrCore

/// A Mac mini has no built-in microphone, so an AirPods disconnect leaves the
/// machine with no input device at all. In that state `installTap` and
/// `AVAudioEngine.start()` both raise Objective-C exceptions, which Swift cannot
/// catch: the process died with SIGABRT and a CoreAudio assertion
/// ("required condition is false: format.sampleRate == inputHWFormat.sampleRate")
/// instead of saying that nothing was plugged in.
///
/// The old code reached that crash because when the input format read 0 Hz / 0 ch
/// it fell back to the node's *output* format, which still read a plausible
/// 44.1 kHz stereo — a number with nothing to do with any input hardware.
final class NoInputDeviceTests: XCTestCase {

    func testNoInputDeviceHasItsOwnError() {
        let message = MicCapture.CaptureError.noInputDevice.errorDescription
        let text = try? XCTUnwrap(message)
        XCTAssertNotNil(text)
        // It has to name the fix, because the machine cannot resolve this itself.
        XCTAssertTrue(text!.lowercased().contains("no microphone"), text!)
        XCTAssertTrue(text!.contains("Sound → Input"), text!)
    }

    /// Distinct from an invalid format: one means "connect something", the other
    /// means "something is connected but unusable".
    func testItIsDistinctFromAnInvalidFormat() {
        XCTAssertNotEqual(
            MicCapture.CaptureError.noInputDevice.errorDescription,
            MicCapture.CaptureError.invalidInputFormat.errorDescription
        )
    }

    func testProbingForAnInputDeviceIsSafe() {
        // Whatever the host has attached, this must answer rather than trap.
        _ = AudioDevices.hasInputDevice()
    }

    // MARK: - Doctor

    func testDoctorWarnsWhenTheGrantExistsButNoDeviceDoes() {
        let check = DoctorReport.checkMicrophone(hasDevice: false)
        guard case .authorized = AVCaptureDevice.authorizationStatus(for: .audio) else {
            // Without the grant the permission state dominates, which is correct:
            // there is nothing to say about a device you may not read.
            return
        }
        guard case .warn(let message) = check.status else {
            return XCTFail("expected a warning, got \(check.status)")
        }
        XCTAssertTrue(message.contains("no input device"), message)
        XCTAssertNotNil(check.remediation)
    }

    /// Speaker-only capture is still worth doing, so a missing mic must not stop
    /// a meeting from being recorded.
    func testAMissingMicrophoneNeverBlocksStartup() {
        XCTAssertTrue(DoctorReport.allOK([DoctorReport.checkMicrophone(hasDevice: false)]))
    }

    func testDoctorIsUnchangedWhenADeviceIsPresent() {
        let check = DoctorReport.checkMicrophone(hasDevice: true)
        if case .authorized = AVCaptureDevice.authorizationStatus(for: .audio) {
            guard case .ok = check.status else {
                return XCTFail("expected ok, got \(check.status)")
            }
        }
    }
}
