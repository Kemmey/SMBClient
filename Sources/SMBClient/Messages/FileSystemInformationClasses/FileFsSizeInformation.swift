import Foundation

public struct FileFsSizeInformation {
  public let totalAllocationUnits: UInt64
  public let availableAllocationUnits: UInt64
  public let sectorsPerAllocationUnit: UInt32
  public let bytesPerSector: UInt32

  public init(data: Data) throws {
    let reader = ByteReader(data)

    totalAllocationUnits = try reader.read()
    availableAllocationUnits = try reader.read()
    sectorsPerAllocationUnit = try reader.read()
    bytesPerSector = try reader.read()
  }
}
