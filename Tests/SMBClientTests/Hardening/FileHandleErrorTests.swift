import XCTest
@testable import SMBClient

// RUMSKROT-TESTS: a download whose local writes fail — a full disk, here a
// handle that cannot write — throws instead of terminating the process with
// an uncatchable Objective-C exception (RumskrotNavigator#244).
final class FileHandleErrorTests: XCTestCase {
  private var servers = [ScriptedServer]()

  override func tearDown() {
    servers.forEach { $0.stop() }
    servers.removeAll()
    super.tearDown()
  }

  func testDownloadIntoAnUnwritableHandleThrows() async throws {
    let server = try ScriptedServer(replies: [
      ResponseFixtures.frame(ResponseFixtures.negotiate()),
      ResponseFixtures.frame(ResponseFixtures.create(contexts: Data())),
      ResponseFixtures.frame(ResponseFixtures.read()),
    ])
    servers.append(server)
    let port = try await server.start()
    let session = Session(host: "127.0.0.1", port: port)
    try await session.connect()
    try await session.negotiate()

    let url = FileManager.default.temporaryDirectory.appendingPathComponent("smb-\(UUID().uuidString).bin")
    try Data().write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    // Open for reading only: every write fails, as it does on a full disk.
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    let reader = FileReader(session: session, path: "file.txt")
    do {
      try await reader.download(fileHandle: handle)
      XCTFail("expected the write to throw")
    } catch is ResponseDecodingError {
      XCTFail("the write failed, not the reply")
    } catch {
      // Thrown, not trapped.
    }
  }

  func testUploadReadsWithTheThrowingCall() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("smb-\(UUID().uuidString).bin")
    try Data("hello".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    XCTAssertEqual(try handle.readChunk(upToCount: 3), Data("hel".utf8))
    XCTAssertEqual(try handle.readChunk(upToCount: 10), Data("lo".utf8))
    XCTAssertEqual(try handle.readChunk(upToCount: 10), Data())
  }
}
