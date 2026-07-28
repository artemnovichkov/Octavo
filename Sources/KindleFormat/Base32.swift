import Foundation

/// KF8's base-32 alphabet — digits then `A`…`V`, no padding character. It shows up in three
/// places in a KF8 file and nowhere else: the `aid` attribute the chunk index selects elements
/// by, and the two halves of a `kindle:pos:fid:000E:off:000000001K` link.
///
/// Values were read off a calibre-produced AZW3 (`aid="9"`, `aid="A"`, `aid="10"`, `aid="UGI0"`),
/// which is what pins the alphabet down: it is *not* RFC 4648's `A`…`Z2`…`7`.
enum Base32 {
    static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUV")

    /// `width` zero-pads on the left; `nil` leaves the number as short as it comes out.
    static func encode(_ value: Int, width: Int? = nil) -> String {
        precondition(value >= 0, "base32 encodes non-negative values only")

        var digits = [Character]()
        var remainder = value
        repeat {
            digits.append(alphabet[remainder & 0x1F])
            remainder >>= 5
        } while remainder > 0

        if let width, digits.count < width {
            digits.append(contentsOf: repeatElement(alphabet[0], count: width - digits.count))
        }
        return String(digits.reversed())
    }

    static func decode(_ text: String) -> Int? {
        var value = 0
        for character in text.uppercased() {
            guard let digit = alphabet.firstIndex(of: character) else { return nil }
            value = value << 5 | digit
        }
        return value
    }
}
