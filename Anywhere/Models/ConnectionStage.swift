//
//  ConnectionStage.swift
//  Anywhere
//
//  Модель этапов подключения для графа на главном экране.
//  Спека: design for anywhere/SPEC.md, разделы 3 и 4.
//
//  Алгоритм подключения:
//    проверка сети → подключение к VPN → проверка белых списков
//      ├─ обхода не нужно  → работаем через VPN                    (прямой ствол)
//      └─ идём в обход     → открываем TURN-туннель → капча (если TURN её просит)
//                            → работаем через VPN                  (ветка обхода)
//

import Foundation

// MARK: - Узлы графа

/// Узел графа подключения. `rawValue` — порядковый номер по маршруту,
/// на нём держится вся логика «пройден / текущий».
nonisolated enum ConnectionGraphNode: Int, CaseIterable, Identifiable, Sendable {
    case networkCheck = 1   // Проверка сети
    case vpnConnect         // Подключение к VPN
    case whitelistCheck     // Проверка белых списков — точка ветвления
    case turnTunnel         // Открытие TURN-туннеля  — ветка обхода
    case captcha            // Решение капчи          — ветка обхода, необязательный
    case connected          // Подключено             — мерж

    var id: Int { rawValue }

    /// Узлы обхода блокировки. Ствол — все остальные.
    var isOnBypassBranch: Bool {
        self == .turnTunnel || self == .captcha
    }

    var title: String {
        switch self {
        case .networkCheck:
            return String(localized: "graph.node.networkCheck", defaultValue: "Checking Network", comment: "Узел графа: есть ли сеть")
        case .vpnConnect:
            return String(localized: "graph.node.vpnConnect", defaultValue: "Connecting to VPN", comment: "Узел графа: поднятие VPN")
        case .whitelistCheck:
            return String(localized: "graph.node.whitelistCheck", defaultValue: "Checking Restrictions", comment: "Узел графа: проба на блокировку")
        case .turnTunnel:
            return String(localized: "graph.node.turnTunnel", defaultValue: "Opening TURN Tunnel", comment: "Узел графа: обход через TURN")
        case .captcha:
            return String(localized: "graph.node.captcha", defaultValue: "Solving Captcha", comment: "Узел графа: капча VK")
        case .connected:
            return String(localized: "graph.node.connected", defaultValue: "Connected", comment: "Узел графа: соединение установлено")
        }
    }
}

/// Состояние отдельного узла.
nonisolated enum ConnectionNodeState: Sendable {
    case off        // не пройден
    case done       // пройден
    case current    // на нём стоим сейчас
    case skipped    // маршрут прошёл через узел, но шаг не потребовался (капча)
    case failed     // на этом узле всё встало
}

// MARK: - Провал этапа

/// Причина, по которой подключение встало.
///
/// Намеренно без ассоциированных значений: тип участвует в `Hashable`-сравнении
/// `ConnectionStage`, а строка в кейсе заставляла бы `animation(value:)`
/// и `onChange` дёргаться на каждом обновлении текста.
nonisolated enum ConnectionFailure: Sendable, Hashable, CaseIterable {
    /// Прифлайт не нашёл сети — туннель даже не запускали.
    case noNetwork
    /// `startVPNTunnel` не поднял туннель.
    case vpnStartFailed
    /// Туннель поднялся, но проба из расширения не достала ничего.
    case networkLost
    /// TURN-туннель не собрался за отведённое время.
    case turnTimeout
    /// Капча не решилась за отведённое время.
    case captchaTimeout

    /// Узел, который красится в красный.
    var node: ConnectionGraphNode {
        switch self {
        case .noNetwork:      return .networkCheck
        case .vpnStartFailed: return .vpnConnect
        case .networkLost:    return .whitelistCheck
        case .turnTimeout:    return .turnTunnel
        case .captchaTimeout: return .captcha
        }
    }

    /// Текст для алерта и для свёрнутой строки графа.
    var message: String {
        switch self {
        case .noNetwork:
            return String(localized: "vpn.error.noInternet", defaultValue: "No internet connection. Check your network and try again.")
        case .vpnStartFailed:
            return String(localized: "graph.error.vpnStart", defaultValue: "The VPN could not be started.", comment: "Ошибка графа: туннель не поднялся")
        case .networkLost:
            return String(localized: "graph.error.networkLost", defaultValue: "The network became unreachable after the VPN started.", comment: "Ошибка графа: сеть пропала после старта")
        case .turnTimeout:
            return String(localized: "graph.error.turnTimeout", defaultValue: "The TURN tunnel could not be opened. Traffic will use the direct route.", comment: "Ошибка графа: TURN не поднялся")
        case .captchaTimeout:
            return String(localized: "graph.error.captchaTimeout", defaultValue: "The captcha was not solved in time.", comment: "Ошибка графа: капча не решена")
        }
    }
}

// MARK: - Этап

