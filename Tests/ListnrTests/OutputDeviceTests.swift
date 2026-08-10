import CoreAudio
import XCTest
@testable import ListnrCore

/// A session on AirPods captured 243.9 seconds of system audio in which every
/// sample was zero. ScreenCaptureKit reported no error, `doctor` reported no
/// problem, and the transcript simply had no remote speakers in it. The output
/// transport was the one signal that distinguished a working configuration from
/// that one, and nothing surfaced it.
final class OutputDeviceTests: XCTestCase {

    // MARK: - Transport classification

    func testClassifiesBluetooth() {
        XCTAssertEqual(AudioTransport(rawTransport: kAudioDeviceTransportTypeBluetooth), .bluetooth)
        XCTAssertEqual(AudioTransport(rawTransport: kAudioDeviceTransportTypeBluetoothLE), .bluetooth)
    }

    func testClassifiesPhysicalTransports() {
        XCTAssertEqual(AudioTransport(rawTransport: kAudioDeviceTransportTypeBuiltIn), .builtIn)
        XCTAssertEqual(AudioTransport(rawTransport: kAudioDeviceTransportTypeUSB), .usb)
        XCTAssertEqual(AudioTransport(rawTransport: kAudioDeviceTransportTypeAirPlay), .airPlay)
    }

    /// Loopback tools install these, and they can route audio away from the tap.
    func testClassifiesVirtualAndAggregateTogether() {
        XCTAssertEqual(AudioTransport(rawTransport: kAudioDeviceTransportTypeVirtual), .virtualDevice)
        XCTAssertEqual(AudioTransport(rawTransport: kAudioDeviceTransportTypeAggregate), .virtualDevice)
    }

    func testUnrecognisedTransportIsPreservedRatherThanGuessed() {
        let raw: UInt32 = 0x1234_5678
        XCTAssertEqual(AudioTransport(rawTransport: raw), .other(raw))
    }

    func testEveryTransportHasALabel() {
        let all: [AudioTransport] = [
            .builtIn, .bluetooth, .usb, .airPlay, .virtualDevice, .other(0),
        ]
        for transport in all {
            XCTAssertFalse(transport.label.isEmpty, "\(transport)")
        }
    }

    // MARK: - The doctor check

    private func check(_ transport: AudioTransport, name: String = "Test Device") -> Check {
        DoctorReport.checkSystemAudioOutput(
            device: OutputDeviceInfo(name: name, transport: transport)
        )
    }

    private func isWarn(_ check: Check) -> Bool {
        if case .warn = check.status { return true }
        return false
    }

    private func isOK(_ check: Check) -> Bool {
        if case .ok = check.status { return true }
        return false
    }

    /// The exact configuration that lost a session.
    func testBluetoothOutputWarns() {
        let result = check(.bluetooth, name: "FiascoPods")
        XCTAssertTrue(isWarn(result))
        XCTAssertTrue(result.status.message.contains("FiascoPods"), result.status.message)
        XCTAssertNotNil(result.remediation)
        XCTAssertTrue(
            result.remediation!.contains("Sound → Output"),
            "the remediation has to say where to change it"
        )
    }

    func testVirtualDeviceWarns() {
        XCTAssertTrue(isWarn(check(.virtualDevice, name: "BlackHole 2ch")))
    }

    func testPhysicalOutputPasses() {
        XCTAssertTrue(isOK(check(.builtIn, name: "Mac mini Speakers")))
        XCTAssertTrue(isOK(check(.usb, name: "Scarlett Solo")))
        XCTAssertTrue(isOK(check(.airPlay)))
        XCTAssertTrue(isOK(check(.other(0))))
    }

    func testMissingOutputDeviceWarns() {
        XCTAssertTrue(isWarn(DoctorReport.checkSystemAudioOutput(device: nil)))
    }

    /// A maybe must not stop a meeting from being recorded.
    func testOutputTransportNeverBlocksStartup() {
        let all: [AudioTransport] = [
            .builtIn, .bluetooth, .usb, .airPlay, .virtualDevice, .other(0),
        ]
        for transport in all {
            XCTAssertTrue(
                DoctorReport.allOK([check(transport)]),
                "\(transport) must not be a hard failure"
            )
        }
        XCTAssertTrue(DoctorReport.allOK([DoctorReport.checkSystemAudioOutput(device: nil)]))
    }

    // MARK: - Wiring

    func testTheCheckIsPartOfTheReport() {
        let names = DoctorReport.run().map(\.name)
        XCTAssertTrue(names.contains("system audio output"), "\(names)")
    }

    /// Reading the real device must not crash or hang, whatever is plugged in.
    func testReadingTheCurrentDeviceIsSafe() {
        if let device = OutputDevice.current() {
            XCTAssertFalse(device.name.isEmpty)
        }
    }
}

/// Test-only access to a check's message, so assertions can read what the user
/// would see instead of restating it.
extension CheckStatus {
    var message: String {
        switch self {
        case .ok: return "ok"
        case .warn(let m), .fail(let m): return m
        }
    }
}
