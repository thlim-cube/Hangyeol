import Cocoa
import InputMethodKit

// MARK: - CursorRectResolver

/// Resolves the on-screen caret position for the Hanja candidate window.
///
/// Native apps (TextEdit, Xcode) answer `IMKTextInput.firstRect` directly, but
/// Chromium/Electron hosts block or garbage the coordinate APIs while the Hanja key
/// event is being processed, so resolution runs a strategy chain (fcitx5-macos
/// inspired):
///
/// 1. `firstRect(forCharacterRange:)` on the marked (else selected) range
/// 2. `attributes(forCharacterIndex: pos-1)` — Chromium allows committed chars
/// 3. cached last-known-good position (zero-cost, window stays where it last was)
/// 4. Accessibility API (`AXSelectedTextRange` → `AXBoundsForRange`)
/// 5. mouse location (last resort)
public enum CursorRectResolver {
    /// Chromium may temporarily reject coordinate queries while a key event is in
    /// flight. A cached caret is only reusable for the exact client/session that
    /// produced it, while its screen is still connected, and for a short interval.
    private static let cacheLifetime: TimeInterval = 2
    nonisolated(unsafe) private static var cursorCache = CursorRectCache()

    /// Resolve a usable caret rect for `client`, falling back through the strategy
    /// chain. Always returns SOMETHING displayable (mouse location at worst).
    /// Call BEFORE committing the preedit: Chromium updates cursor position
    /// asynchronously after commit, so post-commit queries return garbage.
    static func resolve(client: IMKTextInput?, sessionID: ObjectIdentifier? = nil) -> NSRect {
        var cursorRect = NSRect(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y - 20, width: 0, height: 20)
        var resolved = false
        var resolvedFromFreshSource = false
        let screenFrames = NSScreen.screens.map(\.frame)
        let now = ProcessInfo.processInfo.systemUptime

        if let client {
            let clientID = ObjectIdentifier(client as AnyObject)
            var actualRange = NSRange()

            // Prefer markedRange during preedit. Chromium fails with garbage values
            // if we request firstRect for selectedRange while a preedit is active.
            var targetRange = client.markedRange()
            if targetRange.location == NSNotFound || targetRange.length == 0 {
                targetRange = client.selectedRange()
            }

            if targetRange.location != NSNotFound {
                // Strategy 1: firstRect — the standard IMK approach
                let rect = client.firstRect(forCharacterRange: targetRange, actualRange: &actualRange)
                if isValidCursorRect(rect) {
                    cursorRect = rect
                    resolved = true
                    resolvedFromFreshSource = true
                    DebugLogger.log("Hanja: cursor from firstRect (pre-commit): \(rect)")
                } else {
                    DebugLogger.log("Hanja: firstRect returned invalid rect for range \(targetRange): \(rect)")

                    // Strategy 2: attributes(forCharacterIndex: pos-1)
                    // Like fcitx5, query the previously committed character (one IPC call only).
                    // Chromium blocks queries for the active preedit character but allows committed ones.
                    var lineRect = NSRect.zero
                    let queryIndex = targetRange.location > 0 ? targetRange.location - 1 : 0
                    _ = client.attributes(forCharacterIndex: queryIndex, lineHeightRectangle: &lineRect)

                    if isValidCursorRect(lineRect) {
                        cursorRect = lineRect
                        resolved = true
                        resolvedFromFreshSource = true
                        DebugLogger.log("Hanja: cursor from attributes(idx \(queryIndex)): \(lineRect)")
                    } else {
                        DebugLogger.log("Hanja: attributes(idx \(queryIndex)) also invalid: \(lineRect)")
                    }
                }
            }

            // Strategy 3: Use cached last-known-good position (fcitx5-style)
            // If coordinate query failed but we have a recent successful position,
            // reuse it. The window stays near where it last appeared — much better
            // than jumping to the mouse cursor across the screen.
            if !resolved,
               let sessionID,
               let cached = cursorCache.value(
                   clientID: clientID,
                   sessionID: sessionID,
                   screenFrames: screenFrames,
                   now: now,
                   maxAge: cacheLifetime
               ) {
                cursorRect = cached
                resolved = true
                DebugLogger.log("Hanja: using cached last-known-good position: \(cached)")
            }

            // Strategy 4: AX element position (rough approximation)
            if !resolved {
                if let axRect = getCursorRectViaAccessibility() {
                    cursorRect = axRect
                    resolved = true
                    resolvedFromFreshSource = true
                    DebugLogger.log("Hanja: cursor from Accessibility API: \(axRect)")
                } else {
                    DebugLogger.log("Hanja: all strategies failed, using mouse location")
                }
            }
        }

        // Cache the resolved position for future fallback
        if resolvedFromFreshSource, let client, let sessionID,
           let screenFrame = screenFrame(containing: cursorRect.origin, in: screenFrames) {
            cursorCache.store(
                rect: cursorRect,
                clientID: ObjectIdentifier(client as AnyObject),
                sessionID: sessionID,
                screenFrame: screenFrame,
                timestamp: now
            )
        }

        return cursorRect
    }

