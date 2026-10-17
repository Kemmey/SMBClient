import Foundation

public struct FileEaInformation {
  public let eaSize: UInt32

  public init(data: Data) throws {
    let reader = ByteReader(data)
    eaSize = try reader.read()
  }
}

extension ByteReader {
  func read() throws -> FileEaInformation {
    try FileEaInformation(data: read(count: 4))
  }
}
