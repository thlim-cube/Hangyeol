import Testing
import Foundation
@testable import PriTypeCore

private struct SwiftCodeScanner {
    private let characters: [Character]
    private var index = 0

    init(_ source: String) {
        characters = Array(source)
    }

    mutating func codeOnly() -> String {
        scanCode(stoppingAtInterpolationEnd: false)
    }

    private mutating func scanCode(stoppingAtInterpolationEnd: Bool) -> String {
        var code = ""
        var parenthesisDepth = 0

        while index < characters.count {
            if stoppingAtInterpolationEnd, characters[index] == ")" {
                if parenthesisDepth == 0 {
                    index += 1
                    return code
                }
                parenthesisDepth -= 1
                code.append(")")
                index += 1
                continue
            }

            if matches(["/", "/"], at: index) {
                skipLineComment()
                code.append("\n")
                continue
            }
            if matches(["/", "*"], at: index) {
                skipBlockComment()
                code.append(" ")
                continue
            }
            if let delimiter = stringDelimiter(at: index) {
                code += " " + skipString(delimiter) + " "
                continue
            }
            if let delimiter = regexDelimiter(at: index, precedingCode: code) {
                code += " " + skipRegex(delimiter) + " "
                continue
            }

            let character = characters[index]
            if stoppingAtInterpolationEnd, character == "(" {
                parenthesisDepth += 1
            }
            code.append(character)
            index += 1
        }

        return code
    }

    private mutating func skipLineComment() {
        index += 2
        while index < characters.count, characters[index] != "\n" {
            index += 1
        }
        if index < characters.count {
            index += 1
        }
    }

    private mutating func skipBlockComment() {
        index += 2
        var depth = 1
        while index < characters.count, depth > 0 {
            if matches(["/", "*"], at: index) {
                depth += 1
                index += 2
            } else if matches(["*", "/"], at: index) {
                depth -= 1
                index += 2
            } else {
                index += 1
            }
        }
    }

    private struct StringDelimiter {
        let hashCount: Int
        let quoteCount: Int
        let prefixLength: Int
    }

    private func stringDelimiter(at position: Int) -> StringDelimiter? {
        var cursor = position
        while cursor < characters.count, characters[cursor] == "#" {
            cursor += 1
        }
        let hashCount = cursor - position
        guard cursor < characters.count, characters[cursor] == "\"" else { return nil }
        let quoteCount = matches(["\"", "\"", "\""], at: cursor) ? 3 : 1
        return StringDelimiter(
            hashCount: hashCount,
            quoteCount: quoteCount,
            prefixLength: hashCount + quoteCount
        )
    }

    private mutating func skipString(_ delimiter: StringDelimiter) -> String {
        index += delimiter.prefixLength
        var interpolationCode = ""
        let closing = Array(repeating: Character("\""), count: delimiter.quoteCount)
            + Array(repeating: Character("#"), count: delimiter.hashCount)

        while index < characters.count {
            if matches(closing, at: index) {
                index += closing.count
                return interpolationCode
            }
            if characters[index] == "\\" {
                var cursor = index + 1
                var observedHashes = 0
                while cursor < characters.count,
                      observedHashes < delimiter.hashCount,
                      characters[cursor] == "#" {
                    observedHashes += 1
                    cursor += 1
                }
                if observedHashes == delimiter.hashCount,
                   cursor < characters.count,
                   characters[cursor] == "(" {
                    index = cursor + 1
                    interpolationCode += " " + scanCode(stoppingAtInterpolationEnd: true) + " "
                    continue
                }
                if observedHashes == delimiter.hashCount, cursor < characters.count {
                    index = cursor + 1
                    continue
                }
            }
            index += 1
        }
        return interpolationCode
    }

    private struct RegexDelimiter {
        let hashCount: Int
        let prefixLength: Int
    }

    private func regexDelimiter(at position: Int, precedingCode: String) -> RegexDelimiter? {
        var cursor = position
        while cursor < characters.count, characters[cursor] == "#" {
            cursor += 1
        }
        let hashCount = cursor - position
        guard cursor < characters.count,
              characters[cursor] == "/",
              hashCount > 0 || canStartRegex(after: precedingCode) else {
            return nil
        }
        return RegexDelimiter(hashCount: hashCount, prefixLength: hashCount + 1)
    }

    private func canStartRegex(after code: String) -> Bool {
        let preceding = code.reversed().drop(while: { $0.isWhitespace })
        guard let previous = preceding.first else { return true }
        if "=([{,:;!?".contains(previous) {
            return true
        }

        let tokenCharacters = preceding.prefix {
            $0.isLetter || $0.isNumber || $0 == "_"
        }
        let token = String(tokenCharacters.reversed())
        let beforeToken = preceding.dropFirst(tokenCharacters.count)
        if let adjacent = beforeToken.first,
           adjacent == "`" || adjacent.isLetter || adjacent.isNumber || adjacent == "_" {
            return false
        }
        if beforeToken.drop(while: { $0.isWhitespace }).first == "." {
            return false
        }
        return ["return", "throw", "case", "in", "where", "try", "await", "yield"]
            .contains(token)
    }