    /// Session-ending events invalidate any fallback coordinate immediately. This
    /// prevents a caret from one field being reused after focus moves within an app.
    static func invalidateCache() {
        cursorCache.removeAll()
    }

    // MARK: - Cursor Position Validation

    /// Validate that a rect from firstRect is a usable cursor position
    /// Electron/Chromium apps can return garbage values (e.g. x=1.6e-314, y=19896)
    public static func isValidCursorRect(_ rect: NSRect) -> Bool {
        isValidCursorRect(rect, screenFrames: NSScreen.screens.map(\.frame))
    }

    /// Pure validation variant used by multi-display regression tests. Negative and
    /// zero coordinates are valid when a connected screen actually occupies them.
    static func isValidCursorRect(_ rect: NSRect, screenFrames: [NSRect]) -> Bool {
        let scalars = [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height]
        guard scalars.allSatisfy(\.isFinite), rect.size.width >= 0, rect.size.height > 0 else {
            return false
        }

        // Chromium has returned subnormal floating-point values for an unavailable
        // coordinate. Preserve real zero (a legitimate screen edge), but reject a
        // non-zero subnormal before screen containment can accidentally accept it.
        guard [rect.origin.x, rect.origin.y].allSatisfy({ $0 == 0 || $0.isNormal }) else {
            return false
        }
        guard (rect.size.width == 0 || rect.size.width.isNormal), rect.size.height.isNormal else {
            return false
        }

        return screenFrame(containing: rect.origin, in: screenFrames) != nil
    }

    /// Convert an Accessibility rect (top-left global coordinates) into AppKit's
    /// bottom-left global coordinates using the screen that contains the AX point.
    /// Keeping screen selection explicit handles displays arranged left of or below
    /// the main display without assuming `NSScreen.main.frame.height` is the desktop.
    static func appKitRect(
        fromAccessibilityRect rect: NSRect,
        screenFrames: [NSRect],
        mainScreenFrame: NSRect
    ) -> NSRect? {
        let scalars = [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height]
        guard scalars.allSatisfy(\.isFinite), rect.size.width >= 0, rect.size.height >= 0 else {
            return nil
        }

        let axPoint = rect.origin
        guard let screenFrame = screenFrames.first(where: {
            accessibilityFrame(for: $0, mainScreenFrame: mainScreenFrame).contains(axPoint)
        }) else {
            return nil
        }

        let axScreenFrame = accessibilityFrame(for: screenFrame, mainScreenFrame: mainScreenFrame)
        let yOffsetWithinScreen = rect.origin.y - axScreenFrame.minY
        return NSRect(
            x: rect.origin.x,
            y: screenFrame.maxY - yOffsetWithinScreen - rect.size.height,
            width: rect.size.width,
            height: rect.size.height
        )
    }

    private static func accessibilityFrame(for screenFrame: NSRect, mainScreenFrame: NSRect) -> NSRect {
        NSRect(
            x: screenFrame.minX,
            y: mainScreenFrame.maxY - screenFrame.maxY,
            width: screenFrame.width,
            height: screenFrame.height
        )
    }

    private static func screenFrame(containing point: NSPoint, in screenFrames: [NSRect]) -> NSRect? {
        screenFrames.first { $0.contains(point) }
    }

    // MARK: - Accessibility API Cursor Position

