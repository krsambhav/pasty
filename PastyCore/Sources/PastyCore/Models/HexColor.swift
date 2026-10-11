import Foundation

/// A CSS-style hex color (`#RGB`, `#RRGGBB`, `#RRGGBBAA`), recognized so it can be previewed as a swatch.
public struct HexColor: Sendable, Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init?(_ text: String) {
        var hex = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        guard [3, 4, 6, 8].contains(hex.count), hex.allSatisfy(\.isHexDigit), hex.allSatisfy(\.isASCII) else { return nil }
        if hex.count <= 4 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard let value = UInt64(hex, radix: 16) else { return nil }
        let hasAlpha = hex.count == 8
        let shift: UInt64 = hasAlpha ? 8 : 0
        red = Double((value >> (16 + shift)) & 0xFF) / 255
        green = Double((value >> (8 + shift)) & 0xFF) / 255
        blue = Double((value >> shift) & 0xFF) / 255
        alpha = hasAlpha ? Double(value & 0xFF) / 255 : 1
    }

    /// `rgb(91, 91, 214)` or `rgba(…, 0.5)`.
    public var cssDescription: String {
        let r = Int((red * 255).rounded()), g = Int((green * 255).rounded()), b = Int((blue * 255).rounded())
        if alpha < 1 {
            return "rgba(\(r), \(g), \(b), \(String(format: "%.2f", alpha)))"
        }
        return "rgb(\(r), \(g), \(b))"
    }
}
