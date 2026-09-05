//
//  ConnectionGraphCollapsedView.swift
//  Anywhere
//
//  Свёрнутый граф: одна строка 44 pt с мини-схемой и текстом.
//  Спека: design for anywhere/SPEC.md, раздел 3.5.
//

import SwiftUI

struct ConnectionGraphCollapsedView: View {

    let stage: ConnectionStage

    // MARK: - Геометрия (SPEC.md 3.5)

    private static let miniWidth: CGFloat = 92
    private static let miniHeight: CGFloat = 28
    private static let dotSize: CGFloat = 7
    private static let edgeWidth: CGFloat = 1.5
    private static let trunkY: CGFloat = 20
    private static let branchY: CGFloat = 8

    /// Те же шесть узлов, что в развёрнутом графе, разложенные по горизонтали.
    private static func center(of node: ConnectionGraphNode) -> CGPoint {
        CGPoint(
            x: 6 + 16 * CGFloat(node.rawValue - 1),
            y: node.isOnBypassBranch ? branchY : trunkY
        )
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 12) {
            miniGraph
            Text(summary)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.68))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.down")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.40))
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.35), value: stage)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary)
        .accessibilityHint(String(localized: "graph.a11y.expandHint", defaultValue: "Show connection stages", comment: "VoiceOver-подсказка свёрнутого графа"))
        .onAppear {
            guard !reduceMotion else { return }
            pulsing = true
        }
    }

    // MARK: - Мини-схема

    private var miniGraph: some View {
        ZStack(alignment: .topLeading) {
            // Порядок как в развёрнутом графе: ствол поверх ветки.
            edge(from: .whitelistCheck, to: .turnTunnel)
            edge(from: .turnTunnel, to: .captcha)
            edge(from: .captcha, to: .connected)
            edge(from: .whitelistCheck, to: .connected)
            edge(from: .vpnConnect, to: .whitelistCheck)
            edge(from: .networkCheck, to: .vpnConnect)

            ForEach(ConnectionGraphNode.allCases) { node in
                dot(for: node)
            }
        }
        .frame(width: Self.miniWidth, height: Self.miniHeight)
    }

    private func edge(from: ConnectionGraphNode, to: ConnectionGraphNode) -> some View {
        MiniEdgePath(from: Self.center(of: from), to: Self.center(of: to))
            .stroke(
                stage.isEdgeTraversed(from: from, to: to)
                    ? ConnectionGraphView.reachedColor
                    : Color.white.opacity(0.14),
                style: StrokeStyle(lineWidth: Self.edgeWidth, lineCap: .round)
            )
    }

    private struct MiniEdgePath: Shape {
        let from: CGPoint
        let to: CGPoint

        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: from)
            if from.y == to.y {
                path.addLine(to: to)
            } else {
                path.addCurve(
                    to: to,
                    control1: CGPoint(x: from.x, y: from.y - 8),
                    control2: CGPoint(x: to.x, y: to.y + 8)
                )
            }
            return path
        }
    }

    @ViewBuilder
    private func dot(for node: ConnectionGraphNode) -> some View {
        let state = stage.state(of: node)
        let center = Self.center(of: node)

        ZStack {
            if state == .current {
                Circle()
                    .fill(ConnectionGraphView.reachedColor.opacity(pulsing ? 0.05 : 0.18))
                    .frame(
                        width: Self.dotSize + (pulsing ? 12 : 6),
                        height: Self.dotSize + (pulsing ? 12 : 6)
                    )
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.85).repeatForever(autoreverses: true),
                        value: pulsing
                    )
            }

            Circle()
                .fill(fill(for: state))
                .overlay {
                    switch state {
                    case .off:
                        Circle().strokeBorder(Color.white.opacity(0.20), lineWidth: 1.5)
                    case .skipped:
                        Circle().strokeBorder(ConnectionGraphView.reachedColor.opacity(0.40), lineWidth: 1.5)
                    case .done, .current, .failed:
                        EmptyView()
                    }
                }
                .frame(width: Self.dotSize, height: Self.dotSize)
        }
        .frame(width: Self.dotSize, height: Self.dotSize)
        .offset(x: center.x - Self.dotSize / 2, y: center.y - Self.dotSize / 2)
    }

    private func fill(for state: ConnectionNodeState) -> Color {
        switch state {
        case .off, .skipped:  return .white.opacity(0.06)
        case .done, .current: return ConnectionGraphView.reachedColor
        case .failed:         return ConnectionGraphView.failedColor
        }
    }

    // MARK: - Текст

    private var summary: String {
        switch stage {
        case .idle:
            return String(localized: "graph.collapsed.idle", defaultValue: "Connection Stages", comment: "Свёрнутый граф в покое")
        case .connectedViaTurn:
            return String(localized: "graph.collapsed.viaTurn", defaultValue: "Connected via TURN", comment: "Свёрнутый граф, шли через обход")
        case .connectedDirect:
            return String(localized: "graph.collapsed.direct", defaultValue: "Connected Directly", comment: "Свёрнутый граф, обход не понадобился")
        case .failed(let failure):
            return String(localized: "graph.collapsed.failed", defaultValue: "Failed: \(failure.node.title)", comment: "Свёрнутый граф, подключение встало")
        default:
            return stage.currentNode?.title ?? ""
        }
    }
}
