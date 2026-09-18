import Foundation

public struct ChromeFixtureState: Codable, Equatable, Sendable {
    public struct Point: Codable, Equatable, Sendable {
        public let x: Double
        public let y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    public struct Selection: Codable, Equatable, Sendable {
        public let start: Int?
        public let end: Int?

        public init(start: Int?, end: Int?) {
            self.start = start
            self.end = end
        }
    }

    public let normalInput: String
    public let editable: String
    public let left: String
    public let right: String
    public let multiline: String
    public let focusedID: String
    public let pageID: String
    public let centers: [String: Point]
    public let selections: [String: Selection]
    /// Synthetic fixture events only; never collects text from a user's page.
    public let inputEvents: [String]?

    public init(
        normalInput: String,
        editable: String,
        left: String,
        right: String,
        multiline: String,
        focusedID: String,
        pageID: String = "",
        centers: [String: Point] = [:],
        selections: [String: Selection] = [:],
        inputEvents: [String]? = nil
    ) {
        self.normalInput = normalInput
        self.editable = editable
        self.left = left
        self.right = right
        self.multiline = multiline
        self.focusedID = focusedID
        self.pageID = pageID
        self.centers = centers
        self.selections = selections
        self.inputEvents = inputEvents
    }
}

public enum FixtureStateCodec {
    public static let titlePrefix = "HangyeolE2E:"

    public static func decode(windowTitle: String) -> ChromeFixtureState? {
        guard let prefixRange = windowTitle.range(of: titlePrefix) else { return nil }
        let suffix = windowTitle[prefixRange.upperBound...]
        let encoded = suffix.prefix { character in
            character.isLetter
                || character.isNumber
                || character == "+"
                || character == "/"
                || character == "="
        }
        guard !encoded.isEmpty,
              let data = Data(base64Encoded: String(encoded)) else {
            return nil
        }
        return try? JSONDecoder().decode(ChromeFixtureState.self, from: data)
    }

    public static func encode(_ state: ChromeFixtureState) throws -> String {
        let data = try JSONEncoder().encode(state)
        return titlePrefix + data.base64EncodedString()
    }
}

public enum ExactTextContract {
    public static func matches(_ actual: String, expected: String) -> Bool {
        guard actual == expected else { return false }
        return Array(actual.unicodeScalars) == Array(expected.unicodeScalars)
    }

    public static func unicodeDescription(_ value: String) -> String {
        let scalars = value.unicodeScalars.map {
            String(format: "U+%04X", $0.value)
        }.joined(separator: " ")
        return "\(String(reflecting: value)) [\(scalars)]"
    }
}
