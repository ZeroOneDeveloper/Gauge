import SwiftUI
import GaugeCore

enum Palette {
    static let background = Color(hex: 0xF6F7F9)
    static let ink = Color(hex: 0x202631)
    static let secondary = Color(hex: 0x6F7885)
    static let line = Color(hex: 0xE9ECF0)
    static let accent = Color(hex: 0xE38C58)
    static let green = Color(hex: 0x399F83)
    static let amber = Color(hex: 0xD9A13E)
    static let red = Color(hex: 0xDA6A67)
    static let sidebar = Color(hex: 0x202832)
    static func provider(_ provider: Provider) -> Color {
        switch provider {
        case .claude: accent
        case .codex: Color(hex: 0x617BC7)
        case .gemini: Color(hex: 0x8861C5)
        }
    }
    static func usage(_ percent: Double) -> Color { percent >= 90 ? red : percent >= 75 ? amber : green }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255, opacity: 1)
    }
}

struct BrandMark: View {
    var size: CGFloat = 35
    var body: some View {
        Image(systemName: "gauge.with.dots.needle.67percent")
            .font(.system(size: size * 0.57, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Palette.accent.gradient, in: RoundedRectangle(cornerRadius: size * 0.28))
    }
}

struct BrandLockup: View {
    var markSize: CGFloat = 32
    var titleSize: CGFloat = 26
    var spacing: CGFloat = 10
    var tracking: CGFloat = -1

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            BrandMark(size: markSize)
            Text("gauge")
                .font(.system(size: titleSize, weight: .semibold, design: .rounded))
                .tracking(tracking)
                // Center the lowercase wordmark's visible glyphs rather than
                // its line box, which reserves unused space for ascenders.
                .offset(y: -titleSize * 0.2)
        }.frame(height: markSize)
    }
}

struct ProviderMark: View {
    var provider: Provider
    var size: CGFloat = 44
    var body: some View {
        Group {
            if provider == .gemini {
                Image(systemName: "sparkles").font(.system(size: size * 0.56, weight: .semibold))
                    .foregroundStyle(Palette.provider(provider))
            } else {
                Image(nsImage: ProviderArtwork.image(for: provider))
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: size * (provider == .claude ? 0.68 : 0.84), height: size * (provider == .claude ? 0.68 : 0.84))
            }
        }
        .frame(width: size, height: size)
        .background(Palette.provider(provider).opacity(0.1), in: RoundedRectangle(cornerRadius: size * 0.29))
        .accessibilityLabel(provider.title)
    }
}

private enum ProviderArtwork {
    private static let images: [Provider: NSImage] = Dictionary(uniqueKeysWithValues: [Provider.claude, .codex].map { provider in
        // CoreSVG misrenders the compact arc commands in the Codex SVG. Its PDF
        // is generated from that same SVG with librsvg and retains vector paths.
        let fileExtension = provider == .codex ? "pdf" : "svg"
        let url = Bundle.main.url(forResource: provider.rawValue, withExtension: fileExtension, subdirectory: "ProviderIcons")
            ?? Bundle.module.url(forResource: provider.rawValue, withExtension: fileExtension, subdirectory: "ProviderIcons")
        guard let url, let image = NSImage(contentsOf: url), image.isValid else {
            preconditionFailure("Missing provider artwork: \(provider.rawValue)")
        }
        return (provider, image)
    })
    static func image(for provider: Provider) -> NSImage { images[provider]! }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 11)
            .background(Palette.ink.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 9))
            .opacity(enabled ? 1 : 0.4)
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14, weight: .medium))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(configuration.isPressed ? Palette.line : .white, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line, lineWidth: 1))
    }
}

struct IconButtonStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        IconButtonContent(label: configuration.label, pressed: configuration.isPressed, selected: selected)
    }

    private struct IconButtonContent<Label: View>: View {
        let label: Label
        let pressed: Bool
        let selected: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovered = false

        var body: some View {
            label.font(.system(size: 15, weight: .medium))
                .foregroundStyle(selected ? Palette.accent : Palette.secondary)
                .frame(width: 32, height: 32)
                .background(pressed ? Palette.line : hovered && enabled ? Palette.line.opacity(0.6) : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .opacity(enabled ? 1 : 0.4)
                .onHover { hovered = $0 }
        }
    }
}

struct Card<Content: View>: View {
    var fillHeight = false
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(24).frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
            .background(.white, in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(Palette.line, lineWidth: 1))
    }
}

struct SectionLabel: View {
    var title: String
    var detail: String? = nil
    var body: some View {
        HStack {
            Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink)
            if let detail { Text(detail).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.secondary) }
            Spacer()
        }
    }
}

struct UsageBar: View {
    var percent: Double
    var muted = false
    var height: CGFloat = 8
    var showsRemaining = false
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.line)
                Capsule().fill(muted ? Palette.secondary : Palette.usage(percent))
                    .frame(width: max(0, geometry.size.width * min(100, max(0, showsRemaining ? 100 - percent : percent)) / 100))
            }
        }.frame(height: height)
    }
}

struct StatusPill: View {
    var title: String
    var color: Color
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title).font(.system(size: 12, weight: .medium))
        }.foregroundStyle(color).padding(.horizontal, 10).padding(.vertical, 6)
            .background(color.opacity(0.08), in: Capsule())
    }
}
