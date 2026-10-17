import Foundation

public struct FileStandardInformation {
  public let allocationSize: UInt64
  public let endOfFile: UInt64
  public let numberOfLinks: UInt32
  public let deletePending: Bool
  public let directory: Bool
  public let reserved: UInt16

  public init(data: Data) throws {
    let reader = ByteReader(data)

    allocationSize = try reader.read()
    endOfFile = try reader.read()
    numberOfLinks = try reader.read()
    deletePending = try reader.read()
    directory = try reader.read()
    reserved = try reader.read()
  }
}

extension ByteReader {
  func read() throws -> FileStandardInformation {
    try FileStandardInformation(data: read(count: 24))
  }
}
