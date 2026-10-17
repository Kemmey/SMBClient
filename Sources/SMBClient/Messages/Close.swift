import Foundation

public enum Close {
  public struct Request: Message.Request {
    public typealias Response = Close.Response
    
    public let header: Header
    public let structureSize: UInt16
    public let flags: UInt16
    public let reserved: UInt32
    public let fileId: Data

    public init(
      headerFlags: Header.Flags = [],
      messageId: UInt64,
      treeId: UInt32,
      sessionId: UInt64,
      fileId: Data
    ) {
      header = Header(
        creditCharge: 1,
        command: .close,
        creditRequest: 256,
        flags: headerFlags,
        messageId: messageId,
        treeId: treeId,
        sessionId: sessionId
      )

      structureSize = 24
      flags = Flags.postQueryAttrib.rawValue
      reserved = 0
      self.fileId = fileId
    }

    public func encoded() -> Data {
      var data = Data()

      data += header.encoded()
      data += structureSize
      data += flags
      data += reserved
      data += fileId

      return data
    }
  }

  public struct Response: Message.Response {
    public let header: Header
    public let structureSize: UInt16
    public let flags: UInt16
    public let reserved: UInt32
    public let creationTime: UInt64
    public let lastAccessTime: UInt64
    public let lastWriteTime: UInt64
    public let changeTime: UInt64
    public let allocationSize: UInt64
    public let endOfFile: UInt64
    public let fileAttributes: UInt32

    public init(data: Data) throws {
      let reader = ByteReader(data)

      header = try reader.read()
      structureSize = try reader.read()
      flags = try reader.read()
      reserved = try reader.read()
      creationTime = try reader.read()
      lastAccessTime = try reader.read()
      lastWriteTime = try reader.read()
      changeTime = try reader.read()
      allocationSize = try reader.read()
      endOfFile = try reader.read()
      fileAttributes = try reader.read()
    }
  }

  public enum Flags: UInt16 {
    case postQueryAttrib = 0x0001
  }
}
