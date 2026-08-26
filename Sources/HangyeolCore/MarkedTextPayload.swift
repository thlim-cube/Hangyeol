import AppKit

/// Builds the canonical marked-text payload for the current renderer.
///
/// AppKit on macOS 26 regenerates marked-text styling, so attributes cannot hide
/// the system underline. Blink web clients receive plain `NSString` because their
/// attributed path can crash inside AppKit; native hosts receive an attributed value.
enum MarkedTextPayload {
    static func value(_ text: String, for hostSurface: HostSurface) -> Any {
        if hostSurface == .blinkWeb {
            return text as NSString
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
