import Cocoa
import InputMethodKit
import Testing
@testable import HangyeolCore

@Suite("Deterministic controller/session lifecycle model", .serialized)
struct LifecycleOperationSequenceTests {
    @Test(
        "Fixed-seed operation sequences preserve ownership and write leases",
        arguments: [
            UInt64(0x0000_0000_0000_0001),
            UInt64(0x1357_9BDF_2468_ACE0),
            UInt64(0x5EED_0000_0000_0001),
            UInt64(0xA11C_E5E5_5100_0001),
            UInt64(0xC0DE_CAFE_F00D_BAAD),
            UInt64(0xFFFF_FFFF_FFFF_FFC5)
        ]
    )
    func fixedSeedLifecycleSequence(seed: UInt64) {
        var generator = SplitMix64(seed: seed)
        let operations = LifecycleOperation.requiredCoverage + (0..<180).map { _ in
            LifecycleOperation.random(using: &generator)
        }
        let harness = LifecycleHarness()
        var executed: [LifecycleOperation] = []

        do {
            for (step, operation) in operations.enumerated() {
                executed.append(operation)
                try harness.apply(operation, step: step)
                try harness.validateGlobalInvariants(step: step)
            }
        } catch {
            let sequence = executed.enumerated().map {
                "\($0.offset): \($0.element.description)"
            }.joined(separator: "\n")
            Issue.record(Comment(rawValue: """
            seed=0x\(String(seed, radix: 16, uppercase: true))
            error=\(error.localizedDescription)
            operations:
            \(sequence)
            """))
        }
    }
}

private enum LifecycleOperation: CustomStringConvertible {
    case activate(Int)
    case lateKeyDown(Int)
    case lateDeactivate(Int)
    case sameClientFieldChange(Int)
    case secureEnter(Int)
    case secureExit(Int)
    case modeToggle(Int)
    case mouseCommit(Int)
    case sessionReplacement(Int)
    case lateHanjaSelection

    static let requiredCoverage: [LifecycleOperation] = [
        .activate(0),
        .lateKeyDown(0),
        .activate(1),
        .lateDeactivate(0),
        .lateKeyDown(0),
        .sameClientFieldChange(0),
        .secureEnter(0),
        .lateKeyDown(0),
        .modeToggle(0),
        .secureExit(0),
        .lateKeyDown(0),
        .mouseCommit(0),
        .sessionReplacement(0),
        .lateHanjaSelection,
        .activate(2),
        .lateKeyDown(2),
        .lateDeactivate(0)
    ]

    static func random(using generator: inout SplitMix64) -> LifecycleOperation {
        let controller = generator.nextInt(upperBound: 3)
        switch generator.nextInt(upperBound: 10) {
        case 0: return .activate(controller)
        case 1: return .lateKeyDown(controller)
        case 2: return .lateDeactivate(controller)
        case 3: return .sameClientFieldChange(controller)
        case 4: return .secureEnter(controller)
        case 5: return .secureExit(controller)
        case 6: return .modeToggle(controller)
        case 7: return .mouseCommit(controller)
        case 8: return .sessionReplacement(controller)
        default: return .lateHanjaSelection
        }
    }

    var description: String {
        switch self {
        case let .activate(id): "activate(C\(id))"
        case let .lateKeyDown(id): "lateKeyDown(C\(id))"
        case let .lateDeactivate(id): "lateDeactivate(C\(id))"
        case let .sameClientFieldChange(id): "sameClientFieldChange(C\(id))"
        case let .secureEnter(id): "secureEnter(C\(id))"
        case let .secureExit(id): "secureExit(C\(id))"
        case let .modeToggle(id): "modeToggle(C\(id))"
        case let .mouseCommit(id): "mouseCommit(C\(id))"
        case let .sessionReplacement(id): "sessionReplacement(C\(id))"
        case .lateHanjaSelection: "lateHanjaSelection"
        }
    }
}

private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func nextInt(upperBound: Int) -> Int {
        precondition(upperBound > 0)
        return Int(next() % UInt64(upperBound))
    }

    private mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

private final class LifecycleHarness {
    private final class Controller {
        let id: Int
        let bundleID: String
        var session: InputSession!
        var client: FakeIMKTextInput!
        var secure = false
        var field = 0
        var sessionOrdinal = 0

