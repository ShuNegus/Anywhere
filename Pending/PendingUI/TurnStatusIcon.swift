//
//  TurnStatusIcon.swift
//  Anywhere
//
//  Знак резервного пути у имени подписки: «мост через реле» (две опоры и арка
//  с точкой-реле). Три состояния — есть, нет, сломан. Рисунок — сетка 24 × 24
//  из макета (вариант А), толщина линии 2,4.
//

import SwiftUI

/// Цвета статуса резервного пути. Красный — вариант повышенного контраста:
/// системный #FF453A на синем градиенте читается хуже 3 : 1.
enum TurnStatusPalette {
    /// Иконка «сломан».
    static let errorIcon = Color(red: 1, green: 105 / 255, blue: 97 / 255)          // #FF6961
    /// Красный текст: статус под кнопкой, строка графа.
    static let warningText = Color(red: 1, green: 138 / 255, blue: 128 / 255)       // #FF8A80
}

/// Рисунок знака в квадрате 24 × 24, масштабируется под рамку.
struct BackupRouteGlyph: View {
    enum Kind { case available, absent, error }

    let kind: Kind
    let color: Color

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 24
            context.scaleBy(x: scale, y: scale)
            let stroke = StrokeStyle(lineWidth: 2.4, lineCap: .round)
            let shading = GraphicsContext.Shading.color(color)

            func dot(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) {
                context.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)), with: shading)
            }

            switch kind {
            case .available:
                var arc = Path()
                arc.move(to: CGPoint(x: 4, y: 18))
                arc.addCurve(to: CGPoint(x: 20, y: 18), control1: CGPoint(x: 4, y: 4.5), control2: CGPoint(x: 20, y: 4.5))
                context.stroke(arc, with: shading, style: stroke)
                dot(12, 7.9, 2.6)
            case .absent:
                // Та же арка точками — семь кружков по кривой (t = 1/8…7/8).
                for (x, y) in [(4.7, 13.6), (6.5, 10.4), (9.1, 8.5), (12, 7.9),
                               (14.9, 8.5), (17.5, 10.4), (19.3, 13.6)] {
                    dot(x, y, 1.2)
                }
            case .error:
                // Арка разрезана на t = 0.34 и 0.66: два обрубка от опор, реле нет.
                var left = Path()
                left.move(to: CGPoint(x: 4, y: 18))
                left.addCurve(to: CGPoint(x: 8.3, y: 8.9), control1: CGPoint(x: 4, y: 13.4), control2: CGPoint(x: 5.8, y: 10.4))
                var right = Path()
                right.move(to: CGPoint(x: 15.7, y: 8.9))
                right.addCurve(to: CGPoint(x: 20, y: 18), control1: CGPoint(x: 18.2, y: 10.4), control2: CGPoint(x: 20, y: 13.4))
                context.stroke(left, with: shading, style: stroke)
                context.stroke(right, with: shading, style: stroke)
            }
            dot(4, 18, 2.8)
            dot(20, 18, 2.8)
        }
        .accessibilityHidden(true)
    }
}

/// Знак у имени подписки с пояснением по тапу.
struct TurnStatusIcon: View {
    let availability: TurnAvailability
    /// Режим из настроек — меняет вторую строку пояснения у «есть».
    let mode: TurnMode

    @State private var showingInfo = false

    var body: some View {
        Button {
            showingInfo = true
        } label: {
            BackupRouteGlyph(kind: kind, color: color)
                .frame(width: 12, height: 12)
                .frame(width: 32, height: 32)       // тап-зона без подложки
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(String(localized: "turn.icon.a11yHint", defaultValue: "Details", comment: "VoiceOver: по тапу — пояснение"))
        .popover(isPresented: $showingInfo) {
            VStack(alignment: .leading, spacing: 3) {
                Text(info.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isError ? TurnStatusPalette.warningText : .primary)
                Text(info.message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .frame(width: 252, alignment: .leading)
            .presentationCompactAdaptation(.popover)
        }
    }

    private var kind: BackupRouteGlyph.Kind {
        switch availability {
        case .available: return .available
        case .absent:    return .absent
        case .error:     return .error
        }
    }

    private var isError: Bool {
        if case .error = availability { return true }
        return false
    }

    /// Пока открыто пояснение, знак подсвечен — видно, к чему относится облачко.
    private var color: Color {
        switch availability {
        case .available: return .white.opacity(showingInfo ? 1 : 0.78)
        case .absent:    return .white.opacity(showingInfo ? 0.6 : 0.34)
        case .error:     return TurnStatusPalette.errorIcon
        }
    }

    private var info: (title: String, message: String) {
        switch availability {
        case .available:
            let title = String(localized: "turn.icon.available.title", defaultValue: "Backup route", comment: "Поповер иконки: резервный путь есть")
            let message: String
            switch mode {
            case .auto:
                message = String(localized: "turn.icon.available.auto", defaultValue: "Available for this subscription. It turns on by itself if your carrier blocks the regular connection.", comment: "Поповер: режим Авто")
            case .on:
                message = String(localized: "turn.icon.available.on", defaultValue: "Available for this subscription. Used on every connection.", comment: "Поповер: режим Вкл")
            case .off:
                message = String(localized: "turn.icon.available.off", defaultValue: "Available for this subscription. Currently turned off in Settings.", comment: "Поповер: режим Выкл")
            }
            return (title, message)
        case .absent:
            return (
                String(localized: "turn.icon.none.title", defaultValue: "No backup route", comment: "Поповер иконки: резервного пути нет"),
                String(localized: "turn.icon.none.message", defaultValue: "This subscription connects directly only.", comment: "Поповер иконки: резервного пути нет — текст")
            )
        case .error(let reason):
            return reason.popover ?? (reason.rowText(serverName: nil), reason.nodeText)
        }
    }

    private var accessibilityLabel: String {
        switch availability {
        case .available:
            return String(localized: "turn.icon.available.a11y", defaultValue: "Backup route available", comment: "VoiceOver: резервный путь есть")
        case .absent:
            return String(localized: "turn.icon.none.a11y", defaultValue: "No backup route", comment: "VoiceOver: резервного пути нет")
        case .error:
            return info.title
        }
    }
}

#if DEBUG
#Preview("Состояния") {
    VStack(alignment: .leading, spacing: 18) {
        ForEach([TurnAvailability.available, .absent, .error(.noVkLink)], id: \.self) { state in
            HStack(spacing: 18) {
                TurnStatusIcon(availability: state, mode: .auto)
                switch state {
                case .available: BackupRouteGlyph(kind: .available, color: .white.opacity(0.78)).frame(width: 48, height: 48)
                case .absent: BackupRouteGlyph(kind: .absent, color: .white.opacity(0.34)).frame(width: 48, height: 48)
                case .error: BackupRouteGlyph(kind: .error, color: TurnStatusPalette.errorIcon).frame(width: 48, height: 48)
                }
            }
        }
    }
    .padding(32)
    .background(LinearGradient(colors: [Color(red: 22/255, green: 101/255, blue: 192/255), Color(red: 11/255, green: 37/255, blue: 79/255)], startPoint: .top, endPoint: .bottom))
}
#endif
