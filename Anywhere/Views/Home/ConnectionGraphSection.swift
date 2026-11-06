//
//  ConnectionGraphSection.swift
//  Anywhere
//
//  Этапы подключения на главном экране — по макету «Иконка TURN»
//  (https://claude.ai/artifact/3rjXs98MQWunjbvpRamukD):
//  свёрнуто — плашка 44 pt с точкой состояния и одной строкой текста;
//  развёрнуто — карточка со списком этапов, у каждого подпись-причина.
//  Развёрнут блок или нет — решает только пользователь, состояние переживает
//  смену этапа и перезапуск приложения.
//

import SwiftUI

/// Цвета точек этапов.
enum StagePalette {
    /// Пройденный этап.
    static let reached = Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255)    // #30D158
    /// Этап, на котором всё встало. Системный `.red` тёмной темы.
    static let failed = Color(red: 255 / 255, green: 69 / 255, blue: 58 / 255)     // #FF453A
}

struct ConnectionGraphSection: View {

    let stage: ConnectionStage
    /// Пул резервного пути: пока туннель работает, а ядро добирает пиры (и, может
    /// быть, просит капчу ради них), это видно подписью у «Подключено».
    var pool: TurnPoolSummary? = nil
    /// Имя выбранного сервера — для причины «у сервера нет резервного пути».
    var serverName: String? = nil

    @AppStorage("connectionGraphExpanded") private var isExpanded = false

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.3)) {
                isExpanded.toggle()
            }
        } label: {
            if isExpanded {
                StageListCard(stage: stage, pool: pool)
                    .accessibilityHint(String(localized: "graph.a11y.collapseHint", defaultValue: "Hide connection stages", comment: "VoiceOver-подсказка развёрнутого графа"))
            } else {
                StageRow(stage: stage, pool: pool, serverName: serverName)
            }
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.3), value: stage)
    }
}

// MARK: - Точка состояния

private struct StageDot: View {
    enum Style { case reached, current, failed, hollow, idle }

    let style: Style
    let size: CGFloat

    var body: some View {
        switch style {
        case .reached, .current:
            Circle()
                .fill(StagePalette.reached)
                .frame(width: size, height: size)
                .shadow(color: StagePalette.reached.opacity(style == .current ? 0.9 : 0.7), radius: style == .current ? 5 : 3)
        case .failed:
            Circle()
                .fill(StagePalette.failed)
                .frame(width: size, height: size)
                .shadow(color: StagePalette.failed.opacity(0.75), radius: 3)
        case .hollow:
            Circle()
                .strokeBorder(Color.white.opacity(0.45), lineWidth: 1.5)
                .frame(width: size, height: size)
        case .idle:
            Circle()
                .fill(Color.white.opacity(0.35))
                .frame(width: size, height: size)
        }
    }
}

// MARK: - Свёрнуто: плашка 44 pt

private struct StageRow: View {
    let stage: ConnectionStage
    let pool: TurnPoolSummary?
    let serverName: String?