    private mutating func skipRegex(_ delimiter: RegexDelimiter) -> String {
        index += delimiter.prefixLength
        var interpolationCode = ""
        var insideCharacterClass = false
        let closing = [Character("/")] + Array(repeating: Character("#"), count: delimiter.hashCount)

        while index < characters.count {
            if !insideCharacterClass, matches(closing, at: index) {
                index += closing.count
                while index < characters.count, characters[index].isLetter {
                    index += 1
                }
                return interpolationCode
            }
            if characters[index] == "[" {
                insideCharacterClass = true
                index += 1
                continue
            }
            if characters[index] == "]" {
                insideCharacterClass = false
                index += 1
                continue
            }
            if characters[index] == "\\" {
                var cursor = index + 1
                var observedHashes = 0
                while cursor < characters.count,
                      observedHashes < delimiter.hashCount,
                      characters[cursor] == "#" {
                    observedHashes += 1
                    cursor += 1
                }
                if observedHashes == delimiter.hashCount,
                   cursor < characters.count,
                   characters[cursor] == "(" {
                    index = cursor + 1
                    interpolationCode += " " + scanCode(stoppingAtInterpolationEnd: true) + " "
                    continue
                }
                index = min(cursor + 1, characters.count)
                continue
            }
            index += 1
        }
        return interpolationCode
    }

    private func matches(_ sequence: [Character], at position: Int) -> Bool {
        guard position + sequence.count <= characters.count else { return false }
        return sequence.indices.allSatisfy { characters[position + $0] == sequence[$0] }
    }
}

@Suite("DebugLogger")
struct DebugLoggerTests {
    private func loggerUsage(in source: String) throws -> (members: [String], references: Int) {
        var scanner = SwiftCodeScanner(source)
        let code = scanner.codeOnly()

        let memberRegex = try NSRegularExpression(
            pattern: #"\bDebugLogger\s*\.\s*`?([A-Za-z_][A-Za-z0-9_]*)`?"#
        )
        let fullRange = NSRange(code.startIndex..<code.endIndex, in: code)
        let members = memberRegex.matches(in: code, range: fullRange).compactMap { match in
            Range(match.range(at: 1), in: code).map { String(code[$0]) }
        }
        let referenceRegex = try NSRegularExpression(pattern: #"\bDebugLogger\b"#)
        let references = referenceRegex.numberOfMatches(in: code, range: fullRange)
        return (members, references)
    }

    private func structuredLoggerMembers(in source: String) throws -> [String] {
        try loggerUsage(in: source).members
    }

    @Test("Input pipeline source cannot call free-form logging APIs")
    func inputPipelineUsesStructuredLoggingOnly() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let inputPipelineFiles = [
            "ClientContextDetector.swift",
            "HostSurface.swift",
            "ClientCompatibilityPolicy.swift",
            "SecureInputPolicy.swift",
            "HostAdapterResolver.swift",
            "HostTextAdapters.swift",
            "HostKeyTransaction.swift",
            "MarkedTextPayload.swift",
            "InputSession.swift",
            "PriTypeInputController.swift",
            "HangulComposer.swift",
            "TextConvenienceHandler.swift",
            "InputModeCoordinator.swift",
            "ToggleLatencyTrace.swift",
            "RightCommandSuppressor.swift",
            "IOKitManager.swift",
            "ToggleMonitoringState.swift",
            "CursorRectResolver.swift",
            "DirectInsertionPlanner.swift",
            "HanjaCandidateWindow.swift",
            "HanjaManager.swift"
        ]

        for filename in inputPipelineFiles {
            let source = try String(
                contentsOf: repoRoot
                    .appendingPathComponent("Sources/PriTypeCore")
                    .appendingPathComponent(filename),
                encoding: .utf8
            )
            let usage = try loggerUsage(in: source)
            #expect(
                usage.members.allSatisfy { $0 == "event" },
                "\(filename) uses a non-structured DebugLogger member: \(usage.members)"
            )
            #expect(
                usage.references == usage.members.count,
                "\(filename) aliases or stores DebugLogger instead of calling event directly"
            )
        }

        let nonCodeFixture = #"""
        // DebugLogger.log("comment")
        let example = "DebugLogger.logError(error, context: \"literal\")"
        /* outer /* nested */ DebugLogger.log("block comment") */
        let regex = /DebugLogger.log/
        func pattern() -> Regex<Substring> { return #/DebugLogger.log/# }
        let interpolated = "\(DebugLogger.event("input.fixture"))"
        """#
        #expect(try structuredLoggerMembers(in: nonCodeFixture) == ["event"])

        let interpolatedViolation = #"""
        let value = "\(DebugLogger.log(secret))"
        """#
        #expect(try structuredLoggerMembers(in: interpolatedViolation) == ["log"])

        let backtickedViolation = #"DebugLogger.`log`(secret)"#
        #expect(try structuredLoggerMembers(in: backtickedViolation) == ["log"])

        let aliasedViolation = #"""
        typealias PipelineLogger = DebugLogger
        PipelineLogger.log(secret)
        """#
        let aliasedUsage = try loggerUsage(in: aliasedViolation)
        #expect(aliasedUsage.members.isEmpty)
        #expect(aliasedUsage.references == 1)

        let divisionAfterKeywordNamedMember = #"""
        let result = value.return / { DebugLogger.log(secret); return 2 }()
        """#
        #expect(try structuredLoggerMembers(in: divisionAfterKeywordNamedMember) == ["log"])

        let spacedDivisionAfterKeywordNamedMember = #"""
        let result = value . return / { DebugLogger.log(secret); return 2 }()
        """#
        #expect(
            try structuredLoggerMembers(in: spacedDivisionAfterKeywordNamedMember) == ["log"]
        )

        let regexAfterPreviousStatement = #"""
        _ = previousIdentifier
        return /DebugLogger.log/
        """#
        #expect(try structuredLoggerMembers(in: regexAfterPreviousStatement).isEmpty)

        let regexAfterYield = #"""
        yield /DebugLogger.log/
        """#
        #expect(try structuredLoggerMembers(in: regexAfterYield).isEmpty)
    }

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
