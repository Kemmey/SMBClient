import Foundation

typealias SType = NetShareEnumResponse.ShareInfo1.ShareType

struct NetShareEnum {
  let serverName: WStr
  let shareInfo: ShareInfo
  let preferredMaximumLength: UInt32
  let resumeHandle: UInt32

  init(serverName: String) {
    self.serverName = WStr(value: serverName)
    shareInfo = ShareInfo(
      level: 1,
      shareInfo: WStr(value: "")
    )
    preferredMaximumLength = 0xFFFFFFFF
    resumeHandle = 0
  }

  func encoded() -> Data {
    var data = Data()
    data += serverName.encoded()
    data += shareInfo.encoded()
    data += preferredMaximumLength
    data += resumeHandle

    return data
  }
}

struct ShareInfo {
  let level: UInt32
  let entriesRead: UInt32 = 1
  let shareInfo: WStr

  init(level: UInt32, shareInfo: WStr) {
    self.level = level
    self.shareInfo = shareInfo
  }

  func encoded() -> Data {
    var data = Data()
    data += level
    data += entriesRead
    data += shareInfo.encoded()

    return data
  }
}

struct WStr {
  let referentID: UInt32
  let maxCount: UInt32
  let offset: UInt32
  let actualCount: UInt32
  let value: String
  let valueData: Data
  let terminator: UInt16

  init(value: String) {
    referentID = 1
    let valueData = value.encoded()
    maxCount = UInt32(valueData.count / 2) + 1
    offset = 0
    actualCount = maxCount
    self.value = value
    self.valueData = valueData
    terminator = 0
  }

  init(referentID: UInt32, byteReader: ByteReader) throws {
    self.referentID = referentID

    maxCount = try byteReader.read()
    offset = try byteReader.read()
    actualCount = try byteReader.read()

    guard UInt64(actualCount) * 2 <= UInt64(byteReader.availableBytes) else {
      throw ResponseDecodingError.invalidValue(field: "WStr.actualCount", value: UInt64(actualCount))
    }
    let valueCount = Int(actualCount) * 2
    valueData = try byteReader.read(count: valueCount)
    if valueCount % 4 != 0 {
      terminator = try byteReader.read()
    } else {
      terminator = 0
    }

    // RUMSKROT-HARDEN: an empty string has no terminator to drop.
    let valueData = Data(valueData).prefix(max(0, valueData.count - 2))
    value = String(data: valueData, encoding: .utf16LittleEndian) ?? valueData.hex
  }

  func encoded() -> Data {
    var data = Data()
    data += referentID
    data += maxCount

    if valueData.isEmpty {
      data += offset
    } else {
      data += offset
      data += actualCount
      data += valueData
      let padding = Data(count: 4 - data.count % 4)
      data += padding
    }

    return data
  }
}

struct NDRLong {
  let referentID: UInt32
  let value: UInt32

  init(value: UInt32) {
    referentID = 1
    self.value = value
  }

  func encoded() -> Data {
    var data = Data()
    data += referentID
    data += value

    return data
  }
}

struct NetShareEnumResponse {
  let level: UInt32
  let shareCtr: UInt32
  let netShareCtr: NetShareCtr
  let shareInfo1: NetShareInfo1
  let padding: Data
  let totalEntries: UInt32
  let resumeHandle: UInt32
  let status: UInt32

  init(data: Data) throws {
    let reader = ByteReader(data)

    level = try reader.read()
    shareCtr = try reader.read()
    netShareCtr = try NetShareCtr(
      refferentID: reader.read(),
      count: reader.read()
    )
    shareInfo1 = try NetShareInfo1(byteReader: reader)
    padding = try reader.read(count: reader.offset % 4 == 0 ? 0 : 4 - reader.offset % 4)
    totalEntries = try reader.read()
    resumeHandle = try reader.read()
    status = try reader.read()
  }

  struct NetShareCtr {
    let refferentID: UInt32
    let count: UInt32
  }

  struct NetShareInfo1 {
    let refferentID: UInt32
    let count: UInt32
    let shareInfo: [ShareInfo1]

    init(byteReader: ByteReader) throws {
      refferentID = try byteReader.read()
      count = try byteReader.read()
      // RUMSKROT-HARDEN: `count` comes off the wire; each entry is at least
      // 12 bytes, so a count the remaining bytes cannot hold is refused
      // before anything is allocated for it.
      guard UInt64(count) * 12 <= UInt64(byteReader.availableBytes) else {
        throw ResponseDecodingError.invalidValue(field: "NetShareInfo1.count", value: UInt64(count))
      }
      shareInfo = try (0..<count)
        .map { _ in
          let nameRefferentID: UInt32 = try byteReader.read()
          let type: UInt32 = try byteReader.read()
          let commentRefferentID: UInt32 = try byteReader.read()
          return (nameRefferentID, type, commentRefferentID)
        }
        .map { (nameRefferentID, type, commentRefferentID) in
          let name = try WStr(referentID: nameRefferentID, byteReader: byteReader)
          let comment = try WStr(referentID: commentRefferentID, byteReader: byteReader)
          return ShareInfo1(name: name, type: type, comment: comment)
        }
    }
  }

  struct ShareInfo1 {
    let name: WStr
    let type: UInt32
    let comment: WStr

    enum ShareType {
      static let diskTree: UInt32 = 0x00000000
      static let printQueue: UInt32 = 0x00000001
      static let device: UInt32 = 0x00000002
      static let ipc: UInt32 = 0x00000003
      static let clusterFS: UInt32 = 0x02000000
      static let clusterSOFS: UInt32 = 0x04000000
      static let clusterDFS: UInt32 = 0x08000000
      static let special: UInt32 = 0x80000000
      static let temporary: UInt32 = 0x40000000
    }
  }
}