    var body: some View {
        HStack(spacing: 8) {
            StageDot(style: dotStyle, size: 8)
            Text(summary)
                .font(.system(size: 14))
                .foregroundStyle(textColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Color.white.opacity(0.10), in: .rect(cornerRadius: 14, style: .continuous))
        .contentShape(.rect(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary)
        .accessibilityHint(String(localized: "graph.a11y.expandHint", defaultValue: "Show connection stages", comment: "VoiceOver-подсказка свёрнутого графа"))
    }

    private var dotStyle: StageDot.Style {
        switch stage {
        case .idle:
            return .idle
        case .failed:
            return .failed
        case .connectedWithoutTurn(let reason):
            return reason.isAlarming ? .failed : .hollow
        case .connectedViaTurn, .connectedDirect:
            return .reached
        default:
            return .current
        }
    }

    /// Причина без резервного пути — красным; «у сервера нет» — обычным белым.
    private var textColor: Color {
        if case .connectedWithoutTurn(let reason) = stage, reason.isAlarming {
            return TurnStatusPalette.warningText
        }
        if case .failed = stage { return TurnStatusPalette.warningText }
        return .white.opacity(0.85)
    }

    private var summary: String {
        switch stage {
        case .idle:
            return String(localized: "graph.collapsed.idle", defaultValue: "Tap to Connect", comment: "Свёрнутый граф в покое")
        case .connectedViaTurn:
            // Пул ещё добирает пиры или ждёт капчу — та же подпись, что у узла «Подключено».
            if let pool, pool.isAddingPeers || pool.needsCaptchaForMorePeers {
                return ConnectionGraphNode.connected.title(pool: pool)
            }
            return String(localized: "graph.collapsed.viaTurn", defaultValue: "Connected via Backup Route", comment: "Свёрнутый граф, шли через обход")
        case .connectedWithoutTurn(let reason):
            return reason.rowText(serverName: serverName)
        case .connectedDirect:
            return String(localized: "graph.collapsed.direct", defaultValue: "Connected Directly", comment: "Свёрнутый граф, обход не понадобился")
        case .failed(let failure):
            return String(localized: "graph.collapsed.failed", defaultValue: "Failed: \(failure.node.title)", comment: "Свёрнутый граф, подключение встало")
        default:
            return stage.currentNode?.title(pool: pool) ?? ""
        }
    }
}

// MARK: - Развёрнуто: карточка со списком этапов

private struct StageListCard: View {
    let stage: ConnectionStage
    let pool: TurnPoolSummary?

    /// Узлы резервного пути показываются, только когда маршрут пошёл через него;
    /// «Проверка VK» — только когда она реально была.
    private var visibleNodes: [ConnectionGraphNode] {
        ConnectionGraphNode.allCases.filter { node in
            switch node {
            case .turnTunnel:
                return stage.usesBypassBranch
            case .captcha:
                guard stage.usesBypassBranch else { return false }
                switch stage.state(of: .captcha) {
                case .current, .done, .failed: return true
                case .off, .skipped: return false
                }
            default:
                return true
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(visibleNodes.enumerated()), id: \.element) { index, node in
                nodeRow(node, isFirst: index == 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.10), in: .rect(cornerRadius: 16, style: .continuous))
        .contentShape(.rect(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func nodeRow(_ node: ConnectionGraphNode, isFirst: Bool) -> some View {
        let state = stage.state(of: node)
        let (title, caption) = split(stage.title(of: node, pool: pool))
        return HStack(alignment: .top, spacing: 12) {
            StageDot(style: dotStyle(for: state), size: 9)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 15))
                    .foregroundStyle(titleColor(for: state))
                    .fixedSize(horizontal: false, vertical: true)
                if let caption {
                    Text(caption)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineSpacing(1)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 9)
        // Соединительная линия от предыдущего узла.
        .overlay(alignment: .topLeading) {
            if !isFirst {
                Rectangle()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 1, height: 18)
                    .offset(x: 4, y: -9)
            }
        }
    }

    /// «Узел · подпись» → заголовок и подпись под ним.
    private func split(_ text: String) -> (String, String?) {
        guard let range = text.range(of: " · ") else { return (text, nil) }
        return (String(text[..<range.lowerBound]), String(text[range.upperBound...]))
    }

    private func dotStyle(for state: ConnectionNodeState) -> StageDot.Style {
        switch state {
        case .done: return .reached
        case .current: return .current
        case .failed: return .failed
        case .off, .skipped: return .hollow
        }
    }

    private func titleColor(for state: ConnectionNodeState) -> Color {
        switch state {
        case .failed where stage.lacksBypass || stage.isFailed:
            return TurnStatusPalette.warningText
        case .off, .skipped:
            return .white.opacity(0.55)
        default:
            return .white.opacity(0.88)
        }
    }
}

#if DEBUG
#Preview("Этапы") {
    ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(
                [ConnectionStage.idle, .whitelistCheck, .connectedDirect,
                 .connectedViaTurn(captchaSolved: true),
                 .connectedWithoutTurn(.noVkLink), .connectedWithoutTurn(.captchaFailed),
                 .connectedWithoutTurn(.serverNotCovered), .failed(.turnTimeout)],
                id: \.self
            ) { stage in
                ConnectionGraphSection(stage: stage, serverName: "USA 1")
            }
        }
        .padding(16)
    }
    .background(Color(red: 0.086, green: 0.145, blue: 0.31))
    .colorScheme(.dark)
}
#endif
