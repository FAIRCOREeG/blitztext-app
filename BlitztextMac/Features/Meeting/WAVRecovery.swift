import Foundation

/// Makes a WAV readable whose header still says zero bytes. That is what a recorder leaves
/// when the app ends without stopping it (crash, force quit, power loss): the samples are on
/// disk, only the RIFF and data sizes are missing.
enum WAVRecovery {
    /// Patches the size fields in place. Returns true when something was fixed.
    @discardableResult
    static func repairIfNeeded(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forUpdating: url) else { return false }
        defer { try? handle.close() }
        guard let length = try? handle.seekToEnd(), length > 12,
              (try? handle.seek(toOffset: 0)) != nil,
              let header = try? handle.read(upToCount: Int(min(length, 65_536))),
              let patches = sizePatches(header: header, fileLength: Int(length)) else { return false }
        for patch in patches {
            var value = patch.value.littleEndian
            do {
                try handle.seek(toOffset: UInt64(patch.offset))
                try handle.write(contentsOf: Data(bytes: &value, count: 4))
            } catch {
                return false
            }
        }
        return true
    }

    /// The size fields to rewrite (byte offset and value), nil when the file is no WAV or its
    /// sizes already match the file length.
    static func sizePatches(header: Data, fileLength: Int) -> [(offset: Int, value: UInt32)]? {
        let bytes = [UInt8](header)
        guard bytes.count >= 12, ascii(bytes, 0) == "RIFF", ascii(bytes, 8) == "WAVE" else { return nil }

        var offset = 12
        while offset + 8 <= bytes.count {
            let size = Int(uint32(bytes, offset + 4))
            if ascii(bytes, offset) == "data" {
                let dataBytes = fileLength - (offset + 8)
                let riffBytes = fileLength - 8
                guard dataBytes >= 0 else { return nil }
                if size == dataBytes, Int(uint32(bytes, 4)) == riffBytes { return nil }
                return [(4, UInt32(riffBytes)), (offset + 4, UInt32(dataBytes))]
            }
            // Chunks before the data (format, padding) carry correct sizes; they are word-aligned.
            offset += 8 + size + size % 2
        }
        return nil
    }

    private static func ascii(_ bytes: [UInt8], _ offset: Int) -> String? {
        String(bytes: bytes[offset..<offset + 4], encoding: .ascii)
    }

    private static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}