        init(id: Int, bundleID: String) {
            self.id = id
            self.bundleID = bundleID
        }
    }

    private struct WriteObservation {
        let kind: String
        let controllerID: Int
        let visibleOwnerMatched: Bool
        let currentSessionMatched: Bool
        let hadConfirmedGeneration: Bool
        let wasSecure: Bool
    }

    private struct StaleHanjaSelection {
        let controllerID: Int
        let session: InputSession
        let snapshot: HanjaSelectionSnapshot
        let expectedText: String
    }

    private let registry = ActiveOwnerHandoffRegistry<Controller>()
    private let inputModeStore = InputModeStore(initialMode: .korean)
    private var writes: [WriteObservation] = []
    private var staleHanjaSelections: [StaleHanjaSelection] = []
    private var allSessions: [InputSession] = []
    private var allClients: [FakeIMKTextInput] = []
    private lazy var controllers: [Controller] = [
        Controller(id: 0, bundleID: "com.google.Chrome"),
        Controller(id: 1, bundleID: "com.tinyspeck.slackmacgap"),
        Controller(id: 2, bundleID: "com.apple.TextEdit")
    ]

    init() {
        for controller in controllers {
            installFreshSession(on: controller)
        }
    }

    func apply(_ operation: LifecycleOperation, step: Int) throws {
        let writeStart = writes.count
        switch operation {
        case let .activate(id):
            try activate(controllers[id])
        case let .lateKeyDown(id):
            try routeLateKeyDown(to: controllers[id])
        case let .lateDeactivate(id):
            try lateDeactivate(controllers[id])
        case let .sameClientFieldChange(id):
            try sameClientFieldChange(controllers[id])
        case let .secureEnter(id):
            try enterSecureInput(controllers[id])
        case let .secureExit(id):
            try exitSecureInput(controllers[id])
        case let .modeToggle(id):
            try toggleMode(controllers[id])
        case let .mouseCommit(id):
            try mouseCommit(controllers[id])
        case let .sessionReplacement(id):
            try replaceSession(controllers[id])
        case .lateHanjaSelection:
            try deliverLateHanjaSelection()
        }
        try validateWrites(from: writeStart, step: step, operation: operation)
    }

    func validateGlobalInvariants(step: Int) throws {
        if let owner = registry.owner, owner.secure,
           owner.session.clientWriteGeneration != nil {
            throw LifecycleInvariantError(
                "step \(step): Secure owner C\(owner.id) retained a client write generation"
            )
        }
        for controller in controllers where controller.session.contextNeedsRefresh {
            if controller.session.captureContextStateLease() != nil {
                throw LifecycleInvariantError(
                    "step \(step): stale session C\(controller.id) issued a context lease"
                )
            }
        }
    }

    private func installFreshSession(on controller: Controller) {
        controller.sessionOrdinal += 1
        let client = FakeIMKTextInput()
        client.bundleID = controller.bundleID
        client.document = "field-C\(controller.id)-S\(controller.sessionOrdinal):"
        client.selectedRangeValue = NSRange(location: client.document.utf16.count, length: 0)
        let composer = HangulComposer(
            statusBar: MockStatusBar(),
            configuration: MockConfiguration(),
            inputModeStore: inputModeStore
        )
        let session = InputSession(
            client: client,
            context: context(for: controller, secure: controller.secure),
            composer: composer,
            experimentalDirectInsertion: { false },
            invalidateCursorContext: {}
        )

        controller.client = client
        controller.session = session
        allClients.append(client)
        allSessions.append(session)

        client.onInsertText = { [weak self, weak controller, weak session] in
            self?.recordWrite(
                kind: "insertText",
                controller: controller,
                session: session
            )
        }
        client.onSetMarkedText = { [weak self, weak controller, weak session] in
            self?.recordWrite(
                kind: "setMarkedText",
                controller: controller,
                session: session
            )
        }
    }

