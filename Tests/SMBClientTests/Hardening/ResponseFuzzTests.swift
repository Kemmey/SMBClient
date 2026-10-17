import XCTest
@testable import SMBClient

// RUMSKROT-TESTS: no reply a server can send may trap the client. Every
// parser is fed its well-formed fixture (must decode), every prefix of it
// (must decode or throw), and seeded random corruptions (must decode or
// throw). A trap fails the run by crashing the test process.
final class ResponseFuzzTests: XCTestCase {
  private struct Parser {
    let name: String
    let fixture: Data
    let decode: (Data) throws -> Void
  }

  private let parsers: [Parser] = [
    Parser(name: "Header", fixture: ResponseFixtures.header(command: .echo)) { _ = try Header(data: $0) },
    Parser(name: "Negotiate", fixture: ResponseFixtures.negotiate()) { _ = try Negotiate.Response(data: $0) },
    Parser(name: "SessionSetup", fixture: ResponseFixtures.sessionSetup()) {
      let response = try SessionSetup.Response(data: $0)
      _ = try NTLM.ChallengeMessage(data: response.buffer)
    },
    Parser(name: "NTLM.ChallengeMessage", fixture: ResponseFixtures.ntlmChallenge()) { _ = try NTLM.ChallengeMessage(data: $0) },
    Parser(name: "TreeConnect", fixture: ResponseFixtures.treeConnect()) { _ = try TreeConnect.Response(data: $0) },
    Parser(name: "TreeDisconnect", fixture: ResponseFixtures.fourByteBody(.treeDisconnect)) { _ = try TreeDisconnect.Response(data: $0) },
    Parser(name: "Logoff", fixture: ResponseFixtures.fourByteBody(.logoff)) { _ = try Logoff.Response(data: $0) },
    Parser(name: "Echo", fixture: ResponseFixtures.fourByteBody(.echo)) { _ = try Echo.Response(data: $0) },
    Parser(name: "Flush", fixture: ResponseFixtures.fourByteBody(.flush)) { _ = try Flush.Response(data: $0) },
    Parser(name: "Create", fixture: ResponseFixtures.create()) { _ = try Create.Response(data: $0) },
    Parser(name: "Close", fixture: ResponseFixtures.close()) { _ = try Close.Response(data: $0) },
    Parser(name: "Read", fixture: ResponseFixtures.read()) { _ = try Read.Response(data: $0) },
    Parser(name: "Write", fixture: ResponseFixtures.write()) { _ = try Write.Response(data: $0) },
    Parser(name: "SetInfo", fixture: ResponseFixtures.setInfo()) { _ = try SetInfo.Response(data: $0) },
    Parser(name: "QueryDirectory", fixture: ResponseFixtures.queryDirectory()) {
      let files = try QueryDirectory.Response(data: $0).files()
      _ = files.map { File(fileInfo: $0) }
    },
    Parser(name: "QueryInfo+FileAllInformation", fixture: ResponseFixtures.queryInfo()) {
      _ = try FileAllInformation(data: QueryInfo.Response(data: $0).buffer)
    },
    Parser(name: "FileFsSizeInformation", fixture: ResponseFixtures.fileFsSizeInformation()) { _ = try FileFsSizeInformation(data: $0) },
    Parser(name: "FileFsVolumeInformation", fixture: ResponseFixtures.fileFsVolumeInformation()) { _ = try FileFsVolumeInformation(data: $0) },
    Parser(name: "FileIdBothDirectoryInformation", fixture: ResponseFixtures.fileIdBothDirectoryInformation()) { _ = try FileIdBothDirectoryInformation(data: $0) },
    Parser(name: "IOCtl+DCERPC+NetShareEnum", fixture: ResponseFixtures.ioctl()) {
      let ioctl = try IOCtl.Response(data: $0)
      let rpc = try DCERPC.Response(data: ioctl.buffer)
      _ = try NetShareEnumResponse(data: rpc.stub)
    },
    Parser(name: "NetShareEnumResponse", fixture: ResponseFixtures.netShareEnumStub()) { _ = try NetShareEnumResponse(data: $0) },
    Parser(name: "ErrorResponse", fixture: ResponseFixtures.errorResponse()) { _ = try ErrorResponse(data: $0) },
    Parser(name: "DirectTCPPacket", fixture: ResponseFixtures.frame(ResponseFixtures.close())) { _ = try DirectTCPPacket(response: $0) },
  ]

  func testEveryFixtureDecodes() throws {
    for parser in parsers {
      XCTAssertNoThrow(try parser.decode(parser.fixture), parser.name)
    }
  }

