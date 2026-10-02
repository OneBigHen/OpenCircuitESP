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

    /// #222 review Q2 + U2 (#215 phase 4). The BGTask handler (ring and strap), the Sleep Focus filter,
    /// AppDelegate's restoration wiring and the intents resolve their store through
    /// `sharedOrFallbackContainer()`: a fallback-built container is PUBLISHED, so a later site reuses
    /// it instead of opening a second container over the same SQLite file, and every one of those
    /// sites builds its store with `LocalStore(container:)`, which keeps the container alive even if
    /// nothing else does.
    func testAFallbackContainerIsPublishedReusedAndKeptAliveByTheBackgroundSites() throws {
        let launchContainer = OpenCircuitApp.sharedContainer
        defer { OpenCircuitApp.sharedContainer = launchContainer }
        OpenCircuitApp.sharedContainer = nil   // a launch that couldn't open the store (before the first unlock)

        weak var weakContainer: ModelContainer?
        func backgroundSiteStore() throws -> LocalStore {
            let container = try OpenCircuitApp.sharedOrFallbackContainer(storeURL: storeURL)
            weakContainer = container
            return LocalStore(container: container)
        }
        let store = try backgroundSiteStore()
        XCTAssertNotNil(OpenCircuitApp.sharedContainer, "the fallback container is published")
        XCTAssertTrue(OpenCircuitApp.sharedContainer === weakContainer)

        // A later site (the next wake, an intent) gets the SAME container, not a second one.
        let otherURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencircuit-lifetime-other-\(UUID().uuidString).store")
        XCTAssertTrue(try OpenCircuitApp.sharedOrFallbackContainer(storeURL: otherURL) === weakContainer)
        XCTAssertFalse(FileManager.default.fileExists(atPath: otherURL.path), "no second store was opened")
        XCTAssertTrue(try OpenCircuitApp.backgroundStore().context.container === weakContainer)

        // The store keeps its container alive on its own (the #218 S1 trap), even once nothing else does.
        OpenCircuitApp.sharedContainer = nil
        XCTAssertNotNil(weakContainer, "the store must keep its container alive")
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let sample = QuantitySample(kind: .heartRate, start: at, value: 58)
        XCTAssertEqual(try store.ingest([sample]), [sample])
        XCTAssertEqual(try store.pendingHealthSamples(), [sample])
    }

    func testAStoreThatCannotOpenIsNotPublished() throws {
        let launchContainer = OpenCircuitApp.sharedContainer
        defer { OpenCircuitApp.sharedContainer = launchContainer }
        OpenCircuitApp.sharedContainer = nil
        // A path under a regular file can never hold a store: the open throws, as it does before the
        // first unlock, and nothing is published or wiped.
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("opencircuit-blocker-\(UUID().uuidString)")
        XCTAssertTrue(FileManager.default.createFile(atPath: blocker.path, contents: Data([0x01])))
        defer { try? FileManager.default.removeItem(at: blocker) }
        XCTAssertThrowsError(try OpenCircuitApp.sharedOrFallbackContainer(storeURL: blocker.appendingPathComponent("x.store")))
        XCTAssertNil(OpenCircuitApp.sharedContainer)
        XCTAssertEqual(try Data(contentsOf: blocker), Data([0x01]))
    }
}
