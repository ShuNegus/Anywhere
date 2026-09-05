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
    let onAddSubscription: () -> Void
    /// Вызывается с id секции-подписки. Секции без заголовка (одиночные конфиги,
    /// цепочки) подписками не являются — у них корзина не показывается вовсе.
    let onDeleteSubscription: (UUID) -> Void

    private static let rowHeight: CGFloat = 52
    private static let rowPadding: CGFloat = 16
    private static let flagWidth: CGFloat = 24
    private static let itemSpacing: CGFloat = 12
    private static let pingWidth: CGFloat = 46
    private static let tickWidth: CGFloat = 20
    /// rowPadding + flagWidth + itemSpacing — разделитель начинается там же, где название.
    private static let separatorInset: CGFloat = 52
    /// Насколько строка уезжает, открывая кнопку удаления.
    private static let swipeWidth: CGFloat = 72
    /// Протяг дальше этого — удаление без второго тапа.
    private static let swipeCommit: CGFloat = 160

    /// Открытая свайпом секция — одновременно открыта не больше одной.
    @State private var swipedSection: UUID?
    @State private var draggingSection: UUID?
    @State private var dragTranslation: CGFloat = 0

    var body: some View {
        if sections.isEmpty {
            emptyState
        } else {
            list
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                if let title = section.header {
                    swipeableSubscriptionHeader(title, id: section.id)
                        .padding(.top, index == 0 ? 0 : 8)
                }
                card(section)
            }
        }
    }

    // MARK: - Заголовок с кнопкой измерения

    private var header: some View {
        HStack(spacing: 0) {
            sectionHeader(String(localized: "server.list.header", defaultValue: "SERVERS", comment: "Заголовок списка серверов"))
            Spacer(minLength: 0)
            measureButton
        }
        .frame(height: 44)
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

    // MARK: - Пустое состояние (SPEC.md §7)

    /// Подписки нет — списка тоже. Кнопка «+» при этом остаётся в верхней панели экрана,
    /// поэтому добавить подписку можно и отсюда, и оттуда.
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.white.opacity(0.35))
                .padding(.bottom, 4)

            Text(String(localized: "server.list.empty.title", defaultValue: "No Subscription", comment: "Пустое состояние списка серверов"))
                .font(.system(size: 17, weight: .semibold))

            Text(String(localized: "server.list.empty.body", defaultValue: "Add a subscription to see the server list", comment: "Пояснение пустого состояния"))
                .font(.system(size: 13))
                .lineSpacing(2)
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)

            Spacer().frame(height: 8)

            Button(action: onAddSubscription) {
                Text(String(localized: "server.list.addSubscription", defaultValue: "Add Subscription", comment: "Кнопка добавления подписки"))
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 22)
                    .frame(height: 44)
                    .background(.white.opacity(0.20), in: .capsule)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 24)
        .background(.primary.opacity(0.1))
        .clipShape(.rect(cornerRadius: 16, style: .continuous))
    }

    /// Свайп влево по заголовку подписки. `.swipeActions` тут недоступен — список
    /// собран из `VStack`, а не из `List`, поэтому жест свой.
    private func swipeableSubscriptionHeader(_ title: String, id: UUID) -> some View {
        let offset = swipeOffset(for: id)
        return ZStack(alignment: .trailing) {
            Button {
                commitDelete(id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: Self.swipeWidth, height: 32)
                    .background(Color.red, in: .rect(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(offset < -4 ? 1 : 0)
            .accessibilityHidden(true)

            // Пока строка уехала, своя корзина прячется — иначе две корзины подряд.
            subscriptionHeader(title, id: id, showsTrash: offset > -4)
                .offset(x: offset)
        }
        .animation(.easeOut(duration: 0.2), value: swipedSection)
        // Simultaneous so a vertical flick still scrolls the page: the gesture only
        // acts on drags that are clearly horizontal.
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onChanged { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    draggingSection = id
                    dragTranslation = value.translation.width
                }
                .onEnded { value in
                    defer { draggingSection = nil; dragTranslation = 0 }
                    guard draggingSection == id else { return }
                    let total = swipeOffset(for: id)
                    if total <= -Self.swipeCommit {
                        commitDelete(id)
                    } else if total <= -Self.swipeWidth / 2 {
                        swipedSection = id
                    } else {
                        swipedSection = nil
                    }
                }
        )
        // A section list that changed under the open row leaves it hanging open.
        .onChange(of: sections.map(\.id)) { _, _ in
            swipedSection = nil
            draggingSection = nil
            dragTranslation = 0
        }
    }

    private func swipeOffset(for id: UUID) -> CGFloat {
        let base: CGFloat = swipedSection == id ? -Self.swipeWidth : 0
        let live: CGFloat = draggingSection == id ? dragTranslation : 0
        return min(0, max(-Self.swipeCommit, base + live))
    }

    private func commitDelete(_ id: UUID) {
        swipedSection = nil
        draggingSection = nil
        dragTranslation = 0
        onDeleteSubscription(id)
    }

    /// Заголовок секции-подписки: имя слева, удаление справа.
    /// Корзина «плоская» — второстепенное действие рядом с двумя основными сверху.
    private func subscriptionHeader(_ title: String, id: UUID, showsTrash: Bool = true) -> some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .padding(.leading, 12)

            Spacer(minLength: 8)

            Button {
                onDeleteSubscription(id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(showsTrash ? 1 : 0)
            .accessibilityLabel(String(localized: "server.list.deleteSubscription", defaultValue: "Delete Subscription", comment: "Кнопка удаления подписки"))
        }
        .frame(height: 32)
        .padding(.trailing, -10)
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
#Preview("Пустое состояние") {
    ServerListSection(
        sections: [], selectedId: nil, latencies: [:], isMeasuring: false,
        onSelect: { _ in }, onMeasure: {}, onAddSubscription: {}, onDeleteSubscription: { _ in }
    )
    .padding(.horizontal, 20)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Color(red: 0.086, green: 0.090, blue: 0.098))
    .colorScheme(.dark)
}

#Preview("Список серверов") {
    let section = PickerSection(
        id: UUID(),
        header: "Bublik VPN",
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
        onMeasure: {},
        onAddSubscription: {},
        onDeleteSubscription: { _ in }
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
