import SwiftUI
import UIKit

// MARK: - Цвета

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if s.count != 6 { s = "B359FF" }
        let v = UInt64(s, radix: 16) ?? 0xB359FF
        self.init(red: Double((v >> 16) & 0xFF) / 255.0,
                  green: Double((v >> 8) & 0xFF) / 255.0,
                  blue: Double(v & 0xFF) / 255.0)
    }

    var hexString: String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02X%02X%02X",
                      Int((r * 255).rounded()),
                      Int((g * 255).rounded()),
                      Int((b * 255).rounded()))
    }

    var luminance: Double {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return Double(0.299 * r + 0.587 * g + 0.114 * b)
    }
}

// MARK: - Готовые темы интерфейса

enum AppTheme: String, CaseIterable, Identifiable {
    case dark, light, purple, ocean, sunset
    var id: String { rawValue }

    func title(_ lang: AppLanguage) -> String {
        switch self {
        case .dark: return lang == .ru ? "Чёрная" : "Black"
        case .light: return lang == .ru ? "Белая" : "White"
        case .purple: return lang == .ru ? "Фиолетовая" : "Purple"
        case .ocean: return lang == .ru ? "Океан" : "Ocean"
        case .sunset: return lang == .ru ? "Закат" : "Sunset"
        }
    }

    var colors: [Color] {
        switch self {
        case .dark: return [Color(red: 0.03, green: 0.03, blue: 0.05), Color(red: 0.11, green: 0.11, blue: 0.14)]
        case .light: return [Color(red: 0.97, green: 0.97, blue: 1.0), Color(red: 0.84, green: 0.88, blue: 1.0)]
        case .purple: return [Color(red: 0.05, green: 0.04, blue: 0.16), Color(red: 0.20, green: 0.07, blue: 0.38)]
        case .ocean: return [Color(red: 0.02, green: 0.08, blue: 0.18), Color(red: 0.0, green: 0.30, blue: 0.42)]
        case .sunset: return [Color(red: 0.17, green: 0.04, blue: 0.16), Color(red: 0.58, green: 0.18, blue: 0.20)]
        }
    }

    var isLight: Bool { self == .light }
}

// MARK: - Палитра приложения

struct Palette {
    let colors: [Color]
    let accent: Color
    let isLight: Bool

    var scheme: ColorScheme { isLight ? .light : .dark }
    var text: Color { isLight ? Color(white: 0.08) : .white }
    var subtext: Color { text.opacity(0.6) }
    /// Цвет текста на кнопках: тёмный на светлых цветах, белый на тёмных
    var onAccent: Color { accent.luminance > 0.72 ? Color(white: 0.08) : .white }
}

// MARK: - Стиль нажатия (вся площадь кнопки + анимация)

struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Liquid Glass

struct GlassSurface: ViewModifier {
    let shape: AnyShape
    var tint: Color? = nil
    var interactive: Bool = false

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(makeGlass(), in: shape)
        } else {
            // Запасной вариант для iOS ниже 26
            if let tint {
                content.background(
                    LinearGradient(colors: [tint, tint.opacity(0.7)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: shape
                )
            } else {
                content
                    .background(.ultraThinMaterial, in: shape)
                    .overlay(shape.stroke(Color.white.opacity(0.14), lineWidth: 0.6))
            }
        }
    }

    @available(iOS 26.0, *)
    private func makeGlass() -> Glass {
        var g = Glass.regular
        if let tint { g = g.tint(tint) }
        if interactive { g = g.interactive() }
        return g
    }
}

extension View {
    /// Стеклянная карточка
    func glassCard(_ p: Palette, radius: CGFloat = 26, padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .modifier(GlassSurface(shape: AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous))))
    }

    /// Стеклянная капсула / круг (для кнопок)
    func glassButton(_ tint: Color?, interactive: Bool = false) -> some View {
        self.modifier(GlassSurface(shape: AnyShape(Capsule()), tint: tint, interactive: interactive))
    }
}

// MARK: - Фон

struct ThemedBackground: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        let p = store.palette
        ZStack {
            LinearGradient(colors: p.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle()
                .fill(p.accent.opacity(p.isLight ? 0.35 : 0.45))
                .frame(width: 320, height: 320)
                .blur(radius: 90)
                .offset(x: -140, y: -290)
            Circle()
                .fill(p.accent.opacity(p.isLight ? 0.22 : 0.28))
                .frame(width: 280, height: 280)
                .blur(radius: 100)
                .offset(x: 170, y: 320)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Карточка выбора файла

struct FileCard: View {
    let theme: Palette
    let title: String
    let icon: String
    let subtitle: String
    let done: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(theme.accent)
                    .frame(width: 46, height: 46)
                    .background(theme.accent.opacity(0.16),
                                in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .foregroundColor(theme.text)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(done ? .green : theme.subtext)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: done ? "checkmark.circle.fill" : "plus.circle.fill")
                    .font(.title3)
                    .foregroundColor(done ? .green : theme.subtext)
            }
            .frame(maxWidth: .infinity)
            .glassCard(theme)
        }
        .buttonStyle(PressStyle())
    }
}
