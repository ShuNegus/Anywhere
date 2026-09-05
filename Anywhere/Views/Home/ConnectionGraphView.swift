//
//  ConnectionGraphView.swift
//  Anywhere
//
//  Граф этапов подключения в стиле git-веток.
//  Спека: design for anywhere/SPEC.md, раздел 3.
//

import SwiftUI

struct ConnectionGraphView: View {

    let stage: ConnectionStage

    // MARK: - Геометрия (см. SPEC.md 3.2)

    private static let height: CGFloat = 210
    private static let trunkX: CGFloat = 14
    private static let branchX: CGFloat = 62
    private static let labelX: CGFloat = 86
    private static let firstRowY: CGFloat = 20
    private static let rowSpacing: CGFloat = 34
    private static let dotSize: CGFloat = 12
    private static let edgeWidth: CGFloat = 2

    // MARK: - Палитра

    /// Единственный новый цвет в дизайне: пройденный этап.
    static let reachedColor = Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255)   // #30D158
    /// Узел, на котором подключение встало. Системный `.red` тёмной темы.
    static let failedColor = Color(red: 255 / 255, green: 69 / 255, blue: 58 / 255)     // #FF453A
    private static let idleEdgeColor = Color.white.opacity(0.14)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            edges
            ForEach(ConnectionGraphNode.allCases) { node in
                dot(for: node)
            }
            ForEach(ConnectionGraphNode.allCases) { node in
                label(for: node)
            }
        }
        .frame(height: Self.height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.35), value: stage)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .onAppear {
            guard !reduceMotion else { return }
            pulsing = true
        }
    }

    // MARK: - Позиции

    private static func center(of node: ConnectionGraphNode) -> CGPoint {
        CGPoint(
            x: node.isOnBypassBranch ? branchX : trunkX,
            y: firstRowY + rowSpacing * CGFloat(node.rawValue - 1)
        )
    }

    // MARK: - Рёбра

    /// Порядок важен: прямой ствол рисуется после ветки, иначе серая кривая
    /// перекрывает зелёный ствол у точек ветвления и мержа.
    private var edges: some View {
        ZStack(alignment: .topLeading) {
            edge(from: .whitelistCheck, to: .turnTunnel)   // ответвление на обход
            edge(from: .turnTunnel, to: .captcha)
            edge(from: .captcha, to: .connected)           // мерж
            edge(from: .whitelistCheck, to: .connected)    // прямой ствол
            edge(from: .vpnConnect, to: .whitelistCheck)
            edge(from: .networkCheck, to: .vpnConnect)
        }
    }

    private func edge(from: ConnectionGraphNode, to: ConnectionGraphNode) -> some View {
        EdgePath(from: Self.center(of: from), to: Self.center(of: to))
            .stroke(
                stage.isEdgeTraversed(from: from, to: to) ? Self.reachedColor : Self.idleEdgeColor,
                style: StrokeStyle(lineWidth: Self.edgeWidth, lineCap: .round)
            )
    }

    /// Вертикаль, если точки в одной колонке; иначе S-образная кривая между колонками.
    private struct EdgePath: Shape {
        let from: CGPoint
        let to: CGPoint

        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: from)
            if from.x == to.x {
                path.addLine(to: to)
            } else {
                // Контрольные точки повторяют кривые из макета: излом
                // укладывается ровно в один шаг строки.
                path.addCurve(
                    to: to,
                    control1: CGPoint(x: from.x, y: from.y + 19),
                    control2: CGPoint(x: to.x, y: to.y - 19)
                )
            }
            return path
        }
    }

    // MARK: - Узлы

    @ViewBuilder
    private func dot(for node: ConnectionGraphNode) -> some View {
        let state = stage.state(of: node)
        let center = Self.center(of: node)

        ZStack {
            if state == .current {
                // Пульсирующее кольцо вокруг текущего узла.
                Circle()
                    .fill(Self.reachedColor.opacity(pulsing ? 0.05 : 0.18))
                    .frame(
                        width: Self.dotSize + (pulsing ? 18 : 8),
                        height: Self.dotSize + (pulsing ? 18 : 8)
                    )
                    .animation(
                        reduceMotion
                            ? nil
                            : .easeInOut(duration: 0.85).repeatForever(autoreverses: true),
                        value: pulsing
                    )
            }

            Circle()
                .fill(fill(for: state))
                .overlay {
                    switch state {
                    case .off:
                        Circle().strokeBorder(Color.white.opacity(0.20), lineWidth: 2)
                    case .skipped:
                        // Шаг не потребовался: полый узел с зелёной обводкой,
                        // рёбра вокруг него при этом зелёные.
                        Circle().strokeBorder(Self.reachedColor.opacity(0.40), lineWidth: 2)
                    case .done, .current, .failed:
                        EmptyView()
                    }
                }
                .frame(width: Self.dotSize, height: Self.dotSize)
                .shadow(
                    color: glowColor(for: state),
                    radius: state == .current ? 9 : 5
                )
        }
        .frame(width: Self.dotSize, height: Self.dotSize)
        .offset(x: center.x - Self.dotSize / 2, y: center.y - Self.dotSize / 2)
    }

    private func fill(for state: ConnectionNodeState) -> Color {
        switch state {
        case .off, .skipped:   return .white.opacity(0.06)
        case .done, .current:  return Self.reachedColor
        case .failed:          return Self.failedColor
        }
    }

    private func glowColor(for state: ConnectionNodeState) -> Color {
        switch state {
        case .off, .skipped: return .clear
        case .done:          return Self.reachedColor.opacity(0.45)
        case .current:       return Self.reachedColor.opacity(0.75)
        // Свечение без пульсации: провал — конечное состояние, мигать нечему.
        case .failed:        return Self.failedColor.opacity(0.65)
        }
    }

    // MARK: - Подписи

    private func label(for node: ConnectionGraphNode) -> some View {
        let state = stage.state(of: node)
        return Text(node.title)
            .font(.system(size: 13, weight: state == .current || state == .failed ? .semibold : .regular))
            .foregroundStyle(labelColor(for: state))
            .lineLimit(1)
            .fixedSize()
            .offset(x: Self.labelX, y: Self.center(of: node).y - 8)
    }

    private func labelColor(for state: ConnectionNodeState) -> Color {
        switch state {
        case .off, .skipped: return .white.opacity(0.45)
        case .done:          return .white.opacity(0.68)
        case .current, .failed: return .white
        }
    }

    // MARK: - Accessibility

    private var accessibilitySummary: String {
        guard let current = stage.currentNode else {
            return String(localized: "graph.a11y.idle", defaultValue: "Connection not started")
        }
        return String(
            localized: "graph.a11y.stage",
            defaultValue: "Connection stage: \(current.title)",
            comment: "VoiceOver-описание графа подключения"
        )
    }
}

#if DEBUG
#Preview("Все этапы") {
    ScrollView {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(
                [ConnectionStage.idle, .networkCheck, .vpnConnect, .whitelistCheck,
                 .turnTunnel, .captcha, .connectedViaTurn(captchaSolved: true),
                 .connectedViaTurn(captchaSolved: false), .connectedDirect,
                 .failed(.turnTimeout)],
                id: \.self
            ) { stage in
                ConnectionGraphView(stage: stage)
            }
        }
        .padding(24)
    }
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
