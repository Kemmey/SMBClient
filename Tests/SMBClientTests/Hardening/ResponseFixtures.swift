import Foundation
@testable import SMBClient

// RUMSKROT-TESTS: well-formed replies for every response parser, built
// from the field layouts in MS-SMB2 / MS-NLMP / MS-SRVS. Each one decodes
// cleanly; the fuzz tests then truncate and corrupt it.
enum ResponseFixtures {
  static func header(
    command: Header.Command,
    status: UInt32 = 0,
    nextCommand: UInt32 = 0,
    messageId: UInt64 = 1
  ) -> Data {
    var data = Data()
    data += UInt32(0x424D53FE)  // ProtocolId
    data += UInt16(64)          // StructureSize
    data += UInt16(1)           // CreditCharge
    data += status
    data += command.rawValue
    data += UInt16(1)           // CreditResponse
    data += UInt32(0x00000001)  // Flags: SERVER_TO_REDIR
    data += nextCommand
    data += messageId
    data += UInt32(0)           // Reserved
    data += UInt32(1)           // TreeId
    data += UInt64(0x1122334455667788)
    data += Data(count: 16)     // Signature
    return data
  }

  static func utf16(_ string: String) -> Data {
    string.data(using: .utf16LittleEndian)!
  }

  // MARK: - SMB2 responses

  static func negotiate(maxReadSize: UInt32 = 65536, securityBuffer: Data = Data(repeating: 0x60, count: 32)) -> Data {
    var data = header(command: .negotiate)
    data += UInt16(65)
    data += UInt16(0x0001)      // SecurityMode
    data += UInt16(0x0210)      // DialectRevision
    data += UInt16(0)           // NegotiateContextCount
    data += Data(repeating: 0xAB, count: 16)
    data += UInt32(0)           // Capabilities
    data += UInt32(65536)       // MaxTransactSize
    data += maxReadSize
    data += UInt32(65536)       // MaxWriteSize
    data += UInt64(0)
    data += UInt64(0)
    data += UInt16(128)         // SecurityBufferOffset
    data += UInt16(securityBuffer.count)
    data += UInt32(0)
    data += securityBuffer
    return data
  }

  static func ntlmChallenge() -> Data {
    let targetName = utf16("SERVER")
    var targetInfo = Data()
    targetInfo += UInt16(0x0001)
    targetInfo += UInt16(targetName.count)
    targetInfo += targetName
    targetInfo += UInt16(0x0000)
    targetInfo += UInt16(0)

    var data = Data()
    data += UInt64(0x005053534D4C544E)
    data += UInt32(2)
    data += UInt16(targetName.count)
    data += UInt16(targetName.count)
    data += UInt32(56)
    data += UInt32(0xE2898215)
    data += UInt64(0x0123456789ABCDEF)
    data += UInt64(0)
    data += UInt16(targetInfo.count)
    data += UInt16(targetInfo.count)
    data += UInt32(56 + UInt32(targetName.count))
    data += UInt64(0x0F00000000020A00)
    data += targetName
    data += targetInfo
    return data
  }

  static func sessionSetup() -> Data {
    let blob = ntlmChallenge()
    var data = header(command: .sessionSetup, status: 0xC0000016)
    data += UInt16(9)
    data += UInt16(0)
    data += UInt16(72)
    data += UInt16(blob.count)
    data += blob
    return data
  }

  static func treeConnect() -> Data {
    var data = header(command: .treeConnect)
    data += UInt16(16)
    data += UInt8(1)
    data += UInt8(0)
    data += UInt32(0)
    data += UInt32(0)
    data += UInt32(0x001F01FF)
    return data
  }

