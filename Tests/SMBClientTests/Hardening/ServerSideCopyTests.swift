import XCTest
@testable import SMBClient

// RUMSKROT-TESTS: server-side copy. The payloads are checked byte for byte
// against MS-SMB2 2.2.31.1 / 2.2.32.1 / 2.2.32.3, and the whole exchange —
// resume key, a refused request, requests sized to the server's limits —
// runs against the scripted localhost server. No Samba container needed.
final class ServerSideCopyTests: XCTestCase {
  // MARK: - Payloads

  func testChunkEncodesAsTwentyFourBytes() {
    let chunk = ServerSideCopy.Chunk(sourceOffset: 0x0102, targetOffset: 0x0304, length: 0x0506)
    var expected = Data()
    expected += UInt64(0x0102)
    expected += UInt64(0x0304)
    expected += UInt32(0x0506)
    expected += UInt32(0)
    XCTAssertEqual(chunk.encoded(), expected)
    XCTAssertEqual(chunk.encoded().count, 24)
  }

  func testCopyChunkCopyEncodesKeyCountAndChunks() {
    let key = Data(repeating: 0xAA, count: 24)
    let chunks = [
      ServerSideCopy.Chunk(sourceOffset: 0, targetOffset: 0, length: 10),
      ServerSideCopy.Chunk(sourceOffset: 10, targetOffset: 10, length: 5),
    ]
    let encoded = ServerSideCopy.CopyChunkCopy(sourceKey: key, chunks: chunks).encoded()
    XCTAssertEqual(encoded.count, 24 + 4 + 4 + 2 * 24)
    XCTAssertEqual(encoded.prefix(24), key)
    XCTAssertEqual(encoded[24..<28], Data(from: UInt32(2)))
    XCTAssertEqual(encoded[28..<32], Data(from: UInt32(0)))
    XCTAssertEqual(encoded[32...], chunks[0].encoded() + chunks[1].encoded())
  }

  func testResumeKeyAndCopyChunkResponseDecode() throws {
    let key = try ServerSideCopy.ResumeKey(data: Self.resumeKeyOutput())
    XCTAssertEqual(key.key, Data(repeating: 0xAA, count: 24))
    XCTAssertEqual(key.contextLength, 4)

    let response = try ServerSideCopy.CopyChunkResponse(data: Self.copyChunkOutput(1, 2, 3))
    XCTAssertEqual(response.chunksWritten, 1)
    XCTAssertEqual(response.chunkBytesWritten, 2)
    XCTAssertEqual(response.totalBytesWritten, 3)
  }

  func testTruncatedPayloadsThrow() {
    let resumeKey = Self.resumeKeyOutput()
    for length in 0..<28 {
      XCTAssertThrowsError(try ServerSideCopy.ResumeKey(data: resumeKey.prefix(length)))
    }
    let copyChunk = Self.copyChunkOutput(1, 2, 3)
    for length in 0..<12 {
      XCTAssertThrowsError(try ServerSideCopy.CopyChunkResponse(data: copyChunk.prefix(length)))
    }
  }

  func testLimitsSplitAFileIntoRequests() {
    let limits = ServerSideCopy.Limits(maxChunkCount: 2, maxChunkSize: 500, maxTotalSize: 800)
    XCTAssertEqual(limits.chunks(from: 0, size: 1234), [
      ServerSideCopy.Chunk(sourceOffset: 0, targetOffset: 0, length: 500),
      ServerSideCopy.Chunk(sourceOffset: 500, targetOffset: 500, length: 300),
    ])
    XCTAssertEqual(limits.chunks(from: 800, size: 1234), [
      ServerSideCopy.Chunk(sourceOffset: 800, targetOffset: 800, length: 434),
    ])
    XCTAssertEqual(limits.chunks(from: 1234, size: 1234), [])
    XCTAssertEqual(ServerSideCopy.Limits.default.chunks(from: 0, size: 1234).count, 1)
  }

  // MARK: - Over the wire

