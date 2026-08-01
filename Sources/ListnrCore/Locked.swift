import Foundation

/// A value guarded by a lock, for handing results across an isolation boundary.
///
/// This codebase reaches for the same shape repeatedly: a `final class`, an
/// `NSLock`, one stored property, and `@unchecked Sendable` on top. Each copy is
/// a chance to forget the lock on one accessor, and the compiler cannot help
/// because `@unchecked` is precisely the promise that it should stop checking.
/// One generic version, audited once.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ initialValue: Value) {
        storage = initialValue
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }

    /// Read-modify-write as one atomic step, for the cases where `get` then `set`
    /// would race.
    @discardableResult
    func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }
}
