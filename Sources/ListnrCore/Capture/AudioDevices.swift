import AVFoundation
import Foundation

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
