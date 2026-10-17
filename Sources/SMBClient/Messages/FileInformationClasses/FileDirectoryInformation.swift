import Foundation

public struct FileDirectoryInformation {
  public let nextEntryOffset: UInt32
  public let fileIndex: UInt32
  public let creationTime: UInt64
  public let lastAccessTime: UInt64
  public let lastWriteTime: UInt64
  public let changeTime: UInt64
  public let endOfFile: UInt64
  public let allocationSize: UInt64
  public let fileAttributes: FileAttributes
  public let fileNameLength: UInt32
  public let fileName: String

  public init(data: Data) throws {
    let reader = ByteReader(data)

    nextEntryOffset = try reader.read()
    fileIndex = try reader.read()
    creationTime = try reader.read()
    lastAccessTime = try reader.read()
    lastWriteTime = try reader.read()
    changeTime = try reader.read()
    endOfFile = try reader.read()
    allocationSize = try reader.read()
    fileAttributes = try FileAttributes(rawValue: reader.read())
    fileNameLength = try reader.read()

    let fileNameData = try reader.read(count: Int(fileNameLength))
    fileName = String(data: fileNameData, encoding: .utf16LittleEndian) ?? fileNameData.hex
  }
}
