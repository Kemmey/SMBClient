import Foundation

public struct FileInternalInformation {
  public let indexNumber: UInt64

  public init(data: Data) throws {
    let reader = ByteReader(data)
    indexNumber = try reader.read()
  }
}

extension ByteReader {
  func read() throws -> FileInternalInformation {
    try FileInternalInformation(data: read(count: 8))
  }
}