  static func create(contexts: Data = Data(repeating: 0x11, count: 24)) -> Data {
    var data = header(command: .create)
    data += UInt16(89)
    data += UInt8(0)
    data += UInt8(0)
    data += UInt32(1)
    data += UInt64(132_000_000_000_000_000)
    data += UInt64(132_000_000_000_000_000)
    data += UInt64(132_000_000_000_000_000)
    data += UInt64(132_000_000_000_000_000)
    data += UInt64(4096)
    data += UInt64(1234)
    data += UInt32(0x20)
    data += UInt32(0)
    data += Data(repeating: 0x42, count: 16)
    data += UInt32(contexts.isEmpty ? 0 : 152)
    data += UInt32(contexts.count)
    data += contexts
    return data
  }

  static func close(nextCommand: UInt32 = 0) -> Data {
    var data = header(command: .close, nextCommand: nextCommand)
    data += UInt16(60)
    data += UInt16(1)
    data += UInt32(0)
    for _ in 0..<6 { data += UInt64(42) }
    data += UInt32(0x20)
    return data
  }

  static func read(payload: Data = Data("hello, world".utf8)) -> Data {
    var data = header(command: .read)
    data += UInt16(17)
    data += UInt8(80)
    data += UInt8(0)
    data += UInt32(payload.count)
    data += UInt32(0)
    data += UInt32(0)
    data += payload
    return data
  }

  static func write() -> Data {
    var data = header(command: .write)
    data += UInt16(17)
    data += UInt16(0)
    data += UInt32(512)
    data += UInt32(0)
    data += UInt16(0)
    data += UInt16(0)
    return data
  }

  static func fileDirectoryInformation(name: String, last: Bool) -> Data {
    let nameData = utf16(name)
    var entry = Data()
    entry += UInt32(0)  // NextEntryOffset, patched below
    entry += UInt32(0)
    for _ in 0..<4 { entry += UInt64(132_000_000_000_000_000) }
    entry += UInt64(99)
    entry += UInt64(4096)
    entry += UInt32(0x20)
    entry += UInt32(nameData.count)
    entry += nameData
    let padded = (entry.count + 7) / 8 * 8
    entry += Data(count: padded - entry.count)
    if !last {
      entry.replaceSubrange(0..<4, with: Data(from: UInt32(entry.count)))
    }
    return entry
  }

  static func queryDirectory() -> Data {
    let buffer = fileDirectoryInformation(name: ".", last: false)
      + fileDirectoryInformation(name: "Report.pdf", last: false)
      + fileDirectoryInformation(name: "Ærø ø.txt", last: true)
    var data = header(command: .queryDirectory)
    data += UInt16(9)
    data += UInt16(72)
    data += UInt32(buffer.count)
    data += buffer
    return data
  }