    /// Get cursor position via macOS Accessibility API
    /// Chromium/Electron apps have broken IMK firstRect but properly implement AX text attributes.
    /// Uses AXSelectedTextRange → AXBoundsForRange to get the caret's screen coordinates.
    ///
    /// - Returns: NSRect of the caret position in screen coordinates (bottom-left origin), or nil if unavailable
    private static func getCursorRectViaAccessibility() -> NSRect? {
        let systemWide = AXUIElementCreateSystemWide()

        // Get the currently focused UI element
        var focusedElement: AnyObject?
        var focusResult = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement)

        // Fallback: If system-wide focused element fails (common in Chromium intermittently),
        // try going through the focused application instead
        if focusResult != .success || focusedElement == nil {
            DebugLogger.log("Hanja AX: systemWide focusedElement failed (\(focusResult.rawValue)), trying app path")

            var focusedApp: AnyObject?
            if AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp) == .success,
               let appElement = validatedAXElement(focusedApp) {
                focusResult = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)
                if focusResult != .success {
                    DebugLogger.log("Hanja AX: app focusedElement also failed (\(focusResult.rawValue))")
                    return nil
                }
            } else {
                DebugLogger.log("Hanja AX: focusedApplication also failed")
                return nil
            }
        }

        guard let axElement = validatedAXElement(focusedElement) else {
            DebugLogger.log("Hanja AX: focused value was not an AXUIElement")
            return nil
        }

        // Strategy 1: AXSelectedTextRange → AXBoundsForRange
        if let rect = getBoundsForSelectedText(axElement) {
            return rect
        }

        // Strategy 2: Use element's AXPosition + AXSize as approximation
        // The focused element itself (e.g. text area) gives us a reasonable position
        if let rect = getElementCaretPosition(axElement) {
            return rect
        }

        DebugLogger.log("Hanja AX: all strategies failed")
        return nil
    }

    /// Try to get caret bounds via AXBoundsForRange
    private static func getBoundsForSelectedText(_ axElement: AXUIElement) -> NSRect? {
        // Get the selected text range (caret position)
        var selectedRangeValue: AnyObject?
        let rangeResult = AXUIElementCopyAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, &selectedRangeValue)
        guard rangeResult == .success, let rangeVal = validatedAXValue(selectedRangeValue) else {
            DebugLogger.log("Hanja AX: selectedTextRange failed (\(rangeResult.rawValue))")
            return nil
        }

        // Extract the CFRange to check if we have a zero-length selection (caret)
        var cfRange = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeVal, .cfRange, &cfRange) else {
            DebugLogger.log("Hanja AX: selectedTextRange was not a CFRange")
            return nil
        }

        // If caret is at position > 0, try bounds for the character BEFORE caret
        // This often works better than bounds for a zero-length range
        let queryRange: AnyObject
        if cfRange.length == 0 && cfRange.location > 0 {
            var charRange = CFRange(location: cfRange.location - 1, length: 1)
            // AXValueCreate is effectively non-nil for a valid CFRange, but fall
            // back to the original range instead of force-unwrapping if it isn't.
            if let charRangeValue = AXValueCreate(.cfRange, &charRange) {
                queryRange = charRangeValue
            } else {
                queryRange = rangeVal
            }
        } else {
            queryRange = rangeVal
        }

        // Get the bounds for this text range
        var boundsValue: AnyObject?
        let boundsResult = AXUIElementCopyParameterizedAttributeValue(
            axElement,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            queryRange,
            &boundsValue
        )
        guard boundsResult == .success, let boundsVal = validatedAXValue(boundsValue) else {
            DebugLogger.log("Hanja AX: boundsForRange failed (\(boundsResult.rawValue))")
            return nil
        }

        // Convert AXValue to CGRect
        var bounds = CGRect.zero
        guard AXValueGetValue(boundsVal, .cgRect, &bounds) else {
            DebugLogger.log("Hanja AX: AXValueGetValue failed")
            return nil
        }

        DebugLogger.log("Hanja AX: raw bounds = \(bounds)")

        let screenFrames = NSScreen.screens.map(\.frame)
        guard let mainScreenFrame = NSScreen.main?.frame else { return nil }

        // Chrome returns (0, y, 0, 0) — only y is valid
        // If we have a valid y but x/width/height are zero, supplement from element position
        if bounds.size.width == 0 && bounds.size.height == 0 {
            // Get the element's position to supplement x coordinate
            var posValue: AnyObject?
            if AXUIElementCopyAttributeValue(axElement, kAXPositionAttribute as CFString, &posValue) == .success,
               let pv = validatedAXValue(posValue) {
                var pos = CGPoint.zero
                guard AXValueGetValue(pv, .cgPoint, &pos) else {
                    DebugLogger.log("Hanja AX: element position was not a CGPoint")
                    return nil
                }

                // Use element x, AX y, and a default caret height. Screen-aware
                // conversion supports negative X and displays below the main one.
                let defaultHeight: CGFloat = 18
                let supplemented = NSRect(x: pos.x, y: bounds.origin.y, width: 0, height: defaultHeight)
                guard let result = appKitRect(
                    fromAccessibilityRect: supplemented,
                    screenFrames: screenFrames,
                    mainScreenFrame: mainScreenFrame
                ) else { return nil }
                DebugLogger.log("Hanja AX: Chrome partial → supplemented with element pos: \(result)")

                if isValidCursorRect(result) { return result }
            }
        }

        // Normal case: full bounds available
        guard let result = appKitRect(
            fromAccessibilityRect: bounds,
            screenFrames: screenFrames,
            mainScreenFrame: mainScreenFrame
        ) else { return nil }

        guard isValidCursorRect(result) else {
            DebugLogger.log("Hanja AX: converted rect invalid: \(result)")
            return nil
        }

        return result
    }

    /// Fallback: use element's AXPosition to approximate caret location
    private static func getElementCaretPosition(_ axElement: AXUIElement) -> NSRect? {
        var posValue: AnyObject?
        var sizeValue: AnyObject?

        guard AXUIElementCopyAttributeValue(axElement, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(axElement, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let pv = validatedAXValue(posValue), let sv = validatedAXValue(sizeValue) else {
            DebugLogger.log("Hanja AX: element position/size unavailable")
            return nil
        }

        var pos = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(pv, .cgPoint, &pos),
              AXValueGetValue(sv, .cgSize, &size) else {
            DebugLogger.log("Hanja AX: element position/size had unexpected AXValue types")
            return nil
        }

        // Use the bottom-left of the element as a rough caret position.
        let defaultHeight: CGFloat = 18
        let screenFrames = NSScreen.screens.map(\.frame)
        guard let mainScreenFrame = NSScreen.main?.frame,
              let elementRect = appKitRect(
                  fromAccessibilityRect: NSRect(origin: pos, size: size),
                  screenFrames: screenFrames,
                  mainScreenFrame: mainScreenFrame
              ) else { return nil }
        let result = NSRect(x: elementRect.minX, y: elementRect.minY, width: 0, height: defaultHeight)

        DebugLogger.log("Hanja AX: element position fallback: \(result)")
        guard isValidCursorRect(result) else { return nil }
        return result
    }

    private static func validatedAXElement(_ value: AnyObject?) -> AXUIElement? {
        guard let value else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func validatedAXValue(_ value: AnyObject?) -> AXValue? {
        guard let value else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }
}

/// Value-type cache so client/session/screen/TTL behavior can be tested without an
/// InputMethodKit host. The process-global resolver owns one instance on the IMK
/// callback thread.
struct CursorRectCache {
    private struct Entry {
        let rect: NSRect
        let clientID: ObjectIdentifier
        let sessionID: ObjectIdentifier
        let screenFrame: NSRect
        let timestamp: TimeInterval
    }

    private var entry: Entry?

    mutating func store(
        rect: NSRect,
        clientID: ObjectIdentifier,
        sessionID: ObjectIdentifier,
        screenFrame: NSRect,
        timestamp: TimeInterval
    ) {
        entry = Entry(
            rect: rect,
            clientID: clientID,
            sessionID: sessionID,
            screenFrame: screenFrame,
            timestamp: timestamp
        )
    }

    mutating func value(
        clientID: ObjectIdentifier,
        sessionID: ObjectIdentifier,
        screenFrames: [NSRect],
        now: TimeInterval,
        maxAge: TimeInterval
    ) -> NSRect? {
        guard let entry,
              entry.clientID == clientID,
              entry.sessionID == sessionID,
              screenFrames.contains(entry.screenFrame),
              now >= entry.timestamp,
              now - entry.timestamp <= maxAge else {
            self.entry = nil
            return nil
        }
        return entry.rect
    }

    mutating func removeAll() {
        entry = nil
    }
}
