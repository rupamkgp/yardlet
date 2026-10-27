import Foundation

/// RFC 4122 version 5 UUIDs: the same name in the same namespace always gives the same UUID, on any
/// platform and in any launch. They name things; they secure nothing.
///
/// SHA-1 is computed here because the engine does not use CryptoKit (docs/PLATFORM_PORTABILITY.md).
enum NameBasedUUID {
    static func make(namespace: UUID, name: String) -> UUID {
        let namespaceBytes = withUnsafeBytes(of: namespace.uuid) { Array($0) }
        var digest = sha1(namespaceBytes + Array(name.utf8))
        digest[6] = (digest[6] & 0x0F) | 0x50 // version 5
        digest[8] = (digest[8] & 0x3F) | 0x80 // RFC 4122 variant
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]
        ))
    }

    /// The 20-byte SHA-1 digest of `message` (FIPS 180-4).
    static func sha1(_ message: [UInt8]) -> [UInt8] {
        var state: (UInt32, UInt32, UInt32, UInt32, UInt32) = (0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476, 0xC3D2_E1F0)
        var padded = message
        padded.append(0x80)
        while padded.count % 64 != 56 { padded.append(0) }
        let bitCount = UInt64(message.count) &* 8
        for shift in stride(from: 56, through: 0, by: -8) {
            padded.append(UInt8(truncatingIfNeeded: bitCount >> UInt64(shift)))
        }

        var words = [UInt32](repeating: 0, count: 80)
        for chunk in stride(from: 0, to: padded.count, by: 64) {
            for index in 0..<16 {
                let offset = chunk + index * 4
                words[index] = UInt32(padded[offset]) << 24 | UInt32(padded[offset + 1]) << 16
                    | UInt32(padded[offset + 2]) << 8 | UInt32(padded[offset + 3])
            }
            for index in 16..<80 {
                words[index] = rotate(words[index - 3] ^ words[index - 8] ^ words[index - 14] ^ words[index - 16], by: 1)
            }
            var (a, b, c, d, e) = state
            for index in 0..<80 {
                let (f, k): (UInt32, UInt32) = switch index {
                case 0..<20: ((b & c) | (~b & d), 0x5A82_7999)
                case 20..<40: (b ^ c ^ d, 0x6ED9_EBA1)
                case 40..<60: ((b & c) | (b & d) | (c & d), 0x8F1B_BCDC)
                default: (b ^ c ^ d, 0xCA62_C1D6)
                }
                let next = rotate(a, by: 5) &+ f &+ e &+ k &+ words[index]
                e = d
                d = c
                c = rotate(b, by: 30)
                b = a
                a = next
            }
            state = (state.0 &+ a, state.1 &+ b, state.2 &+ c, state.3 &+ d, state.4 &+ e)
        }
        return [state.0, state.1, state.2, state.3, state.4].flatMap { word in
            [UInt8(word >> 24), UInt8(truncatingIfNeeded: word >> 16), UInt8(truncatingIfNeeded: word >> 8),
             UInt8(truncatingIfNeeded: word)]
        }
    }

    private static func rotate(_ value: UInt32, by bits: UInt32) -> UInt32 {
        (value << bits) | (value >> (32 - bits))
    }
}