nonisolated enum ConnectionStage: Sendable, Hashable {
    case idle
    case networkCheck
    case vpnConnect
    case whitelistCheck
    case turnTunnel
    case captcha
    /// Идём через обход. `captchaSolved == false` — TURN капчу не запросил,
    /// узел «Решение капчи» пропущен.
    case connectedViaTurn(captchaSolved: Bool)
    /// Обход не понадобился, работаем напрямую через VPN.
    case connectedDirect
    /// Подключение встало на конкретном узле.
    case failed(ConnectionFailure)

    var isConnected: Bool {
        switch self {
        case .connectedViaTurn, .connectedDirect: return true
        default: return false
        }
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    /// Идёт переход — в кнопке питания крутится `ProgressView`.
    var isBusy: Bool {
        self != .idle && !isConnected && !isFailed
    }

    /// Маршрут пошёл (или идёт) в обход блокировки.
    var usesBypassBranch: Bool {
        switch self {
        case .turnTunnel, .captcha, .connectedViaTurn: return true
        case .failed(let failure):                     return failure.node.isOnBypassBranch
        default:                                       return false
        }
    }

    /// Узел, на котором стоим. `nil` в состоянии покоя.
    var currentNode: ConnectionGraphNode? {
        switch self {
        case .idle:              return nil
        case .networkCheck:      return .networkCheck
        case .vpnConnect:        return .vpnConnect
        case .whitelistCheck:    return .whitelistCheck
        case .turnTunnel:        return .turnTunnel
        case .captcha:           return .captcha
        case .connectedViaTurn,
             .connectedDirect:   return .connected
        case .failed(let failure): return failure.node
        }
    }

    /// Узел зелёный: он текущий либо уже пройден.
    ///
    /// Прямое подключение перепрыгивает ветку обхода — узлы 4–5 остаются серыми,
    /// хотя «Подключено» уже зелёное.
    func isReached(_ node: ConnectionGraphNode) -> Bool {
        if self == .connectedDirect {
            return !node.isOnBypassBranch
        }
        guard let current = currentNode else { return false }
        return node.rawValue <= current.rawValue
    }

    func state(of node: ConnectionGraphNode) -> ConnectionNodeState {
        if case .failed(let failure) = self, node == failure.node {
            return .failed
        }
        if case .connectedViaTurn(let solved) = self, node == .captcha, !solved {
            return .skipped
        }
        if currentNode == node { return .current }
        return isReached(node) ? .done : .off
    }

    /// Ребро зелёное, когда зелёные оба его конца.
    ///
    /// Прямой ствол «Проверка белых списков → Подключено» — исключение: он зеленеет
    /// только когда обход не понадобился. Если пошли в обход, ствол остаётся
    /// серым, хотя оба его конца зелёные: маршрут по нему не шёл.
    func isEdgeTraversed(from: ConnectionGraphNode, to: ConnectionGraphNode) -> Bool {
        if from == .whitelistCheck && to == .connected {
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

    /// Маршрут, по которому идёт (или пойдёт) трафик.
    nonisolated enum Route: Sendable {
        case direct
        case turn
        /// Режим `.auto`, проба ещё не решила.
        case undecided
    }

    /// Маршрут определяется настройкой; в `.auto` — решением пробы.
    ///
    /// - Parameters:
    ///   - turnMode: `nil` — фича обхода выключена целиком.
    static func route(turnMode: TurnMode?, autoDecision: TurnAutoState.Decision?) -> Route {
        guard let turnMode else { return .direct }
        switch turnMode {
        case .off: return .direct
        case .on:  return .turn
        case .auto:
            switch autoDecision {
            case .turn:               return .turn
            // `.offline` — обход не поможет, флоу пускают напрямую.
            case .direct, .offline:   return .direct
            case .undecided, .none:   return .undecided
            }
        }
    }

    /// Единственная точка, где из состояния приложения получается этап для графа.
    ///
    /// - Parameters:
    ///   - status: `VPNViewModel.status` (не `vpnStatus` — тот `NEVPNStatus`).
    ///   - isPreflighting: идёт прифлайт-проба перед стартом туннеля.
    ///   - turnMode: режим обхода; `nil`, когда фича выключена.
    ///   - autoDecision: решение пробы в режиме `.auto`; `nil` в `.on`/`.off`.
    ///   - turnPhase: фаза от Go-ядра; `nil`, пока пула нет.
    ///   - captchaPending: `TurnCaptchaMonitor.captchaWaiting`.
    ///   - captchaSeen: за эту сессию капчу действительно показывали.
    ///     `false` на маршруте обхода означает «капча не потребовалась».
    ///   - failure: провал, если он уже зафиксирован.
    static func resolve(
        status: VPNStatus,
        isPreflighting: Bool,
        turnMode: TurnMode?,
        autoDecision: TurnAutoState.Decision?,
        turnPhase: TurnPhase?,
        captchaPending: Bool,
        captchaSeen: Bool,
        failure: ConnectionFailure?
    ) -> ConnectionStage {

        // Провал перебивает всё: он живёт дольше статуса, который его вызвал.
        if let failure { return .failed(failure) }

        // Туннель стоит, но сеть за ним не отвечает — это не «подключено».
        if turnMode == .auto, autoDecision == .offline, status == .connected {
            return .failed(.networkLost)
        }

        // Прифлайт идёт до старта туннеля, статус в этот момент ещё `.disconnected`.
        if isPreflighting { return .networkCheck }

        switch status {
        case .disconnected, .invalid, .disconnecting:
            return .idle
        case .connecting, .reasserting:
            return .vpnConnect
        case .connected:
            break
        }

        // Расширение возвращает `startTunnel` рано: узлы 3–5 проходятся уже
        // после того, как система сообщила `.connected`.
        switch route(turnMode: turnMode, autoDecision: autoDecision) {
        case .direct:
            return .connectedDirect
        case .undecided:
            return .whitelistCheck
        case .turn:
            if captchaPending { return .captcha }
            switch turnPhase {
            case .captchaAuto, .captchaWait:
                return .captcha
            case .ready:
                return .connectedViaTurn(captchaSolved: captchaSeen)
            default:
                return .turnTunnel
            }
        }
    }
}
