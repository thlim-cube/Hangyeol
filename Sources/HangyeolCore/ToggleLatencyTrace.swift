import Foundation

/// DEBUG-only, content-free timing trace for one physical language-toggle request.
///
/// The trace follows the actual event delivery path across the event-tap/IOKit
/// callback and the main run loop. Release builds keep the same API as an empty,
/// inlinable value type so no clock reads, allocations, logging, or retained trace
/// state are added to the typing hot path.
public struct ToggleLatencyTrace: Sendable {
    public enum Stage: Sendable {
        case mainExecution
        case finalize
        case keyboardOverride
        case modeWrite
        case firstHandle
        case ignored
        case superseded

        var diagnosticLabel: StaticString {
            switch self {
            case .mainExecution: "main_execution"
            case .finalize: "finalize"
            case .keyboardOverride: "keyboard_override"
            case .modeWrite: "mode_write"
            case .firstHandle: "first_handle"
            case .ignored: "ignored"
            case .superseded: "superseded"
            }
        }

        var stopsTrace: Bool {
            // A host may re-enter `handle` during finalize/override. Keep a
            // first-handle trace open so the remaining stages still reveal that
            // ordering; only explicit cancellation suppresses later samples.
            switch self {
            case .ignored, .superseded: true
            case .mainExecution, .finalize, .keyboardOverride, .modeWrite, .firstHandle: false
            }
        }
    }

    #if DEBUG
    private final class State: @unchecked Sendable {
        let id: UInt64
        let source: InputModeCoordinator.ToggleSource
        private let lock = NSLock()
        private var timeline: ToggleLatencyTimeline
        private var completed = false

        init(id: UInt64, source: InputModeCoordinator.ToggleSource, requestedAt: UInt64) {
            self.id = id
            self.source = source
            self.timeline = ToggleLatencyTimeline(requestedAt: requestedAt)
        }

        func mark(_ stage: Stage, at now: UInt64) {
            lock.lock()
            guard !completed else {
                lock.unlock()
                return
            }
            let sample = timeline.record(at: now)
            if stage.stopsTrace {
                completed = true
            }
            lock.unlock()

            DebugLogger.event("toggle.latency", metadata: [
                .traceID(id),
                .state("source", source.diagnosticLabel),
                .state("stage", stage.diagnosticLabel),
                .durationMicroseconds("from_request", sample.fromRequestNanoseconds / 1_000),
                .durationMicroseconds("from_previous", sample.fromPreviousNanoseconds / 1_000)
            ])
        }
    }

    private static let idLock = NSLock()
    nonisolated(unsafe) private static var nextID: UInt64 = 0
    private let state: State

    private init(state: State) {
        self.state = state
    }

    public static func begin(source: InputModeCoordinator.ToggleSource) -> Self {
        idLock.lock()
        nextID &+= 1
        let id = nextID
        idLock.unlock()

        let now = DispatchTime.now().uptimeNanoseconds
        let trace = Self(state: State(id: id, source: source, requestedAt: now))
        DebugLogger.event("toggle.latency", metadata: [
            .traceID(id),
            .state("source", source.diagnosticLabel),
            .state("stage", "request"),
            .durationMicroseconds("from_request", 0),
            .durationMicroseconds("from_previous", 0)
        ])
        return trace
    }

    public func mark(_ stage: Stage) {
        state.mark(stage, at: DispatchTime.now().uptimeNanoseconds)
    }
    #else
    @usableFromInline
    init() {}

    @inlinable
    public static func begin(source: InputModeCoordinator.ToggleSource) -> Self {
        Self()
    }

    @inlinable
    public func mark(_ stage: Stage) {}
    #endif
}

/// Pure monotonic delta calculator kept separate so boundary behavior is testable
/// without sleeping or depending on wall-clock time.
struct ToggleLatencyTimeline {
    struct Sample: Equatable {
        let fromRequestNanoseconds: UInt64
        let fromPreviousNanoseconds: UInt64
    }

    private let requestedAt: UInt64
    private var previousStageAt: UInt64

    init(requestedAt: UInt64) {
        self.requestedAt = requestedAt
        self.previousStageAt = requestedAt
    }

    mutating func record(at timestamp: UInt64) -> Sample {
        // DispatchTime is monotonic. Clamp anyway so a synthetic/test clock or a
        // future clock implementation can never underflow the unsigned deltas.
        let monotonicTimestamp = max(timestamp, previousStageAt)
        let sample = Sample(
            fromRequestNanoseconds: monotonicTimestamp - requestedAt,
            fromPreviousNanoseconds: monotonicTimestamp - previousStageAt
        )
        previousStageAt = monotonicTimestamp
        return sample
    }
}
