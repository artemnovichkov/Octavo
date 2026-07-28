import Foundation

/// PalmDOC's LZ77 variant — the compression MOBI and KF8 text records use (`compression = 2`
/// in the PalmDOC header). Records are compressed independently: a back-reference never
/// reaches outside the record it lives in, which is what lets the Kindle decode any record
/// without replaying the ones before it.
///
/// The encoding is four cases, distinguished by the first byte:
///
/// | Byte | Meaning |
/// |---|---|
/// | `0x00`, `0x09…0x7F` | the literal byte itself |
/// | `0x01…0x08` | that many literal bytes follow |
/// | `0x80…0xBF` | with the next byte, a back-reference: 11-bit distance, 3-bit length − 3 |
/// | `0xC0…0xFF` | a space followed by `byte ^ 0x80` |
enum PalmDoc {
    static let windowSize = 2047
    static let minMatch = 3
    static let maxMatch = 10
    /// How far down a hash chain to look before settling for the best match so far. The
    /// window is only 2047 bytes and matches cap at 10, so the tail of a long chain almost
    /// never improves on its head.
    private static let maxChainWalk = 64

    // MARK: - Decompression

    static func decompress(_ input: Data) -> Data {
        let bytes = [UInt8](input)
        var output = [UInt8]()
        output.reserveCapacity(bytes.count * 2)

        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            index += 1

            switch byte {
            case 0x00, 0x09...0x7F:
                output.append(byte)

            case 0x01...0x08:
                let end = min(index + Int(byte), bytes.count)
                output.append(contentsOf: bytes[index..<end])
                index = end

            case 0x80...0xBF:
                guard index < bytes.count else { break }
                let pair = Int(byte) << 8 | Int(bytes[index])
                index += 1
                let distance = (pair >> 3) & 0x07FF
                let length = (pair & 0x07) + 3
                guard distance > 0, distance <= output.count else { break }
                // Overlapping copies are legal and common — read one byte at a time.
                var source = output.count - distance
                for _ in 0..<length {
                    output.append(output[source])
                    source += 1
                }

            default:
                output.append(0x20)
                output.append(byte ^ 0x80)
            }
        }

        return Data(output)
    }

    // MARK: - Compression

    static func compress(_ input: Data) -> Data {
        let bytes = [UInt8](input)
        guard !bytes.isEmpty else { return Data() }

        var output = [UInt8]()
        output.reserveCapacity(bytes.count)

        /// Literals that cannot be emitted on their own — `0x01…0x08` and `0x80…0xFF` would be
        /// read as a length prefix or a back-reference — are gathered into a run of up to
        /// eight and emitted behind a count byte.
        var pending = [UInt8]()

        func isSelfDescribing(_ byte: UInt8) -> Bool { byte == 0 || (byte >= 0x09 && byte < 0x80) }

        func flushPending() {
            var index = 0
            while index < pending.count {
                if isSelfDescribing(pending[index]) {
                    output.append(pending[index])
                    index += 1
                } else {
                    let end = min(index + 8, pending.count)
                    var run = index
                    while run < end, !isSelfDescribing(pending[run]) { run += 1 }
                    output.append(UInt8(run - index))
                    output.append(contentsOf: pending[index..<run])
                    index = run
                }
            }
            pending.removeAll(keepingCapacity: true)
        }

        // Hash chains over three-byte keys: `head` holds the most recent position for a key,
        // `chain` links each position back to the previous one with the same key. Scanning
        // the whole window at every position would be quadratic.
        var head = [Int](repeating: -1, count: 1 << 16)
        var chain = [Int](repeating: -1, count: bytes.count)

        func key(at position: Int) -> Int {
            let a = Int(bytes[position]), b = Int(bytes[position + 1]), c = Int(bytes[position + 2])
            return ((a << 10) ^ (b << 5) ^ c) & 0xFFFF
        }

        var position = 0
        while position < bytes.count {
            var bestLength = 0
            var bestDistance = 0

            if position + minMatch <= bytes.count {
                let limit = min(maxMatch, bytes.count - position)
                let earliest = max(0, position - windowSize)
                var candidate = head[key(at: position)]
                var walked = 0

                while candidate >= earliest, walked < maxChainWalk {
                    walked += 1
                    // The match must end at or before `position`: PalmDOC back-references never
                    // overlap the bytes they are being written in place of.
                    var length = 0
                    while length < limit,
                          candidate + length < position,
                          bytes[candidate + length] == bytes[position + length] {
                        length += 1
                    }
                    if length > bestLength {
                        bestLength = length
                        bestDistance = position - candidate
                        if bestLength == limit { break }
                    }
                    candidate = chain[candidate]
                }
            }

            // Register this position (and every position a match skips over) before advancing.
            func register(_ start: Int, _ count: Int) {
                for offset in 0..<count where start + offset + minMatch <= bytes.count {
                    let slot = key(at: start + offset)
                    chain[start + offset] = head[slot]
                    head[slot] = start + offset
                }
            }

            if bestLength >= minMatch {
                flushPending()
                let pair = 0x8000 | (bestDistance << 3) | (bestLength - minMatch)
                output.append(UInt8(pair >> 8 & 0xFF))
                output.append(UInt8(pair & 0xFF))
                register(position, bestLength)
                position += bestLength
                continue
            }

            register(position, 1)

            // A space followed by a printable ASCII letter packs into one byte.
            if bytes[position] == 0x20, position + 1 < bytes.count,
               bytes[position + 1] >= 0x40, bytes[position + 1] < 0x80 {
                flushPending()
                output.append(bytes[position + 1] ^ 0x80)
                register(position + 1, 1)
                position += 2
                continue
            }

            pending.append(bytes[position])
            position += 1
        }

        flushPending()
        return Data(output)
    }
}
