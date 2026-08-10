import Testing
@testable import PriTypeCore

@Suite("DebugLogger")
struct DebugLoggerTests {
    #if DEBUG
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
    #else
    @Test("Release logging APIs do not evaluate arguments")
    func releaseLoggingAPIsDoNotEvaluateArguments() {
        enum SyntheticError: Error {
            case attemptedEvaluation
        }

        var evaluationCount = 0
        func evaluated<Value>(_ value: Value) -> Value {
            evaluationCount += 1
            return value
        }

        DebugLogger.log(evaluated("release_noop"))
        DebugLogger.event("input.release_noop", metadata: evaluated([
            .count("evaluation_count", 1)
        ]))
        DebugLogger.logError(
            evaluated(SyntheticError.attemptedEvaluation),
            context: evaluated("release_noop")
        )

        #expect(evaluationCount == 0)
    }
    #endif
}