    private func activate(_ incoming: Controller) throws {
        let previous = registry.owner
        let previousInsertCount = previous?.client.insertCalls.count ?? 0
        let acquired = registry.claim(incoming) { retiring in
            retiring.session.retireForControllerHandoff(
                fieldIdentityMayHaveChanged: retiring.client === incoming.client
            )
        }
        guard acquired else { return }
        incoming.session.markContextStaleForSameClientReactivation()
        let finalizedCount = (previous?.client.insertCalls.count ?? 0) - previousInsertCount
        try requireAtMostOneFinalize(
            finalizedCount,
            boundary: "activation handoff"
        )
    }

    private func routeLateKeyDown(to incoming: Controller) throws {
        if InputBoundaryOwnershipPolicy.requiresClaim(
            candidate: incoming,
            currentOwner: registry.owner
        ) {
            let acquired = registry.claim(incoming) { retiring in
                retiring.session.prepareForLateInputBoundaryHandoff()
                retiring.session.finishControllerHandoff()
            }
            guard acquired else { return }
        }
        guard registry.owner === incoming else { return }

        _ = incoming.session.refreshContextIfNeeded { _ in
            self.context(for: incoming, secure: incoming.secure)
        }
        if incoming.secure {
            _ = HangyeolInputController.routeSecureKeyDown(
                in: incoming.session,
                keyCode: 15
            )
            return
        }

        _ = incoming.session.prepareForNonSecureClientWrites()
        guard let lease = incoming.session.captureContextStateLease() else {
            throw LifecycleInvariantError("nonsecure keyDown did not receive a lease")
        }
        incoming.session.ensureAdapterMatchesPolicy()
        guard incoming.session.isCurrent(lease), registry.owner === incoming else {
            throw LifecycleInvariantError("keyDown lease changed before composition")
        }
        _ = incoming.session.composer.handle(
            TestEventFactory.keyEvent(char: "r", keyCode: 15)!,
            delegate: incoming.session.adapter
        )
        _ = incoming.session.composer.handle(
            TestEventFactory.keyEvent(char: "k", keyCode: 40)!,
            delegate: incoming.session.adapter
        )
    }

    private func lateDeactivate(_ controller: Controller) throws {
        let ownerBefore = registry.owner
        let wasStale = ownerBefore !== controller
        let insertCount = controller.client.insertCalls.count
        let markCount = controller.client.markCalls.count
        let snapshot = HangyeolInputController.captureDeactivationSnapshot(
            session: controller.session,
            sender: controller.client
        )
        _ = snapshot?.session.finalize(reason: .deactivateServer)
        _ = HangyeolInputController.finishDeactivation(
            snapshot,
            currentSession: controller.session
        ) {
            self.registry.release(controller)
        }
        _ = snapshot?.session.finalize(reason: .deactivateServer)

        let finalizedCount = controller.client.insertCalls.count - insertCount
        try requireAtMostOneFinalize(finalizedCount, boundary: "deactivate")
        if wasStale {
            guard registry.owner === ownerBefore else {
                throw LifecycleInvariantError("late deactivate released a newer owner")
            }
            guard controller.client.insertCalls.count == insertCount,
                  controller.client.markCalls.count == markCount else {
                throw LifecycleInvariantError("stale deactivate wrote to its client")
            }
        }
    }

    private func sameClientFieldChange(_ controller: Controller) throws {
        guard registry.owner === controller else { return }
        captureHanjaSelectionBeforeBoundary(controller)
        let insertCount = controller.client.insertCalls.count
        let markCount = controller.client.markCalls.count
        controller.field += 1
        controller.session.markContextStale()
        controller.client.document = "field-C\(controller.id)-F\(controller.field):"
        controller.client.markedText = ""
        controller.client.markedRangeValue = NSRange(location: NSNotFound, length: 0)
        controller.client.selectedRangeValue = NSRange(
            location: controller.client.document.utf16.count,
            length: 0
        )
        controller.session.refreshContext(
            context(for: controller, secure: controller.secure),
            fieldIdentityMayHaveChanged: true
        )
        if controller.secure {
            controller.session.discardForSecureInput()
        } else {
            _ = controller.session.prepareForNonSecureClientWrites()
        }
        guard controller.client.insertCalls.count == insertCount,
              controller.client.markCalls.count == markCount else {
            throw LifecycleInvariantError("previous field composition moved into the next field")
        }
    }

