import Observation

/// Re-armed `withObservationTracking` (ARCHITECTURE §5.13): calls `onChange` with the current value now and
/// after every change of what `read` touched, only when the value differs. AppKit controllers (status item,
/// visibility) use it to follow `@Observable` models without SwiftUI.
@MainActor
public final class ObservationLoop<Value: Equatable> {
    private let read: @MainActor () -> Value
    private let onChange: @MainActor (Value) -> Void
    private var last: Value?
    private var cancelled = false

    public init(_ read: @escaping @MainActor () -> Value, onChange: @escaping @MainActor (Value) -> Void) {
        self.read = read
        self.onChange = onChange
        arm()
    }

    public func cancel() { cancelled = true }

    private func arm() {
        guard !cancelled else { return }
        let value = withObservationTracking(read) { [weak self] in
            Task { @MainActor in self?.arm() }
        }
        if value != last {
            last = value
            onChange(value)
        }
    }
}
