import Foundation

/// A burner that writes nothing and records what it was asked to burn. For tests, and for machines with no blank disc.
public final class FixtureBurner: DiscBurner, @unchecked Sendable {
    private let lock = NSLock()
    private var current: BurnDeviceState
    private var continuations: [UUID: AsyncStream<BurnDeviceState>.Continuation] = [:]
    private var burned: [BurnJob] = []
    private var ejected = 0

    public let deviceName: String?
    /// Make the next burn fail with this.
    public var failNextBurn: BurnError?
    /// How long each of the 10 progress steps takes.
    public var stepDelay: Duration = .milliseconds(5)

    public init(deviceName: String? = "Fixture Burner", state: BurnDeviceState) {
        self.deviceName = deviceName
        self.current = state
    }

    public static func blankCD(blocks: Int = 359_847) -> BurnDeviceState {
        .ready(BurnMedia(kind: .cd, label: "CD-R", blocksFree: blocks))
    }

    public static func blankDVD(blocks: Int = 2_297_888) -> BurnDeviceState {
        .ready(BurnMedia(kind: .dvd, label: "DVD-R", blocksFree: blocks))
    }

    public var jobs: [BurnJob] { lock.withLock { burned } }
    public var ejectCount: Int { lock.withLock { ejected } }

    public func state() -> BurnDeviceState { lock.withLock { current } }

    /// Changes the state, as if a disc was inserted or removed.
    public func set(_ state: BurnDeviceState) {
        let listeners = lock.withLock { () -> [AsyncStream<BurnDeviceState>.Continuation] in
            current = state
            return Array(continuations.values)
        }
        for listener in listeners { listener.yield(state) }
    }

    public func stateChanges() -> AsyncStream<BurnDeviceState> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock { continuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { _ = self?.continuations.removeValue(forKey: id) }
            }
        }
    }

    public func burn(_ job: BurnJob, progress: @Sendable (BurnStage) -> Void) async throws {
        progress(.preparing)
        try await Task.sleep(for: stepDelay)
        if Task.isCancelled { throw CancellationError() }
        guard case .ready = state() else { throw BurnError.noDisc }
        if let failure = lock.withLock({ () -> BurnError? in let f = failNextBurn; failNextBurn = nil; return f }) { throw failure }
        for step in 1...10 {
            progress(.burning(Double(step) / 10))
            try await Task.sleep(for: stepDelay)
        }
        progress(.finishing)
        try await Task.sleep(for: stepDelay)
        lock.withLock { burned.append(job) }
    }

    public func eject() {
        lock.withLock { ejected += 1 }
        set(.noDisc)
    }
}
