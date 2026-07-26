import os

/// A cancel bit that can be read from outside the main actor.
///
/// `SyncEngine.execute` polls `shouldStop` synchronously from inside `DeviceController`,
/// so the flag cannot live on `AppModel` — there is no way to hop back to the main actor
/// from there. `OSAllocatedUnfairLock` makes this properly `Sendable` with no `@unchecked`.
struct CancellationFlag: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)

    var isCancelled: Bool { state.withLock { $0 } }

    func cancel() { state.withLock { $0 = true } }
}