  func testFixturesDecodeTheValuesTheyCarry() throws {
    let files = try QueryDirectory.Response(data: ResponseFixtures.queryDirectory()).files()
    XCTAssertEqual(files.map(\.fileName), [".", "Report.pdf", "Ærø ø.txt"])

    let read = try Read.Response(data: ResponseFixtures.read())
    XCTAssertEqual(read.buffer, Data("hello, world".utf8))

    let rpc = try DCERPC.Response(data: IOCtl.Response(data: ResponseFixtures.ioctl()).buffer)
    let shares = try NetShareEnumResponse(data: rpc.stub).shareInfo1.shareInfo
    XCTAssertEqual(shares.map(\.name.value), ["Media", "IPC$", "Backups"])
    XCTAssertEqual(shares.map(\.comment.value), ["Films and music", "IPC Service", ""])

    let info = try FileAllInformation(data: ResponseFixtures.fileAllInformation())
    XCTAssertEqual(info.nameInformation.fileName, #"\dir\file.txt"#)
    XCTAssertEqual(info.standardInformation.endOfFile, 1234)
  }

  /// Decoding from a slice whose indices do not start at zero must read
  /// the same values: offsets in a reply are relative to the reply.
  func testSlicesDecodeLikeTheirBytes() throws {
    let fixture = ResponseFixtures.read()
    let slice = (Data([0xEE, 0xEE, 0xEE]) + fixture).dropFirst(3)
    XCTAssertNotEqual(slice.startIndex, 0)
    XCTAssertEqual(try Read.Response(data: slice).buffer, try Read.Response(data: fixture).buffer)

    let directory = (Data([0xEE]) + ResponseFixtures.queryDirectory()).dropFirst()
    XCTAssertEqual(try QueryDirectory.Response(data: directory).files().count, 3)
  }

  func testEveryTruncationThrowsInsteadOfTrapping() {
    for parser in parsers {
      var threw = 0
      for length in 0..<parser.fixture.count {
        do {
          try parser.decode(parser.fixture.prefix(length))
        } catch is ResponseDecodingError {
          threw += 1
        } catch {
          XCTFail("\(parser.name) truncated to \(length) threw \(error), not ResponseDecodingError")
        }
      }
      // Some parsers ignore trailing fields; most prefixes must still fail.
      XCTAssertGreaterThan(threw, 0, parser.name)
    }
  }

  func testRandomCorruptionNeverTraps() {
    var rng = SplitMix64(seed: 0x5EED_189)
    for parser in parsers {
      for _ in 0..<2_000 {
        let mutated = mutate(parser.fixture, using: &rng)
        do {
          try parser.decode(mutated)
        } catch {
          // Throwing is the correct outcome for most mutations.
        }
      }
    }
  }

  /// Hand-picked hostile values the random walk is unlikely to hit.
  func testHostileLengthsAndCountsThrow() {
    // A share count no reply could hold.
    var stub = ResponseFixtures.netShareEnumStub()
    stub.replaceSubrange(12..<16, with: Data(from: UInt32.max))
    stub.replaceSubrange(20..<24, with: Data(from: UInt32.max))
    XCTAssertThrowsError(try NetShareEnumResponse(data: stub))

    // A Read whose DataLength runs off the end.
    var read = ResponseFixtures.read()
    read.replaceSubrange(68..<72, with: Data(from: UInt32.max))
    XCTAssertThrowsError(try Read.Response(data: read))

    // A directory entry whose NextEntryOffset points past the buffer.
    var directory = ResponseFixtures.queryDirectory()
    directory.replaceSubrange(72..<76, with: Data(from: UInt32(0x7FFF_FFF0)))
    XCTAssertThrowsError(try QueryDirectory.Response(data: directory).files())

    // An RPC fragment length shorter than its own header.
    var rpc = ResponseFixtures.dcerpcResponse()
    rpc.replaceSubrange(8..<10, with: Data(from: UInt16(4)))
    XCTAssertThrowsError(try DCERPC.Response(data: rpc))

    // An AV pair id NTLM does not define.
    var pair = Data()
    pair += UInt16(0x7777)
    pair += UInt16(0)
    XCTAssertThrowsError(try AVPair(data: pair))
  }

  private func mutate(_ data: Data, using rng: inout SplitMix64) -> Data {
    var bytes = [UInt8](data)
    switch rng.next() % 5 {
    case 0:
      // Flip a handful of bytes anywhere.
      for _ in 0..<(1 + Int(rng.next() % 8)) where !bytes.isEmpty {
        bytes[Int(rng.next() % UInt64(bytes.count))] = UInt8(truncatingIfNeeded: rng.next())
      }
    case 1:
      // Saturate a 16/32-bit field: the lengths and offsets live here.
      if bytes.count >= 4 {
        let at = Int(rng.next() % UInt64(bytes.count - 3))
        let fill: UInt8 = rng.next() % 2 == 0 ? 0xFF : 0x00
        for i in at..<(at + (rng.next() % 2 == 0 ? 2 : 4)) { bytes[i] = fill }
      }
    case 2:
      // Truncate and corrupt.
      bytes = Array(bytes.prefix(Int(rng.next() % UInt64(bytes.count + 1))))
      if !bytes.isEmpty { bytes[Int(rng.next() % UInt64(bytes.count))] ^= 0xFF }
    case 3:
      // Append garbage.
      bytes += (0..<Int(rng.next() % 64)).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
    default:
      // Entirely random bytes of a similar size.
      bytes = (0..<Int(rng.next() % UInt64(bytes.count * 2 + 1))).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
    }
    return Data(bytes)
  }
}

/// A seedable generator, so a failing corruption can be replayed.
struct SplitMix64: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
