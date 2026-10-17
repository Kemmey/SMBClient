import Foundation

public struct FilePositionInformation {
  public let currentByteOffset: UInt64

  public init(data: Data) throws {
    let reader = ByteReader(data)
    currentByteOffset = try reader.read()
  }
}

extension ByteReader {
  func read() throws -> FilePositionInformation {
    return try FilePositionInformation(data: read(count: 8))
  }
}