  static func fileAllInformation() -> Data {
    let name = utf16(#"\dir\file.txt"#)
    var data = Data()
    for _ in 0..<4 { data += UInt64(132_000_000_000_000_000) }  // Basic
    data += UInt32(0x20)
    data += UInt32(0)
    data += UInt64(4096)        // Standard
    data += UInt64(1234)
    data += UInt32(1)
    data += UInt8(0)
    data += UInt8(0)
    data += UInt16(0)
    data += UInt64(7)           // Internal
    data += UInt32(0)           // Ea
    data += UInt32(0x001F01FF)  // Access
    data += UInt64(0)           // Position
    data += UInt32(0)           // Mode
    data += UInt32(0)           // Alignment
    data += UInt32(name.count)  // Name
    data += name
    return data
  }

  static func fileFsSizeInformation() -> Data {
    var data = Data()
    data += UInt64(1_000_000)
    data += UInt64(500_000)
    data += UInt32(8)
    data += UInt32(512)
    return data
  }

  static func fileFsVolumeInformation() -> Data {
    let label = utf16("Volume")
    var data = Data()
    data += UInt64(132_000_000_000_000_000)
    data += UInt32(0xDEADBEEF)
    data += UInt32(label.count)
    data += UInt8(0)
    data += UInt8(0)
    data += label
    return data
  }

  static func fileIdBothDirectoryInformation() -> Data {
    let name = utf16("photo.jpg")
    var data = Data()
    data += UInt32(0)
    data += UInt32(0)
    for _ in 0..<4 { data += UInt64(132_000_000_000_000_000) }
    data += UInt64(10)
    data += UInt64(4096)
    data += UInt32(0x20)
    data += UInt32(name.count)
    data += UInt32(0)
    data += UInt8(0)
    data += UInt8(0)
    data += Data(count: 24)
    data += UInt16(0)
    data += Data(repeating: 0x01, count: 8)
    data += name
    return data
  }

  static func queryInfo(buffer: Data = fileAllInformation()) -> Data {
    var data = header(command: .queryInfo)
    data += UInt16(9)
    data += UInt16(72)
    data += UInt32(buffer.count)
    data += buffer
    return data
  }

  static func wstr(_ string: String) -> Data {
    let value = utf16(string) + Data(count: 2)
    var data = Data()
    data += UInt32(value.count / 2)
    data += UInt32(0)
    data += UInt32(value.count / 2)
    data += value
    if data.count % 4 != 0 { data += Data(count: 4 - data.count % 4) }
    return data
  }

  static func netShareEnumStub(_ shares: [(String, UInt32, String)] = [
    ("Media", 0, "Films and music"),
    ("IPC$", 0x80000003, "IPC Service"),
    ("Backups", 0, ""),
  ]) -> Data {
    var data = Data()
    data += UInt32(1)                   // level
    data += UInt32(1)                   // switch
    data += UInt32(0x00020000)          // container referent
    data += UInt32(shares.count)
    data += UInt32(0x00020004)          // array referent
    data += UInt32(shares.count)
    for (index, share) in shares.enumerated() {
      data += UInt32(0x00020008 + UInt32(index) * 8)
      data += share.1
      data += UInt32(0x0002000C + UInt32(index) * 8)
    }
    for share in shares {
      data += wstr(share.0)
      data += wstr(share.2)
    }
    data += UInt32(shares.count)        // totalEntries
    data += UInt32(0)                   // resume handle referent
    data += UInt32(0)                   // WERROR
    return data
  }

  static func dcerpcResponse(stub: Data = netShareEnumStub(), packetType: UInt8 = 2, flags: UInt8 = 0x03) -> Data {
    var data = Data()
    data += UInt8(5)
    data += UInt8(0)
    data += packetType
    data += flags
    data += UInt32(0x10)
    data += UInt16(24 + stub.count)
    data += UInt16(0)
    data += UInt32(1)
    data += UInt32(stub.count)
    data += UInt16(0)
    data += UInt8(0)
    data += UInt8(0)
    data += stub
    return data
  }

  static func ioctl(output: Data = dcerpcResponse()) -> Data {
    var data = header(command: .ioctl)
    data += UInt16(49)
    data += UInt16(0)
    data += UInt32(0x0011C017)
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

  static func errorResponse(status: UInt32 = 0xC0000034) -> Data {
    var data = header(command: .create, status: status)
    data += UInt16(9)
    data += UInt8(0)
    data += UInt8(0)
    data += UInt32(0)
    data += UInt8(0)
    return data
  }

  static func fourByteBody(_ command: Header.Command) -> Data {
    var data = header(command: command)
    data += UInt16(4)
    data += UInt16(0)
    return data
  }

  static func setInfo() -> Data {
    var data = header(command: .setInfo)
    data += UInt16(2)
    return data
  }

  /// A compound CREATE + CLOSE reply, as `fileStat` expects.
  static func compoundCreateClose() -> Data {
    let first = create(contexts: Data())
    let padded = first + Data(count: (8 - first.count % 8) % 8)
    var chained = padded
    chained.replaceSubrange(20..<24, with: Data(from: UInt32(padded.count)))
    return chained + close()
  }

  /// A Direct TCP frame around an SMB2 message.
  static func frame(_ message: Data) -> Data {
    var data = Data()
    data += UInt32(message.count).bigEndian
    return data + message
  }
}
