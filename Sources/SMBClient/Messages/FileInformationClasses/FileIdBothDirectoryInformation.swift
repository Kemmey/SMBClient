import Foundation

public struct FileIdBothDirectoryInformation {
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
  public let eaSize: UInt32
  public let shortNameLength: UInt8
  public let reserved: UInt8
  public let shortName: String
  public let reserved2: UInt16
  public let fileId: Data
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
    eaSize = try reader.read()
    shortNameLength = try reader.read()
    reserved = try reader.read()

    let shortNameData = try reader.read(count: 24)
    shortName = String(data: shortNameData, encoding: .utf16LittleEndian) ?? shortNameData.hex

    reserved2 = try reader.read()
    fileId = try reader.read(count: 8)

    let fileNameData = try reader.read(count: Int(fileNameLength))
    fileName = String(data: fileNameData, encoding: .utf16LittleEndian) ?? fileNameData.hex
  }
}

extension FileIdBothDirectoryInformation: CustomDebugStringConvertible {
  public var debugDescription: String {
    """
    FileIdBothDirectoryInfo:
      Next Offset: \(nextEntryOffset)
      File Index: \(fileIndex)
      Create: \(FileTime(creationTime))
      Last Access: \(FileTime(lastAccessTime))
      Last Write: \(FileTime(lastWriteTime))
      Last Change: \(FileTime(changeTime))
      End Of File: \(endOfFile)
      Allocation Size: \(allocationSize)
      File Attributes: \(fileAttributes)
      File Name: \(fileName)
    """
  }
}
