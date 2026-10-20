import XCTest
import Network
@testable import SMBClient

// RUMSKROT-TESTS: the same guarantee end to end. A scripted server on
// localhost answers each request with the next canned reply — framing
// included, so the framing itself can be broken — and then closes. Every
// malformed reply must surface as a thrown error, never a trap or a hang.
final class MalformedServerTests: XCTestCase {
  func testShortFrameIsRefused() async throws {
    let session = try await connect(replies: [ResponseFixtures.frame(Data(count: 10))])
    await assertDecodingError { try await session.negotiate() }
  }

  func testFrameLengthBeyondTwentyFourBitsIsRefused() async throws {
    let raw = Data([0x01, 0x00, 0x00, 0x40]) + ResponseFixtures.negotiate().prefix(64)
    let session = try await connect(replies: [raw])
    await assertDecodingError { try await session.negotiate() }
  }

  func testTruncatedNegotiateBodyIsRefused() async throws {
    let session = try await connect(replies: [ResponseFixtures.frame(ResponseFixtures.negotiate().prefix(70))])
    await assertDecodingError { try await session.negotiate() }
  }

  func testZeroNegotiatedReadSizeIsRefused() async throws {
    let session = try await connect(replies: [ResponseFixtures.frame(ResponseFixtures.negotiate(maxReadSize: 0))])
    await assertDecodingError { try await session.negotiate() }
  }

  func testCompoundReplyMissingAPartIsRefused() async throws {
    let session = try await connect(replies: [
      ResponseFixtures.frame(ResponseFixtures.negotiate()),
      ResponseFixtures.frame(ResponseFixtures.create(contexts: Data())),
    ])
    try await session.negotiate()
    await assertDecodingError { _ = try await session.fileStat(path: "file.txt") }
  }

  func testNextCommandInsideTheHeaderIsRefused() async throws {
    var compound = ResponseFixtures.compoundCreateClose()
    compound.replaceSubrange(20..<24, with: Data(from: UInt32(8)))
    let session = try await connect(replies: [
      ResponseFixtures.frame(ResponseFixtures.negotiate()),
      ResponseFixtures.frame(compound),
    ])
    try await session.negotiate()
    await assertDecodingError { _ = try await session.fileStat(path: "file.txt") }
  }

  func testWellFormedCompoundReplyStillDecodes() async throws {
    let session = try await connect(replies: [
      ResponseFixtures.frame(ResponseFixtures.negotiate()),
      ResponseFixtures.frame(ResponseFixtures.compoundCreateClose()),
    ])
    try await session.negotiate()
    let stat = try await session.fileStat(path: "file.txt")
    XCTAssertEqual(stat.endOfFile, 1234)
  }

  func testReadLongerThanRequestedIsRefused() async throws {
    let session = try await connect(replies: [
      ResponseFixtures.frame(ResponseFixtures.negotiate()),
      ResponseFixtures.frame(ResponseFixtures.read(payload: Data(count: 64))),
    ])
    try await session.negotiate()
    await assertDecodingError {
      _ = try await session.read(fileId: Data(count: 16), offset: 0, length: 16)
    }
  }

  func testReadThatMakesNoProgressEndsTheTransfer() async throws {
    let session = try await connect(replies: [
      ResponseFixtures.frame(ResponseFixtures.negotiate()),
      ResponseFixtures.frame(ResponseFixtures.create(contexts: Data())),
      ResponseFixtures.frame(ResponseFixtures.read(payload: Data())),
    ])
    try await session.negotiate()
    let reader = FileReader(session: session, path: "file.txt")
    await assertDecodingError { _ = try await reader.read(offset: 0, length: 100) }
  }

  func testCorruptedRepliesOverTheWireNeverTrap() async throws {
    var rng = SplitMix64(seed: 0xF022)
    let compound = ResponseFixtures.compoundCreateClose()
    for iteration in 0..<300 {
      var message = [UInt8](compound)
      for _ in 0..<(1 + Int(rng.next() % 6)) {
        message[Int(rng.next() % UInt64(message.count))] = UInt8(truncatingIfNeeded: rng.next())
      }
      var reply = ResponseFixtures.frame(Data(message))
      if iteration % 10 == 0 {
        // Break the framing too, now and then.
        reply[Int(rng.next() % 4)] = UInt8(truncatingIfNeeded: rng.next())
      }
      let session = try await connect(replies: [ResponseFixtures.frame(ResponseFixtures.negotiate()), reply])
      try await session.negotiate()
      _ = try? await session.fileStat(path: "file.txt")
      session.disconnect()
    }
  }

  // MARK: - Helpers

  private var servers = [ScriptedServer]()

  override func tearDown() {
    servers.forEach { $0.stop() }
    servers.removeAll()
    super.tearDown()
  }

  private func connect(replies: [Data]) async throws -> Session {
    let server = try ScriptedServer(replies: replies)
    servers.append(server)
    let port = try await server.start()
    let session = Session(host: "127.0.0.1", port: port)
    try await session.connect()
    return session
  }

  private func assertDecodingError(
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () async throws -> Void
  ) async {
    do {
      try await body()
      XCTFail("expected a ResponseDecodingError", file: file, line: line)
    } catch is ResponseDecodingError {
    } catch {
      XCTFail("expected a ResponseDecodingError, got \(error)", file: file, line: line)
    }
  }
}

/// Answers each framed request with the next canned reply, then closes.
final class ScriptedServer: @unchecked Sendable {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "ScriptedServer")
  private var replies: [Data]
  private var connections = [NWConnection]()
  private var received = [Data]()

  /// Every request body received so far, in order.
  var requests: [Data] {
    queue.sync { received }
  }

  init(replies: [Data]) throws {
    self.replies = replies
    listener = try NWListener(using: .tcp, on: .any)
  }

  func start() async throws -> Int {
    listener.newConnectionHandler = { [weak self] connection in
      guard let self else { return }
      connections.append(connection)
      connection.start(queue: queue)
      serve(connection)
    }
    return try await withCheckedThrowingContinuation { continuation in
      listener.stateUpdateHandler = { [listener] state in
        switch state {
        case .ready:
          listener.stateUpdateHandler = nil
          continuation.resume(returning: Int(listener.port?.rawValue ?? 0))
        case .failed(let error):
          listener.stateUpdateHandler = nil
          continuation.resume(throwing: error)
        default:
          break
        }
      }
      listener.start(queue: queue)
    }
  }

  func stop() {
    queue.sync {
      connections.forEach { $0.cancel() }
      listener.cancel()
    }
  }

  private func serve(_ connection: NWConnection) {
    receive(exactly: 4, on: connection) { [weak self] header in
      guard let self, let header else { return }
      let length = header.reduce(0) { $0 << 8 | Int($1) } & 0x00FF_FFFF
      receive(exactly: length, on: connection) { [weak self] body in
        guard let self, let body else { return }
        received.append(body)
        guard !replies.isEmpty else {
          connection.cancel()
          return
        }
        let reply = replies.removeFirst()
        let isLast = replies.isEmpty
        connection.send(content: reply, completion: .contentProcessed { _ in
          // Closing after the last reply turns any reply the client is
          // still waiting on into a disconnect rather than a hang.
          if isLast { connection.cancel() }
        })
        if !isLast {
          serve(connection)
        }
      }
    }
  }

  private func receive(exactly count: Int, on connection: NWConnection, _ completion: @escaping (Data?) -> Void) {
    guard count > 0 else {
      completion(Data())
      return
    }
    connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
      completion(error == nil ? data : nil)
    }
  }
}