  func testCopyAdoptsTheLimitsTheServerReports() async throws {
    let (session, server) = try await connect(replies: [
      ResponseFixtures.negotiate(),
      ResponseFixtures.create(contexts: Data()),
      Self.ioctl(output: Self.resumeKeyOutput()),
      ResponseFixtures.create(contexts: Data()),
      Self.ioctl(status: Self.invalidParameter, output: Self.copyChunkOutput(2, 500, 1000)),
      Self.ioctl(output: Self.copyChunkOutput(2, 500, 1000)),
      Self.ioctl(output: Self.copyChunkOutput(1, 234, 234)),
      ResponseFixtures.close(),
      ResponseFixtures.close(),
    ])
    try await session.negotiate()

    var reported = [UInt64]()
    try await session.copyFile(from: "a.bin", to: "b.bin") { copied, total in
      XCTAssertEqual(total, 1234)
      reported.append(copied)
    }
    XCTAssertEqual(reported, [0, 1000, 1234])

    let requests = server.requests
    XCTAssertEqual(requests.count, 9)
    XCTAssertEqual(Self.command(requests[2]), Header.Command.ioctl.rawValue)
    XCTAssertEqual(Self.ctlCode(requests[2]), IOCtl.CtlCode.srvRequestResumeKey.rawValue)
    // The destination is created, never opened over an existing file.
    XCTAssertEqual(Self.createDisposition(requests[3]), Create.CreateDisposition.create.rawValue)
    // First within the default limits: the whole file in one chunk.
    XCTAssertEqual(Self.ctlCode(requests[4]), IOCtl.CtlCode.srvCopyChunk.rawValue)
    XCTAssertEqual(Self.chunks(requests[4]).map(\.length), [1234])
    // Then within what the server said.
    XCTAssertEqual(Self.sourceKey(requests[5]), Data(repeating: 0xAA, count: 24))
    XCTAssertEqual(Self.chunks(requests[5]).map(\.length), [500, 500])
    XCTAssertEqual(Self.chunks(requests[6]), [
      ServerSideCopy.Chunk(sourceOffset: 1000, targetOffset: 1000, length: 234),
    ])
    XCTAssertEqual(Self.command(requests[7]), Header.Command.close.rawValue)
    XCTAssertEqual(Self.command(requests[8]), Header.Command.close.rawValue)
  }

  func testRefusalWithinTheReportedLimitsIsFinalAndTheDestinationGoes() async throws {
    let (session, server) = try await connect(replies: [
      ResponseFixtures.negotiate(),
      ResponseFixtures.create(contexts: Data()),
      Self.ioctl(output: Self.resumeKeyOutput()),
      ResponseFixtures.create(contexts: Data()),
      Self.ioctl(status: Self.invalidParameter, output: Self.copyChunkOutput(16, 1024 * 1024, 16 * 1024 * 1024)),
      ResponseFixtures.close(),
    ])
    try await session.negotiate()

    do {
      try await session.copyFile(from: "a.bin", to: "b.bin")
      XCTFail("expected the refusal to be final")
    } catch ServerSideCopyError.limitsRefused {
    }
    // The partial destination is closed, then deleted (the server hangs up
    // after the close, so the delete is all we can see of it if it got
    // that far).
    let requests = server.requests
    XCTAssertGreaterThanOrEqual(requests.count, 6)
    XCTAssertEqual(Self.command(requests[5]), Header.Command.close.rawValue)
  }

  func testAnEmptyFileSendsNoCopyChunk() async throws {
    var empty = ResponseFixtures.create(contexts: Data())
    empty.replaceSubrange(112..<120, with: Data(from: UInt64(0)))
    let (session, server) = try await connect(replies: [
      ResponseFixtures.negotiate(),
      empty,
      Self.ioctl(output: Self.resumeKeyOutput()),
      ResponseFixtures.create(contexts: Data()),
      ResponseFixtures.close(),
      ResponseFixtures.close(),
    ])
    try await session.negotiate()
    try await session.copyFile(from: "a.bin", to: "b.bin")
    let requests = server.requests
    XCTAssertEqual(requests.count, 6)
    XCTAssertFalse(requests.contains { Self.ctlCode($0) == IOCtl.CtlCode.srvCopyChunk.rawValue })
  }

