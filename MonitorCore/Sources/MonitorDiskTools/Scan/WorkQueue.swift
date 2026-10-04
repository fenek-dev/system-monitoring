import Dispatch
import Synchronization

/// LIFO work stack shared by the scan workers (depth-first keeps the live frontier small).
///
/// Termination: the scan is complete only when nothing is queued *and* nothing is in flight. A worker that pops the
/// last item may still push children, so `complete()` — called after the worker committed and pushed — is the only
/// place that can declare the queue drained.
final class WorkQueue<Item: Sendable>: Sendable {
    private struct State {
        var stack: [Item] = []
        var inFlight = 0
        var cancelled = false
        var drained = false
    }

    private let state = Mutex(State())
    private let wake = DispatchSemaphore(value: 0)
    private let workers: Int

    init(workers: Int) {
        self.workers = workers
    }

    var queued: Int { state.withLock { $0.stack.count } }
    var inFlight: Int { state.withLock { $0.inFlight } }

    func push(_ items: [Item]) {
        guard !items.isEmpty else { return }
        let accepted = state.withLock { state -> Bool in
            guard !state.cancelled else { return false }
            state.stack.append(contentsOf: items)
            return true
        }
        if accepted { for _ in items { wake.signal() } }
    }

    /// Next item, blocking while the stack is empty but work is still in flight; nil once drained or cancelled.
    func pop() -> Item? {
        while true {
            let outcome = state.withLock { state -> (item: Item?, finished: Bool) in
                if state.cancelled || state.drained { return (nil, true) }
                guard let item = state.stack.popLast() else { return (nil, false) }
                state.inFlight += 1
                return (item, false)
            }
            if let item = outcome.item { return item }
            if outcome.finished { return nil }
            wake.wait()
        }
    }

    /// The item returned by `pop` is fully processed (its children, if any, are already pushed).
    func complete() {
        let drainedNow = state.withLock { state -> Bool in
            state.inFlight -= 1
            guard !state.drained, state.stack.isEmpty, state.inFlight == 0 else { return false }
            state.drained = true
            return true
        }
        if drainedNow { releaseAll() }
    }

    func cancel() {
        let first = state.withLock { state -> Bool in
            guard !state.cancelled else { return false }
            state.cancelled = true
            return true
        }
        if first { releaseAll() }
    }

    var isCancelled: Bool { state.withLock { $0.cancelled } }

    private func releaseAll() {
        for _ in 0 ..< workers { wake.signal() }
    }
}
