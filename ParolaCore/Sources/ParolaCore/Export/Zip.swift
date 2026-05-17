import Foundation

/// Minimal ZIP writer for stored (uncompressed) entries. Used by `DocxExporter`.
public enum Zip {
    public struct File: Sendable {
        public let name: String
        public let data: Data

        public init(name: String, data: Data) {
            self.name = name
            self.data = data
        }
    }

    public static func archive(_ files: [File]) -> Data {
        var bytes = Data()
        var centralDirectory = Data()

        for file in files {
            let nameBytes = Data(file.name.utf8)
            let crc = crc32(file.data)
            let dataSize = UInt32(file.data.count)
            let offset = UInt32(bytes.count)

            bytes.append(uint32: 0x04034b50)
            bytes.append(uint16: 20)
            bytes.append(uint16: 0)
            bytes.append(uint16: 0)
            bytes.append(uint16: 0)
            bytes.append(uint16: 0x21)
            bytes.append(uint32: crc)
            bytes.append(uint32: dataSize)
            bytes.append(uint32: dataSize)
            bytes.append(uint16: UInt16(nameBytes.count))
            bytes.append(uint16: 0)
            bytes.append(nameBytes)
            bytes.append(file.data)

            centralDirectory.append(uint32: 0x02014b50)
            centralDirectory.append(uint16: 20)
            centralDirectory.append(uint16: 20)
            centralDirectory.append(uint16: 0)
            centralDirectory.append(uint16: 0)
            centralDirectory.append(uint16: 0)
            centralDirectory.append(uint16: 0x21)
            centralDirectory.append(uint32: crc)
            centralDirectory.append(uint32: dataSize)
            centralDirectory.append(uint32: dataSize)
            centralDirectory.append(uint16: UInt16(nameBytes.count))
            centralDirectory.append(uint16: 0)
            centralDirectory.append(uint16: 0)
            centralDirectory.append(uint16: 0)
            centralDirectory.append(uint16: 0)
            centralDirectory.append(uint32: 0)
            centralDirectory.append(uint32: offset)
            centralDirectory.append(nameBytes)
        }

        let cdOffset = UInt32(bytes.count)
        let cdSize = UInt32(centralDirectory.count)
        bytes.append(centralDirectory)

        bytes.append(uint32: 0x06054b50)
        bytes.append(uint16: 0)
        bytes.append(uint16: 0)
        bytes.append(uint16: UInt16(files.count))
        bytes.append(uint16: UInt16(files.count))
        bytes.append(uint32: cdSize)
        bytes.append(uint32: cdOffset)
        bytes.append(uint16: 0)

        return bytes
    }

    public static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                if crc & 1 != 0 {
                    crc = (crc >> 1) ^ 0xEDB88320
                } else {
                    crc = crc >> 1
                }
            }
        }
        return crc ^ 0xFFFFFFFF
    }
}

private extension Data {
    mutating func append(uint16 value: UInt16) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    mutating func append(uint32 value: UInt32) {
        append(contentsOf: [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF)
        ])
    }
}