  func testAServerThatWritesNothingEndsTheCopy() async throws {
    let (session, _) = try await connect(replies: [
      ResponseFixtures.negotiate(),
      ResponseFixtures.create(contexts: Data()),
      Self.ioctl(output: Self.resumeKeyOutput()),
      ResponseFixtures.create(contexts: Data()),
      Self.ioctl(output: Self.copyChunkOutput(0, 0, 0)),
    ])
    try await session.negotiate()
    do {
      try await session.copyFile(from: "a.bin", to: "b.bin")
      XCTFail("expected no progress to end the copy")
    } catch ServerSideCopyError.noProgress(let offset) {
      XCTAssertEqual(offset, 0)
    }
  }

  // MARK: - Helpers

  private static let invalidParameter: UInt32 = 0xC000000D

  private var servers = [ScriptedServer]()

  override func tearDown() {
    servers.forEach { $0.stop() }
    servers.removeAll()
    super.tearDown()
  }

  private func connect(replies: [Data]) async throws -> (Session, ScriptedServer) {
    let server = try ScriptedServer(replies: replies.map(ResponseFixtures.frame))
    servers.append(server)
    let port = try await server.start()
    let session = Session(host: "127.0.0.1", port: port)
    try await session.connect()
    return (session, server)
  }

  static func resumeKeyOutput() -> Data {
    var data = Data(repeating: 0xAA, count: 24)
    data += UInt32(4)
    data += UInt32(0)
    return data
  }

  static func copyChunkOutput(_ chunks: UInt32, _ chunkBytes: UInt32, _ total: UInt32) -> Data {
    var data = Data()
    data += chunks
    data += chunkBytes
    data += total
    return data
  }

  static func ioctl(status: UInt32 = 0, output: Data) -> Data {
    var data = ResponseFixtures.header(command: .ioctl, status: status)
    data += UInt16(49)
    data += UInt16(0)
    data += UInt32(0x001440F2)
    data += Data(repeating: 0x42, count: 16)
    data += UInt32(112)
    data += UInt32(0)
    data += UInt32(112)
    data += UInt32(output.count)
    data += UInt32(0)
    data += UInt32(0)
    data += output
    return data
  }

  // Request fields, at their MS-SMB2 offsets from the start of the message.

  static func command(_ request: Data) -> UInt16 {
    request[(request.startIndex + 12)..<(request.startIndex + 14)].to(type: UInt16.self)
  }

  static func ctlCode(_ request: Data) -> UInt32 {
    request[(request.startIndex + 68)..<(request.startIndex + 72)].to(type: UInt32.self)
  }

  static func createDisposition(_ request: Data) -> UInt32 {
    request[(request.startIndex + 100)..<(request.startIndex + 104)].to(type: UInt32.self)
  }

  static func ioctlInput(_ request: Data) -> Data {
    let count = Int(request[(request.startIndex + 92)..<(request.startIndex + 96)].to(type: UInt32.self))
    return Data(request[(request.startIndex + 120)..<(request.startIndex + 120 + count)])
  }

  static func sourceKey(_ request: Data) -> Data {
    ioctlInput(request).prefix(24)
  }

  static func chunks(_ request: Data) -> [ServerSideCopy.Chunk] {
    let input = ioctlInput(request)
    let count = Int(input[24..<28].to(type: UInt32.self))
    return (0..<count).map { index in
      let base = 32 + index * 24
      return ServerSideCopy.Chunk(
        sourceOffset: input[base..<(base + 8)].to(type: UInt64.self),
        targetOffset: input[(base + 8)..<(base + 16)].to(type: UInt64.self),
        length: input[(base + 16)..<(base + 20)].to(type: UInt32.self)
      )
    }
  }
}
