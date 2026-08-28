//
//  ConnectionStage.swift
//  Anywhere
//
//  Модель этапов подключения для графа на главном экране.
//  Спека: design for anywhere/SPEC.md, разделы 3 и 4.
//

import Foundation

// MARK: - Узлы графа

/// Узел графа подключения. `rawValue` — порядковый номер по маршруту,
/// на нём держится вся логика «пройден / текущий».
nonisolated enum ConnectionGraphNode: Int, CaseIterable, Identifiable, Sendable {
    case connect = 1        // Подключение
    case vpnSetup           // Настройка VPN     — точка ветвления
    case vkAccess           // Доступ к VK       — ветка VK TURN
    case captcha            // Решение капчи     — ветка VK TURN
    case tunnelSetup        // Настройка туннеля — ветка VK TURN
    case connected          // Подключено        — мерж

    var id: Int { rawValue }

    /// Узлы обхода через VK TURN. Ствол — все остальные.
    var isOnTurnBranch: Bool {
        self == .vkAccess || self == .captcha || self == .tunnelSetup
    }

    var title: String {
        switch self {
        case .connect:     return String(localized: "graph.node.connect", defaultValue: "Connecting", comment: "Узел графа: старт подключения")
        case .vpnSetup:    return String(localized: "graph.node.vpnSetup", defaultValue: "VPN Setup", comment: "Узел графа: поднятие VPN-профиля")
        case .vkAccess:    return String(localized: "graph.node.vkAccess", defaultValue: "VK Access", comment: "Узел графа: получение VK-креды для TURN")
        case .captcha:     return String(localized: "graph.node.captcha", defaultValue: "Solving Captcha", comment: "Узел графа: капча VK")
        case .tunnelSetup: return String(localized: "graph.node.tunnelSetup", defaultValue: "Tunnel Setup", comment: "Узел графа: поднятие TURN-туннеля")
        case .connected:   return String(localized: "graph.node.connected", defaultValue: "Connected", comment: "Узел графа: соединение установлено")
        }
    }
}

/// Состояние отдельного узла.
nonisolated enum ConnectionNodeState: Sendable {
    case off       // не пройден
    case done      // пройден
    case current   // на нём стоим сейчас
}

// MARK: - Этап

nonisolated enum ConnectionStage: Sendable, Hashable {
    case idle
    case connecting
    case vpnSetup
    case vkAccess
    case captcha
    case tunnelSetup
    case connectedViaTurn
    case connectedDirect

    /// Соединение установлено — экран красится в «подключённый» градиент.
    var isConnected: Bool {
        self == .connectedViaTurn || self == .connectedDirect
    }

    /// Идёт переход — в кнопке питания крутится `ProgressView`.
    var isBusy: Bool {
        self != .idle && !isConnected
    }

    /// Маршрут прошёл (или проходит) через обход VK TURN.
    var usesTurnBranch: Bool {
        switch self {
        case .vkAccess, .captcha, .tunnelSetup, .connectedViaTurn: return true
        default: return false
        }
    }

    /// Узел, на котором стоим. `nil` в состоянии покоя.
    var currentNode: ConnectionGraphNode? {
        switch self {
        case .idle:             return nil
        case .connecting:       return .connect
        case .vpnSetup:         return .vpnSetup
        case .vkAccess:         return .vkAccess
        case .captcha:          return .captcha
        case .tunnelSetup:      return .tunnelSetup
        case .connectedViaTurn,
             .connectedDirect:  return .connected
        }
    }

    /// Узел зелёный: он текущий либо уже пройден.
    ///
    /// Прямое подключение перепрыгивает всю ветку — узлы 3–5 остаются серыми,
    /// хотя «Подключено» уже зелёное.
    func isReached(_ node: ConnectionGraphNode) -> Bool {
        if self == .connectedDirect {
            return !node.isOnTurnBranch
        }
        guard let current = currentNode else { return false }
        return node.rawValue <= current.rawValue
    }

    func state(of node: ConnectionGraphNode) -> ConnectionNodeState {
        if currentNode == node { return .current }
        return isReached(node) ? .done : .off
    }

    /// Ребро зелёное, когда зелёные оба его конца.
    ///
    /// Прямой ствол «Настройка VPN → Подключено» — исключение: он зеленеет
    /// только при подключении без TURN, потому что при обходе маршрут по нему не шёл.
    func isEdgeTraversed(from: ConnectionGraphNode, to: ConnectionGraphNode) -> Bool {
        if from == .vpnSetup && to == .connected {
            return self == .connectedDirect
        }
        return isReached(from) && isReached(to)
    }

    /// Текст под кнопкой питания — берётся из существующего `VPNStatus`.
    var statusText: String {
        if isConnected { return VPNStatus.connected.localizedText }
        if isBusy { return VPNStatus.connecting.localizedText }
        return VPNStatus.disconnected.localizedText
    }
}

