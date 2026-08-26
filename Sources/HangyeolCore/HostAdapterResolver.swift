import InputMethodKit

/// How composition output reaches the focused client.
enum InputDeliveryMode: Equatable {
    case immediate
    case directInsertion
    case markedText
}

/// The single decision point for choosing a host delivery adapter.
struct HostAdapterResolver {
    static func mode(
        for context: ClientContext,
        experimentalDirectInsertion: Bool
    ) -> InputDeliveryMode {
        switch context.hostSurface {
        case .finderNonText:
            return .immediate
        case .blinkWeb:
            if ClientCompatibilityPolicy.prefersDirectInsertionForComposition(
                bundleId: context.bundleId
            ), context.documentAccessSafe,
               !ClientCompatibilityPolicy.directInsertionDenied(bundleId: context.bundleId) {
                return .directInsertion
            }
            return .markedText
        case .blinkNative:
            return context.documentAccessSafe ? .directInsertion : .markedText
        case .appKit:
            break
        }
        if (experimentalDirectInsertion
                || ClientCompatibilityPolicy.prefersDirectInsertionForComposition(
                    bundleId: context.bundleId
                )),
           context.documentAccessSafe,
           !ClientCompatibilityPolicy.directInsertionDenied(bundleId: context.bundleId) {
            return .directInsertion
        }
        return .markedText
    }

    static func makeAdapter(
        for client: IMKTextInput,
        context: ClientContext,
        experimentalDirectInsertion: Bool
    ) -> BaseClientAdapter {
        switch mode(
            for: context,
            experimentalDirectInsertion: experimentalDirectInsertion
        ) {
        case .immediate:
            return ImmediateModeAdapter(
                client: client,
                hostSurface: context.hostSurface
            )
        case .directInsertion:
            DebugLogger.event("delivery.adapter_created", metadata: [
                .state("mode", "direct_insertion")
            ])
            return DirectInsertionAdapter(
                client: client,
                hostSurface: context.hostSurface
            )
        case .markedText:
            return MarkedTextAdapter(
                client: client,
                hostSurface: context.hostSurface
            )
        }
    }
}
