// @preconcurrency must match the import in every file that touches this
// type's AVFoundation-typed API, or the symbol mangling diverges at link time.
@preconcurrency import AVFoundation
import Foundation

/// Feeds a single already-filled buffer to `AVAudioConverter` exactly once.
///
/// `AVAudioConverterInputBlock` is `@Sendable`, so mutating a captured `var` to
/// track "have I handed over the buffer yet" is a data-race error under the
/// Swift 6 language mode. Boxing that one flag here keeps the call sites clean.
///
/// `@unchecked Sendable` is sound in this specific use: `AVAudioConverter.convert`
/// invokes the input block synchronously, on the calling thread, before it
/// returns, so the box and the buffer it holds are never touched concurrently.
/// Do not reuse an instance across conversions or across threads.
final class ConverterFeed: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var supplied = false

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioPCMBuffer? {
        if supplied {
            status.pointee = .noDataNow
            return nil
        }
        supplied = true
        status.pointee = .haveData
        return buffer
    }

    /// An input block bound to this feed.
    var inputBlock: AVAudioConverterInputBlock {
        { [self] _, status in next(status) }
    }
}
