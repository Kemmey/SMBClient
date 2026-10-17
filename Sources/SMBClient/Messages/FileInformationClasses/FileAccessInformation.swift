import Foundation

public struct FileAccessInformation {
  public let accessFlags: AccessMask

  public init(data: Data) throws {
    let reader = ByteReader(data)
    accessFlags = try AccessMask(rawValue: reader.read())
  }
}

extension ByteReader {
  func read() throws -> FileAccessInformation {
    try FileAccessInformation(data: read(count: 4))
  }
}
