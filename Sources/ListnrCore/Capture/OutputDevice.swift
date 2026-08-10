import AVFoundation
import CoreAudio
import Foundation

/// How the current output device is attached to the Mac.
///
/// This matters to Lane B. ScreenCaptureKit taps whatever the system is playing,
/// and when that tap comes back as silence it does so without an error: the
/// stream still delivers buffers, still reports a duration, and every sample in
/// them is zero. A session can therefore report four minutes of captured system
/// audio containing nothing at all, which looks like a transcription problem and
/// is not one. Naming the transport gives that failure something to point at.
enum AudioTransport: Equatable, Sendable {
    case builtIn
    case bluetooth
    case usb
    case airPlay
    /// Aggregate or virtual devices, the kind loopback tools install.
    case virtualDevice
    case other(UInt32)

    init(rawTransport: UInt32) {
        switch rawTransport {
        case kAudioDeviceTransportTypeBuiltIn:
            self = .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            self = .bluetooth
        case kAudioDeviceTransportTypeUSB:
            self = .usb
        case kAudioDeviceTransportTypeAirPlay:
            self = .airPlay
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate:
            self = .virtualDevice
        default:
            self = .other(rawTransport)
        }
    }

    var label: String {
        switch self {
        case .builtIn: return "built-in"
        case .bluetooth: return "Bluetooth"
        case .usb: return "USB"
        case .airPlay: return "AirPlay"
        case .virtualDevice: return "virtual/aggregate"
        case .other: return "unknown transport"
        }
    }
}

struct OutputDeviceInfo: Equatable, Sendable {
    let name: String
    let transport: AudioTransport
}

/// Whether the Mac has a microphone at all.
///
/// Its own namespace because the answer is needed before any capture object
/// exists. A Mac mini or Studio has no built-in microphone, so a disconnecting
/// headset leaves the machine with no input device whatsoever — and in that state
/// both `installTap` and `AVAudioEngine.start()` raise Objective-C exceptions,
/// which Swift cannot catch. The process aborts on a CoreAudio assertion rather
/// than reporting that nothing is plugged in, so this has to be checked first.
enum AudioDevices {
    static func hasInputDevice() -> Bool {
        AVCaptureDevice.default(for: .audio) != nil
    }
}

/// Reads the default output device from CoreAudio.
enum OutputDevice {
    static func current() -> OutputDeviceInfo? {
        guard let id = defaultOutputDeviceID() else { return nil }
        guard let transport: UInt32 = property(id, kAudioDevicePropertyTransportType) else { return nil }
        return OutputDeviceInfo(
            name: name(of: id) ?? "output device",
            transport: AudioTransport(rawTransport: transport)
        )
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        guard let id: AudioDeviceID = property(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyDefaultOutputDevice
        ) else { return nil }
        return id == kAudioObjectUnknown ? nil : id
    }

    private static func name(of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// Read a fixed-size CoreAudio property, or nil if it is unavailable.
    private static func property<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<T>.size)
        let storage = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { storage.deallocate() }
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, storage)
        guard status == noErr else { return nil }
        return storage.pointee
    }
}
