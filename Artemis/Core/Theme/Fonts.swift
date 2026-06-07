//  Fonts.swift
//  ONE type system: San Francisco (the system font) everywhere, across messages,
//  headings, chips, labels and settings. The display serif (Spectral) is kept for
//  the single welcome heading only (welcomeHeading). sans/serif/voiceStyle all
//  resolve to SF, so the chat and controls never mix fonts.

import SwiftUI

enum ArtemisFont {
    /// ONE type system: San Francisco (the system font) everywhere. Used for all
    /// UI chrome, messages, headings, chips, labels and settings.
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Font.system(size: size, weight: weight)
    }

    /// Kept for source compatibility. Now ALSO San Francisco, so the chat and
    /// controls never mix fonts (this was previously a serif).
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .medium, italic: Bool = false) -> Font {
        let f = Font.system(size: size, weight: weight)
        return italic ? f.italic() : f
    }

    /// The ONLY display serif, used solely on the single welcome heading.
    static func welcomeSerif(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        Font.custom(weight >= .medium ? "Spectral-Medium" : "Spectral-Regular", size: size)
    }
}

private extension Font.Weight {
    static func >= (lhs: Font.Weight, rhs: Font.Weight) -> Bool { lhs.rank >= rhs.rank }
    var rank: Int {
        switch self {
        case .ultraLight: return 0
        case .thin: return 1
        case .light: return 2
        case .regular: return 3
        case .medium: return 4
        case .semibold: return 5
        case .bold: return 6
        case .heavy: return 7
        case .black: return 8
        default: return 3
        }
    }
}

extension View {
    /// Heading style: San Francisco, gently tracked. One consistent voice.
    func voiceStyle(_ size: CGFloat, weight: Font.Weight = .medium) -> some View {
        font(.system(size: size, weight: weight)).tracking(-0.006 * size)
    }

    /// The single welcome heading: the one place the display serif is allowed.
    func welcomeHeading(_ size: CGFloat, weight: Font.Weight = .medium) -> some View {
        font(ArtemisFont.welcomeSerif(size, weight)).tracking(-0.012 * size)
    }
}
