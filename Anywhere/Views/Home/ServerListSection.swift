//
//  ServerListSection.swift
//  Anywhere
//
//  Постоянный список серверов вместо всплывающего Menu.
//  Спека: design for anywhere/SPEC.md, разделы 5 и 6.
//

import SwiftUI

struct ServerListSection: View {

    /// Секции ровно те же, что раньше отдавались в `Menu`:
    /// `configStore.standalonePickerItems`, `chainStore.pickerItems` («Chains»),
    /// `subscriptionStore.pickerSections` (заголовок = имя подписки).
    let sections: [PickerSection]

    let selectedId: UUID?
    let latencies: [UUID: LatencyResult]
    let isMeasuring: Bool

    let onSelect: (UUID) -> Void
    let onMeasure: () -> Void

    private static let rowHeight: CGFloat = 52
    private static let rowPadding: CGFloat = 16
    private static let flagWidth: CGFloat = 24
    private static let itemSpacing: CGFloat = 12
    private static let pingWidth: CGFloat = 46
    private static let tickWidth: CGFloat = 20
    /// rowPadding + flagWidth + itemSpacing — разделитель начинается там же, где название.
    private static let separatorInset: CGFloat = 52

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                if let title = section.header {
                    sectionHeader(title)
                        .padding(.top, index == 0 ? 0 : 8)
                }
                card(section)
            }
        }
    }

    // MARK: - Заголовок с кнопкой измерения

    private var header: some View {
        HStack(spacing: 0) {
            sectionHeader(String(localized: "server.list.header", defaultValue: "SERVER", comment: "Заголовок списка серверов"))
            Spacer(minLength: 0)
            measureButton
        }
        .frame(height: 44)
        .padding(.leading, 12)
        .padding(.trailing, -6)   // визуальный край круга совпадает с краем карточки
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .kerning(0.4)
            .foregroundStyle(.white.opacity(0.55))
            .padding(.leading, 12)
    }

    private var measureButton: some View {
        Button(action: onMeasure) {
            ZStack {
                Circle()
                    .fill(.white.opacity(0.12))
                    .frame(width: 32, height: 32)
                if isMeasuring {
                    ProgressView().controlSize(.small)
                } else {
                    gaugeIcon
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .frame(width: 44, height: 44)     // тап-зона
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isMeasuring ? 0.65 : 1)
        .disabled(isMeasuring)
        .accessibilityLabel(String(localized: "server.list.measurePing", defaultValue: "Measure server ping"))
    }

    private var gaugeIcon: Image {
        if #available(iOS 16.0, *) {
            return Image(systemName: "gauge.with.needle")
        } else {
            return Image(systemName: "speedometer")
        }
    }

    // MARK: - Карточка секции

    private func card(_ section: PickerSection) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Rectangle()
                        .fill(.white.opacity(0.08))
                        .frame(height: 1)
                        .padding(.leading, Self.separatorInset)
                }
                row(item)
            }
        }
        .background(.primary.opacity(0.1))                       // как карточки статистики
        .clipShape(.rect(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Строка

    private func row(_ item: PickerItem) -> some View {
        let isSelected = item.id == selectedId
        // Флаг — эмодзи-префикс в имени конфигурации ("🇺🇸 Los Angeles"),
        // отдельного поля под него в модели нет.
        let (flag, name) = Self.splitFlag(from: item.name)

        return Button {
            onSelect(item.id)
        } label: {
            HStack(spacing: Self.itemSpacing) {
                Text(flag)
                    .font(.system(size: 20))
                    .frame(width: Self.flagWidth)

                Text(name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                pingCell(latencies[item.id])

                ZStack {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: Self.tickWidth)
            }
            .padding(.horizontal, Self.rowPadding)
            .frame(height: Self.rowHeight)
            .contentShape(Rectangle())
            .background(isSelected ? Color.white.opacity(0.14) : .clear)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// Ширина колонки фиксирована во всех состояниях — иначе названия
    /// прыгают в момент появления чисел.
    @ViewBuilder
    private func pingCell(_ result: LatencyResult?) -> some View {
        Group {
            switch result {
            case .testing:
                MeasuringPlaceholder()
            case .success(let ms):
                Text("\(ms) ms")
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.52))
            case .failed:
                Text(String(localized: "timeout"))
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.40))
            case .insecure:
                Text(String(localized: "insecure"))
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.40))
            case nil:
                Color.clear
            }
        }
        .frame(width: Self.pingWidth, alignment: .trailing)
    }

    private struct MeasuringPlaceholder: View {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var bright = false

        var body: some View {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(.white.opacity(0.18))
                .frame(width: 36, height: 8)
                .opacity(bright ? 1 : 0.40)
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.575).repeatForever(autoreverses: true),
                    value: bright
                )
                .onAppear { if !reduceMotion { bright = true } }
        }
    }

    // MARK: - Разбор имени

    /// Отделяет ведущий эмодзи-флаг от названия. Если флага нет — вернёт пустую строку.
    static func splitFlag(from name: String) -> (flag: String, rest: String) {
        guard let first = name.first,
              first.unicodeScalars.allSatisfy({ (0x1F1E6...0x1F1FF).contains($0.value) })
        else {
            return ("", name)
        }
        let rest = name.dropFirst().trimmingCharacters(in: .whitespaces)
        return (String(first), rest)
    }
}

#if DEBUG
#Preview("Список серверов") {
    let section = PickerSection(
        id: UUID(),
        header: nil,
        items: [
            PickerItem(id: UUID(), name: "🇷🇺 Russia"),
            PickerItem(id: UUID(), name: "🇺🇸 USA 1"),
            PickerItem(id: UUID(), name: "🇳🇱 Netherlands 1"),
            PickerItem(id: UUID(), name: "🇯🇵 Japan"),
        ]
    )
    return ServerListSection(
        sections: [section],
        selectedId: section.items.first?.id,
        latencies: [
            section.items[0].id: .success(18),
            section.items[1].id: .success(142),
            section.items[2].id: .testing,
        ],
        isMeasuring: true,
        onSelect: { _ in },
        onMeasure: {}
    )
    .padding(.horizontal, 20)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(
        LinearGradient(
            colors: [Color(red: 0.235, green: 0.243, blue: 0.263),
                     Color(red: 0.086, green: 0.090, blue: 0.098)],
            startPoint: .top,
            endPoint: .bottom
        )
    )
    .colorScheme(.dark)
}
#endif
