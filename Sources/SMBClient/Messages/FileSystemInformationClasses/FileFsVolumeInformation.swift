import Foundation

public struct FileFsVolumeInformation {
  public let volumeCreationTime: UInt64
  public let volumeSerialNumber: UInt32
  public let volumeLabelLength: UInt32
  public let supportsObjects: Bool
  public let reserved: UInt8
  public let volumeLabel: String

  public init(data: Data) throws {
    let reader = ByteReader(data)

    volumeCreationTime = try reader.read()
    volumeSerialNumber = try reader.read()
    volumeLabelLength = try reader.read()
    // RUMSKROT-HARDEN: a one-byte BOOLEAN; `read() == 1` inferred Int and consumed eight.
    supportsObjects = try (reader.read() as UInt8) == 1
    reserved = try reader.read()
    let volumeLabelData = try reader.read(count: Int(volumeLabelLength))
    volumeLabel = String(data: volumeLabelData, encoding: .utf16LittleEndian) ?? volumeLabelData.hex
  }
}