// MARK: - Фаза TURN, приходящая из расширения

/// Фаза обхода, которую сообщает Go-ядро vk-turn через IPC расширения.
///
/// Значения повторяют `clientcore.Phase` один в один — менять нумерацию нельзя.
nonisolated enum TurnPhase: Int, Sendable {
    case inactive = 0   // обход не используется
    case vkAccess       // тянем VK-креды по vk_link
    case captchaAuto    // капча решается автоматически
    case captchaWait    // капча ждёт пользователя
    case tunnelSetup    // allocate + поднятие пула стримов
    case ready          // туннель поднят
}

// MARK: - Сборка этапа из сигналов приложения

extension ConnectionStage {

    /// Единственная точка, где из состояния приложения получается этап для графа.
    ///
    /// - Parameters:
    ///   - status: `VPNViewModel.vpnStatus`.
    ///   - turnEnabled: TURN участвует в этом подключении — фича включена и режим не `.off`
    ///     (в режиме `.auto` — по факту решения автопилота).
    ///   - turnPhase: фаза от расширения; `nil`, пока ядро её не отдаёт.
    ///   - captchaPending: `TurnCaptchaMonitor.shared.showCaptcha`.
    ///   - vpnProfileUp: профиль поднят, идёт установка соединения.
    ///     Если такого сигнала нет — передавай `false`, узел «Настройка VPN»
    ///     тогда загорится вместе с фазой TURN или по факту подключения.
    static func resolve(
        status: VPNStatus,
        turnEnabled: Bool,
        turnPhase: TurnPhase?,
        captchaPending: Bool,
        vpnProfileUp: Bool
    ) -> ConnectionStage {

        switch status {
        case .connected:
            guard turnEnabled else { return .connectedDirect }
            // Капча важнее статуса: туннель поднят, но обход ещё не работает.
            if captchaPending { return .captcha }
            if let phase = turnPhase {
                switch phase {
                case .inactive:     return .connectedViaTurn
                case .vkAccess:     return .vkAccess
                case .captchaAuto,
                     .captchaWait:  return .captcha
                case .tunnelSetup:  return .tunnelSetup
                case .ready:        return .connectedViaTurn
                }
            }
            // Фазы ещё нет: туннель поднят, но обход своего пула пока не собрал.
            return .tunnelSetup

        case .disconnected, .invalid, .disconnecting:
            return .idle

        case .connecting, .reasserting:
            break
        }

        // Идёт подключение.
        guard turnEnabled else {
            return vpnProfileUp ? .vpnSetup : .connecting
        }

        if let phase = turnPhase {
            switch phase {
            case .inactive:     return vpnProfileUp ? .vpnSetup : .connecting
            case .vkAccess:     return .vkAccess
            case .captchaAuto,
                 .captchaWait:  return .captcha
            case .tunnelSetup:  return .tunnelSetup
            case .ready:        return .tunnelSetup   // ждём, пока поднимется сам VPN
            }
        }

        // Фазы ещё нет — расширение либо не запущено, либо пул ещё не создан.
        return vpnProfileUp ? .vpnSetup : .connecting
    }
}
