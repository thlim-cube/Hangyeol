import Testing
@testable import PriTypeCore

@Suite("DebugLogger")
struct DebugLoggerTests {
    @Test("Structured input event renders content-free typed metadata")
    func structuredEventFormatting() {
        let rendered = DebugLogger.formatEvent("input.pipeline", metadata: [
            .traceID(7),
            .state("stage", "composition_commit"),
            .flag("had_composition", true),
            .count("committed_length", 1),
            .durationMicroseconds("elapsed", 250),
            .statusCode("status", -1)
        ])

        #expect(rendered == "event=input.pipeline trace=7 stage=composition_commit had_composition=true committed_length=1 elapsed=250us status=-1")
    }

    @Test("Structured input event without metadata has a stable shape")
    func structuredEventWithoutMetadata() {
        #expect(DebugLogger.formatEvent("input.session_activated", metadata: []) == "event=input.session_activated")
    }
}
