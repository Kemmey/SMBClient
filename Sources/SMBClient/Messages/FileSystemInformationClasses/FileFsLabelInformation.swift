import Foundation

public struct FileFsLabelInformation {
  public let volumeLabelLength: UInt32
  public let volumeLabel: String

  public init(data: Data) throws {
    let reader = ByteReader(data)

    volumeLabelLength = try reader.read()
    let volumeLabelData = try reader.read(count: Int(volumeLabelLength))
    volumeLabel = String(data: volumeLabelData, encoding: .utf16LittleEndian) ?? volumeLabelData.hex
  }
}
