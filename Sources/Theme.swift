import SwiftUI

public enum Theme {
    // Backgrounds
    public static let bg = Color(hex: 0x1a1b26)
    public static let bgDark = Color(hex: 0x16161e)
    public static let bgHighlight = Color(hex: 0x292e42)
    public static let bgFloat = Color(hex: 0x1f2335)

    // Foregrounds
    public static let fg = Color(hex: 0xc0caf5)
    public static let fgDark = Color(hex: 0xa9b1d6)
    public static let comment = Color(hex: 0x565f89)

    // Accents
    public static let blue = Color(hex: 0x7aa2f7)
    public static let cyan = Color(hex: 0x7dcfff)
    public static let purple = Color(hex: 0xbb9af7)
    public static let green = Color(hex: 0x9ece6a)
    public static let yellow = Color(hex: 0xe0af68)
    public static let orange = Color(hex: 0xff9e64)
    public static let red = Color(hex: 0xf7768e)

    public static let border = Color(hex: 0x3b4261)

    // Typography
    public static let body = Font.system(size: 13)
    public static let bodyMedium = Font.system(size: 13, weight: .medium)
    public static let bodyBold = Font.system(size: 13, weight: .semibold)
    public static let small = Font.system(size: 11)
    public static let smallMedium = Font.system(size: 11, weight: .medium)
    public static let smallBold = Font.system(size: 11, weight: .semibold)

    public static let mono = Font.system(size: 11, design: .monospaced)
    public static let monoBody = Font.system(size: 13, design: .monospaced)
}

public extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255.0,
            green: Double((hex >> 8) & 0xff) / 255.0,
            blue: Double(hex & 0xff) / 255.0,
            opacity: 1.0
        )
    }
}
