import NoBeachballsCore
import SwiftUI

enum Theme {
    static let background = Color(red: 0.055, green: 0.063, blue: 0.078)
    static let panel = Color(red: 0.09, green: 0.10, blue: 0.12)
    static let border = Color(white: 0.24)
    static let text = Color(white: 0.88)
    static let dim = Color(white: 0.52)
    static let accent = Color(red: 0.36, green: 0.78, blue: 0.98)
    static let green = Color(red: 0.36, green: 0.84, blue: 0.48)
    static let yellow = Color(red: 0.98, green: 0.80, blue: 0.30)
    static let red = Color(red: 0.98, green: 0.38, blue: 0.36)

    static func mono(_ size: CGFloat = 11, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// btop-style meter color: green → yellow → red.
    static func meter(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.6: green
        case ..<0.85: yellow
        default: red
        }
    }

    static func level(_ level: HealthLevel) -> Color {
        switch level {
        case .ok: green
        case .elevated: accent
        case .strained: yellow
        case .lagging: red
        }
    }
}

struct Panel<Content: View>: View {
    let title: String
    var trailing: String = ""
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(Theme.mono(11, .bold)).foregroundStyle(Theme.accent)
                Spacer()
                Text(trailing).font(Theme.mono(11)).foregroundStyle(Theme.dim)
            }
            content
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.panel)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Filled area graph of values in 0...max.
struct Sparkline: View {
    let values: [Double]
    var max: Double = 1
    var capacity = 90

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let step = size.width / CGFloat(capacity - 1)
            let start = size.width - step * CGFloat(values.count - 1)
            var line = Path()
            for (i, v) in values.enumerated() {
                let y = size.height * (1 - CGFloat(Swift.min(v / self.max, 1)))
                let point = CGPoint(x: start + step * CGFloat(i), y: y)
                i == 0 ? line.move(to: point) : line.addLine(to: point)
            }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: start, y: size.height))
            area.closeSubpath()

            let gradient = Gradient(colors: [Theme.red, Theme.yellow, Theme.green])
            let shading = GraphicsContext.Shading.linearGradient(gradient, startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height))
            context.opacity = 0.35
            context.fill(area, with: shading)
            context.opacity = 1
            context.stroke(line, with: shading, lineWidth: 1.2)
        }
        .background(Color.black.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

struct MeterBar: View {
    let fraction: Double
    var color: Color?
    var height: CGFloat = 7

    var body: some View {
        Capsule()
            .fill(Color.white.opacity(0.08))
            .overlay(alignment: .leading) {
                MeterFill(fraction: fraction)
                    .fill(color ?? Theme.meter(fraction))
            }
        .frame(height: height)
    }
}

/// Draw directly in the proposed bounds; no geometry feedback or extra layout pass.
private struct MeterFill: Shape {
    let fraction: Double

    func path(in rect: CGRect) -> Path {
        let width = rect.width * CGFloat(min(max(fraction, 0), 1))
        return Capsule().path(in: CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height))
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var tint: Color = Theme.text
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 18)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct LabeledButton: View {
    let title: String
    let symbol: String
    var tint: Color = Theme.text
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(Theme.mono(11, .semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(tint.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }
}

func percent(_ cpu: Double) -> String {
    cpu >= 100 ? String(format: "%.0f%%", cpu) : String(format: "%.1f%%", cpu)
}

func duration(since date: Date) -> String {
    let s = Int(Date().timeIntervalSince(date))
    return s < 60 ? "\(s)s" : s < 3600 ? "\(s / 60)m \(s % 60)s" : "\(s / 3600)h \((s % 3600) / 60)m"
}
