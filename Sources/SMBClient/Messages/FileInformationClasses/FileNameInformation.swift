import Foundation

public struct FileNameInformation {
  public let fileNameLength: UInt32
  public let fileName: String

  public init(data: Data) throws {
    let reader = ByteReader(data)

    fileNameLength = try reader.read()

    let fileNameData = try reader.read(count: Int(fileNameLength))
    fileName = String(data: fileNameData, encoding: .utf16LittleEndian) ?? fileNameData.hex
  }

  fileprivate init(fileNameLength: UInt32, fileName: String) {
    self.fileNameLength = fileNameLength
    self.fileName = fileName
  }
}

extension ByteReader {
  func read() throws -> FileNameInformation {
    let fileNameLength: UInt32 = try read()
    let fileNameData = try read(count: Int(fileNameLength))
    let fileName = String(data: fileNameData, encoding: .utf16LittleEndian) ?? fileNameData.hex
    return FileNameInformation(fileNameLength: fileNameLength, fileName: fileName)
  }
}
