// `--out` must be a regular file, flushed with a checked F_FULLFSYNC (#219 review N2: /dev/null was
// accepted, and a plain fsync reported the write as durable).

import XCTest
@testable import HelioVerify

@available(macOS 10.15.4, *)
final class OutFileTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("OutFileTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func rejection(_ path: String) -> OutFileError? {
        if case .failure(let error) = OutFile.open(path) { return error }
        return nil
    }

    func testDevNullIsRejectedWithAClearMessage() throws {
        let error = try XCTUnwrap(rejection("/dev/null"))
        XCTAssertEqual(error, .notRegularFile(path: "/dev/null", kind: "a character device"))
        XCTAssertEqual(error.description, "--out must be a regular file, and '/dev/null' is a character device: a round written there would count as saved without being stored")
    }

    func testDirectoryAndPipeAreRejected() throws {
        XCTAssertEqual(rejection(directory.path), .notRegularFile(path: directory.path, kind: "a directory"))
        let fifo = directory.appendingPathComponent("fifo").path
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        // Checked before opening: a FIFO with no reader would otherwise block the open.
        XCTAssertEqual(rejection(fifo), .notRegularFile(path: fifo, kind: "a pipe"))
    }

    func testMissingParentCannotBeCreated() {
        let path = directory.appendingPathComponent("missing/out.jsonl").path
        XCTAssertEqual(rejection(path), .cannotCreate(path: path))
    }

    func testRegularFileIsCreatedAppendedToAndFullySynced() throws {
        let path = directory.appendingPathComponent("out.jsonl").path
        let first = try OutFile.open(path).get()
        try first.write(contentsOf: Data("one\n".utf8))
        XCTAssertNoThrow(try OutFile.synchronize(first))
        try first.close()
        // Reopening appends rather than truncating.
        let second = try OutFile.open(path).get()
        try second.write(contentsOf: Data("two\n".utf8))
        XCTAssertNoThrow(try OutFile.synchronize(second))
        try second.close()
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "one\ntwo\n")
    }

    func testSymlinkToARegularFileIsAccepted() throws {
        let target = directory.appendingPathComponent("target.jsonl")
        XCTAssertTrue(FileManager.default.createFile(atPath: target.path, contents: nil))
        let link = directory.appendingPathComponent("link.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let handle = try OutFile.open(link.path).get()
        try handle.close()
    }
}
