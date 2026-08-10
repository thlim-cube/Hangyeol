import Testing
@testable import PriTypeCore

@Suite("ToggleLatencyTrace")
struct ToggleLatencyTraceTests {
    @Test("Timeline reports cumulative and per-stage monotonic deltas")
    func timelineDeltas() {
        var timeline = ToggleLatencyTimeline(requestedAt: 1_000)

        #expect(timeline.record(at: 1_250) == .init(
            fromRequestNanoseconds: 250,
            fromPreviousNanoseconds: 250
        ))
        #expect(timeline.record(at: 2_000) == .init(
            fromRequestNanoseconds: 1_000,
            fromPreviousNanoseconds: 750
        ))
    }

    @Test("Timeline clamps a regressing synthetic clock without underflow")
    func timelineClampsRegression() {
        var timeline = ToggleLatencyTimeline(requestedAt: 1_000)
        _ = timeline.record(at: 1_500)

        #expect(timeline.record(at: 1_400) == .init(
            fromRequestNanoseconds: 500,
            fromPreviousNanoseconds: 0
        ))
    }

    @Test("Stage labels stay content-free and stable")
    func stageLabels() {
        #expect("\(ToggleLatencyTrace.Stage.mainExecution.diagnosticLabel)" == "main_execution")
        #expect("\(ToggleLatencyTrace.Stage.firstHandle.diagnosticLabel)" == "first_handle")
        #expect("\(InputModeCoordinator.ToggleSource.customKey.diagnosticLabel)" == "event_tap")
        #expect("\(InputModeCoordinator.ToggleSource.iokitFallback.diagnosticLabel)" == "iokit")
    }
}
