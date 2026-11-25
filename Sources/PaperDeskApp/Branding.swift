import SwiftUI

struct PaperDeskWordmark: View {
    var size: CGFloat = 19
    var showsIcon = true

    private var accentColors: [Color] {
        [
            Color(nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor(srgbRed: 0.62, green: 0.78, blue: 0.98, alpha: 1)
                    : NSColor(srgbRed: 0.13, green: 0.28, blue: 0.50, alpha: 1)
            }),
            Color(nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor(srgbRed: 0.44, green: 0.82, blue: 0.80, alpha: 1)
                    : NSColor(srgbRed: 0.12, green: 0.44, blue: 0.46, alpha: 1)
            })
        ]
    }

    private var accent: LinearGradient {
        LinearGradient(colors: accentColors, startPoint: .leading, endPoint: .trailing)
    }

    var body: some View {
        HStack(spacing: size * 0.42) {
            if showsIcon {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                        .fill(accentColors[0].opacity(0.13))
                    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                        .strokeBorder(accentColors[1].opacity(0.28), lineWidth: 0.8)
                    Image(systemName: "book.closed")
                        .font(.system(size: size * 0.54, weight: .light))
                        .foregroundStyle(accent)
                }
                .frame(width: size * 1.04, height: size * 1.04)
            }

            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("Paper")
                    .font(.custom("Didot", size: size))
                    .foregroundStyle(.primary)
                Text("Desk")
                    .font(.custom("Didot-Italic", size: size))
                    .foregroundStyle(accent)
            }
            .tracking(0.55)
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [accentColors[0].opacity(0), accentColors[1].opacity(0.75), accentColors[0].opacity(0)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(height: 0.8)
                    .offset(y: 1.5)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("PaperDesk")
    }
}

struct PaperDeskBrandLockup: View {
    var body: some View {
        VStack(spacing: 11) {
            PaperDeskWordmark(size: 36, showsIcon: false)
            Text("THEORETICAL READING DESK")
                .font(.system(size: 9, weight: .medium, design: .default))
                .tracking(2.8)
                .foregroundStyle(.tertiary)
        }
    }
}