    private func enterSecureInput(_ controller: Controller) throws {
        guard registry.owner === controller else { return }
        captureHanjaSelectionBeforeBoundary(controller)
        let insertCount = controller.client.insertCalls.count
        let markCount = controller.client.markCalls.count
        controller.secure = true
        controller.field += 1
        controller.session.markContextStale()
        controller.client.document = "secure-C\(controller.id)-F\(controller.field):"
        controller.client.markedText = ""
        controller.client.markedRangeValue = NSRange(location: NSNotFound, length: 0)
        controller.client.selectedRangeValue = NSRange(
            location: controller.client.document.utf16.count,
            length: 0
        )
        controller.session.refreshContext(
            context(for: controller, secure: true),
            fieldIdentityMayHaveChanged: true
        )
        _ = HangyeolInputController.routeSecureKeyDown(
            in: controller.session,
            keyCode: 15
        )
        guard controller.client.insertCalls.count == insertCount,
              controller.client.markCalls.count == markCount else {
            throw LifecycleInvariantError("Secure Input received a client write")
        }
    }

    private func exitSecureInput(_ controller: Controller) throws {
        guard registry.owner === controller else { return }
        let insertCount = controller.client.insertCalls.count
        let markCount = controller.client.markCalls.count
        controller.secure = false
        controller.field += 1
        controller.session.markContextStale()
        controller.client.document = "field-C\(controller.id)-F\(controller.field):"
        controller.client.markedText = ""
        controller.client.markedRangeValue = NSRange(location: NSNotFound, length: 0)
        controller.client.selectedRangeValue = NSRange(
            location: controller.client.document.utf16.count,
            length: 0
        )
        controller.session.refreshContext(
            context(for: controller, secure: false),
            fieldIdentityMayHaveChanged: true
        )
        _ = controller.session.prepareForNonSecureClientWrites()
        guard controller.client.insertCalls.count == insertCount,
              controller.client.markCalls.count == markCount else {
            throw LifecycleInvariantError("Secure exit cleaned an unproven previous field")
        }
    }

    private func toggleMode(_ controller: Controller) throws {
        guard registry.owner === controller else { return }
        let insertCount = controller.client.insertCalls.count
        if controller.secure {
            controller.session.discardForSecureInput()
            controller.session.composer.setInputMode(
                controller.session.composer.inputMode.toggled
            )
            guard controller.client.insertCalls.count == insertCount else {
                throw LifecycleInvariantError("secure mode toggle inserted text")
            }
            return
        }
        _ = controller.session.prepareForNonSecureClientWrites()
        _ = controller.session.finalize(reason: .modeTransition)
        _ = controller.session.finalize(reason: .modeTransition)
        controller.session.composer.setInputMode(
            controller.session.composer.inputMode.toggled
        )
        try requireAtMostOneFinalize(
            controller.client.insertCalls.count - insertCount,
            boundary: "mode toggle"
        )
    }

    private func mouseCommit(_ controller: Controller) throws {
        guard registry.owner === controller else { return }
        let insertCount = controller.client.insertCalls.count
        if controller.secure {
            controller.session.discardForSecureInput()
        } else {
            _ = controller.session.prepareForNonSecureClientWrites()
            _ = controller.session.finalize(reason: .mouseCommit)
            _ = controller.session.finalize(reason: .mouseCommit)
            controller.session.finishHostCommitBoundary()
        }
        try requireAtMostOneFinalize(
            controller.client.insertCalls.count - insertCount,
            boundary: "mouse commit"
        )
    }

    private func replaceSession(_ controller: Controller) throws {
        guard registry.owner === controller else { return }
        captureHanjaSelectionBeforeBoundary(controller)
        let previous = controller.session!
        let previousClient = controller.client!
        let insertCount = previousClient.insertCalls.count
        let retirement = HangyeolInputController.captureSessionRetirementSnapshot(
            session: previous
        )
        previous.composer.dismissHanjaCandidates()
        _ = previous.finalize(reason: .sessionReplacement)
        let didRetire = HangyeolInputController.finishSessionRetirement(
            retirement,
            currentSession: controller.session
        ) {
            previous.disarmFocusLossFinalizer()
        }
        guard didRetire else {
            throw LifecycleInvariantError("current session replacement was rejected")
        }
        installFreshSession(on: controller)
        try requireAtMostOneFinalize(
            previousClient.insertCalls.count - insertCount,
            boundary: "session replacement"
        )

        let writesBeforeLateFinalize = writes.count
        _ = previous.finalize(reason: .deactivateServer)
        guard writes.count == writesBeforeLateFinalize else {
            throw LifecycleInvariantError("retired session wrote after replacement")
        }
    }

