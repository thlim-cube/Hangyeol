import AppKit

/// Builds the canonical marked-text payload for the current renderer.
///
/// Blink needs an attributed value to preserve the requested preedit caret on
/// macOS 26. A plain NSString selects the composing syllable in Chrome textareas.
/// Keep Blink's attributes empty: styled payloads previously trapped inside
/// AppKit's _forceAttributedString. Native hosts retain their existing styling.
/// Live transport comparisons and limits are recorded in Docs/E2ETesting.md.
enum MarkedTextPayload {
    static func value(_ text: String, for hostSurface: HostSurface) -> Any {
        if hostSurface == .blinkWeb {
            return NSAttributedString(string: text)
        }
        return attributedValue(text)
    }

    private static func attributedValue(_ text: String) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .underlineStyle: 0,
                .underlineColor: NSColor.clear
            ]
        )
    }
}
