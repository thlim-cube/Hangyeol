import Foundation
import Testing
@testable import HangyeolCore

@Suite("Caps Lock ownership preference cache")
struct CapsLockSwitchStateCacheTests {
    @Test("Hot-path reads use the initial snapshot without re-reading preferences")
    func repeatedReadsStayInMemory() {
        let probe = BooleanPreferenceProbe(initialValue: false)
        let cache = CapsLockSwitchStateCache(reader: probe.read)

        #expect(probe.readCount == 1)
        for _ in 0..<1_000 {
            #expect(!cache.value)
        }
        #expect(probe.readCount == 1)

        probe.value = true
        #expect(!cache.value)
        #expect(probe.readCount == 1)
    }

    @Test("Explicit refresh atomically publishes only real ownership changes")
    func refreshUpdatesSnapshot() {
        let probe = BooleanPreferenceProbe(initialValue: false)
        let cache = CapsLockSwitchStateCache(reader: probe.read)

        #expect(cache.refresh() == nil)
        #expect(probe.readCount == 2)

        probe.value = true
        #expect(cache.refresh() == .init(previousValue: false, currentValue: true))
        #expect(cache.value)
        #expect(probe.readCount == 3)

        #expect(cache.refresh() == nil)
        #expect(probe.readCount == 4)
    }

    @Test("Preference refresh does not block hot-path snapshot reads")
    func refreshDoesNotBlockReads() {
        let probe = BlockingPreferenceProbe()
        let cache = CapsLockSwitchStateCache(reader: probe.read)
        let refreshFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            cache.refresh()
            refreshFinished.signal()
        }

        let readerStarted = probe.readerStarted.wait(timeout: .now() + 2)
        #expect(readerStarted == .success)
        guard readerStarted == .success else {
            probe.allowReaderToFinish.signal()
            _ = refreshFinished.wait(timeout: .now() + 2)
            return
        }

        let hotPathReadFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = cache.value
            hotPathReadFinished.signal()
        }

        let hotPathReadResult = hotPathReadFinished.wait(timeout: .now() + 2)
        probe.allowReaderToFinish.signal()

        #expect(hotPathReadResult == .success)
        #expect(refreshFinished.wait(timeout: .now() + 2) == .success)
    }
}

private final class BooleanPreferenceProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Bool
    private var storedReadCount = 0

    init(initialValue: Bool) {
        storedValue = initialValue
    }

    var value: Bool {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }

    var readCount: Int {
        lock.withLock { storedReadCount }
    }

    func read() -> Bool {
        lock.withLock {
            storedReadCount += 1
            return storedValue
        }
    }
}

private final class BlockingPreferenceProbe: @unchecked Sendable {
    let readerStarted = DispatchSemaphore(value: 0)
    let allowReaderToFinish = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private var readCount = 0

    func read() -> Bool {
        let shouldBlock = lock.withLock {
            readCount += 1
            return readCount == 2
        }
        if shouldBlock {
            readerStarted.signal()
            allowReaderToFinish.wait()
        }
        return false
    }
}