    private func captureHanjaSelectionBeforeBoundary(_ controller: Controller) {
        guard let generation = controller.session.clientWriteGeneration else { return }
        controller.client.document = "가"
        controller.client.selectedRangeValue = NSRange(location: 1, length: 0)
        staleHanjaSelections.append(StaleHanjaSelection(
            controllerID: controller.id,
            session: controller.session,
            snapshot: HanjaSelectionSnapshot(
                generation: 99,
                clientID: ObjectIdentifier(controller.client as AnyObject),
                sessionID: ObjectIdentifier(controller.session),
                fieldGeneration: generation,
                selectionLocation: 1
            ),
            expectedText: "가"
        ))
    }

    private func deliverLateHanjaSelection() throws {
        guard !staleHanjaSelections.isEmpty else { return }
        let stale = staleHanjaSelections.removeFirst()
        let insertCount = (stale.session.client as? FakeIMKTextInput)?.insertCalls.count ?? 0
        let markCount = (stale.session.client as? FakeIMKTextInput)?.markCalls.count ?? 0
        let controller = controllers[stale.controllerID]
        let callbackStillOwnsSession = registry.owner === controller
            && controller.session === stale.session
        let routed = callbackStillOwnsSession && HangyeolInputController.routeHanjaSelection(
            in: stale.session,
            snapshot: stale.snapshot,
            isSecureInput: controller.secure,
            expectedText: stale.expectedText,
            replacement: "可"
        )
        guard !routed else {
            throw LifecycleInvariantError("late Hanja selection was accepted")
        }
        if let client = stale.session.client as? FakeIMKTextInput {
            guard client.insertCalls.count == insertCount,
                  client.markCalls.count == markCount,
                  client.document != "可" else {
                throw LifecycleInvariantError("late Hanja selection wrote to a client")
            }
        }
    }

    private func recordWrite(
        kind: String,
        controller: Controller?,
        session: InputSession?
    ) {
        guard let controller, let session else { return }
        writes.append(WriteObservation(
            kind: kind,
            controllerID: controller.id,
            visibleOwnerMatched: registry.owner === controller,
            currentSessionMatched: controller.session === session,
            hadConfirmedGeneration: session.clientWriteGeneration != nil,
            wasSecure: controller.secure
        ))
    }

    private func validateWrites(
        from start: Int,
        step: Int,
        operation: LifecycleOperation
    ) throws {
        for write in writes[start...] {
            guard write.visibleOwnerMatched else {
                throw LifecycleInvariantError(
                    "step \(step) \(operation): C\(write.controllerID) \(write.kind) without ownership"
                )
            }
            guard write.currentSessionMatched else {
                throw LifecycleInvariantError(
                    "step \(step) \(operation): retired session performed \(write.kind)"
                )
            }
            guard write.hadConfirmedGeneration else {
                throw LifecycleInvariantError(
                    "step \(step) \(operation): unconfirmed generation performed \(write.kind)"
                )
            }
            guard !write.wasSecure else {
                throw LifecycleInvariantError(
                    "step \(step) \(operation): Secure Input performed \(write.kind)"
                )
            }
        }
    }

    private func context(for controller: Controller, secure: Bool) -> ClientContext {
        ClientContext(
            bundleId: controller.bundleID,
            hasTextInputCapability: !secure,
            isLikelyDesktopArea: false,
            documentAccessSafe: !secure
        )
    }

    private func requireAtMostOneFinalize(_ count: Int, boundary: String) throws {
        guard count <= 1 else {
            throw LifecycleInvariantError(
                "\(boundary) finalized composition \(count) times"
            )
        }
    }
}

private struct LifecycleInvariantError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
