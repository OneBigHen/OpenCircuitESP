import SwiftData
import XCTest
import OpenCircuitKit
@testable import OpenCircuit

/// A `LocalStore` built from a container nothing else retains (review #218 S1).
///
/// `AppDelegate`'s restoration relaunch, `exportStore()` and `quickLogStore()` fall back to
/// `OpenCircuitApp.makeContainerOrThrow()` when `sharedContainer` is nil and keep only the store.
/// A `ModelContext` does not retain its container, so with `LocalStore(container.mainContext)` the
/// container was released on return and the first fetch trapped the process ("Test crashed with
/// signal trap" in the reviewer's probe, on an on-disk store). This is that probe, asserting the fix:
/// those call sites now build the store with `LocalStore(container:)`, which keeps the container
/// alive. If the retention regresses, this test takes the host down; it doesn't fail quietly.
@MainActor
final class LocalStoreContainerLifetimeTests: XCTestCase {
    private var storeURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencircuit-lifetime-\(UUID().uuidString).store")
    }

    override func tearDownWithError() throws {
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
        }
        storeURL = nil
        try super.tearDownWithError()
    }

    func testAStoreBuiltFromAFallbackContainerOutlivesTheScopeThatBuiltIt() throws {
        weak var weakContainer: ModelContainer?
        func fallbackStore() throws -> LocalStore {
            let container = try OpenCircuitApp.makeContainerOrThrow(storeURL: storeURL)
            weakContainer = container
            return LocalStore(container: container)
        }
        let store = try fallbackStore()
        XCTAssertNotNil(weakContainer, "the store must keep its container alive")

        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let sample = QuantitySample(kind: .heartRate, start: at, value: 61)
        XCTAssertEqual(try store.ingest([sample]), [sample])
        XCTAssertEqual(try store.loadCursor().last(.heartRate), at)
        XCTAssertEqual(try store.pendingHealthSamples(), [sample])
    }
}
