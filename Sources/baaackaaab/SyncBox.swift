import Foundation

/// A reference box for one value handed across a synchronous↔asynchronous bridge:
/// a background thread or a completion handler writes `value`, the caller reads it
/// back, and a `DispatchSemaphore` (signal in the closure → wait on the caller)
/// orders the two. This is the recurring "run an async API but block until it
/// finishes" pattern — restic's piped stdout, NSFileCoordinator's materialize,
/// PhotoKit's writeData / requestAuthorization.
///
/// `@unchecked Sendable` because that semaphore is the happens-before relationship
/// the compiler cannot see. It is ONLY safe for this signal-then-read handoff —
/// never reach into `value` from two sides without the semaphore in between.
final class SyncBox<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}
