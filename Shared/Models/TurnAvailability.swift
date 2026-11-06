//
//  TurnAvailability.swift
//  Anywhere
//
//  Статус резервного пути (TURN) у подписки и причины, по которым им нельзя
//  воспользоваться. В интерфейсе это «резервный путь», слово TURN не показывается.
//

import Foundation

/// Почему резервным путём сейчас воспользоваться нельзя.
nonisolated enum TurnUnavailableReason: String, Codable, Sendable, CaseIterable, Hashable {
    /// Запрос настроек упал (сеть, таймаут, 5xx), а сохранённых настроек нет.
    case loadFailed
    /// Сервер не знает подписку (404).
    case subscriptionNotFound
    /// Настройки пришли, но без ссылки на звонок VK, а она обязательна.
    case noVkLink
    /// VK отклонил ссылку. Ядро пока не отличает это от прочих сбоев, поэтому
    /// на iOS не выставляется — оставлено для совместимости с Android и сервером.
    case linkRejected
    /// Проверка VK («я не робот») не пройдена за отведённое время.
    case captchaFailed
    /// Туннель не поднялся за отведённое время по иной причине.
    case runtimeFailed
    /// Режим резервного пути «Выкл», а он понадобился.
    case disabledInSettings
    /// У подписки резервный путь есть, но не для выбранного сервера. Не тревога.
    case serverNotCovered

    /// Красное ли состояние. «У сервера нет» — не поломка, а выбор сервера.
    var isAlarming: Bool { self != .serverNotCovered }

    /// Причина относится к подписке целиком и красит её иконку.
    var marksSubscription: Bool {
        switch self {
        case .loadFailed, .subscriptionNotFound, .noVkLink, .linkRejected: return true
        default: return false
        }
    }

    /// Свёрнутая строка графа.
    func rowText(serverName: String?) -> String {
        switch self {
        case .loadFailed:
            return String(localized: "turn.reason.loadFailed.row", defaultValue: "Backup route settings failed to load", comment: "Строка графа: настройки резервного пути не загрузились")
        case .subscriptionNotFound:
            return String(localized: "turn.reason.notFound.row", defaultValue: "Subscription not found", comment: "Строка графа: подписка не найдена")
        case .noVkLink:
            return String(localized: "turn.reason.noVkLink.row", defaultValue: "No VK call link", comment: "Строка графа: нет ссылки на звонок VK")
        case .linkRejected:
            return String(localized: "turn.reason.linkRejected.row", defaultValue: "VK call link has expired", comment: "Строка графа: ссылка на звонок VK устарела")
        case .captchaFailed:
            return String(localized: "turn.reason.captchaFailed.row", defaultValue: "VK check was not passed", comment: "Строка графа: не удалось пройти проверку VK")
        case .runtimeFailed:
            return String(localized: "turn.reason.runtimeFailed.row", defaultValue: "Backup route did not start", comment: "Строка графа: резервный путь не поднялся")
        case .disabledInSettings:
            return String(localized: "turn.reason.disabled.row", defaultValue: "Backup route is turned off in Settings", comment: "Строка графа: резервный путь отключён в настройках")
        case .serverNotCovered:
            let name = serverName ?? ""
            return String(localized: "turn.reason.serverNotCovered.row", defaultValue: "\(name) has no backup route — choose another server", comment: "Строка графа: у выбранного сервера нет резервного пути (имя сервера)")
        }
    }

    /// Подпись узла «Резервный путь» в развёрнутом графе.
    var nodeText: String {
        switch self {
        case .loadFailed:
            return String(localized: "turn.reason.loadFailed.node", defaultValue: "Not loaded · update the subscription ↻", comment: "Узел графа: настройки не загрузились")
        case .subscriptionNotFound:
            return String(localized: "turn.reason.notFound.node", defaultValue: "Subscription not found · renew it in the bot", comment: "Узел графа: подписка не найдена")
        case .noVkLink:
            return String(localized: "turn.reason.noVkLink.node", defaultValue: "No VK call link · contact support", comment: "Узел графа: нет ссылки на звонок VK")
        case .linkRejected:
            return String(localized: "turn.reason.linkRejected.node", defaultValue: "Link expired · update the subscription ↻", comment: "Узел графа: ссылка устарела")
        case .captchaFailed:
            return String(localized: "turn.reason.captchaFailed.node", defaultValue: "VK check not passed · connect again", comment: "Узел графа: проверка VK не пройдена")
        case .runtimeFailed:
            return String(localized: "turn.reason.runtimeFailed.node", defaultValue: "Did not start · connect again", comment: "Узел графа: резервный путь не поднялся")
        case .disabledInSettings:
            return String(localized: "turn.reason.disabled.node", defaultValue: "Turned off in Settings", comment: "Узел графа: отключён в настройках")
        case .serverNotCovered:
            return String(localized: "turn.reason.serverNotCovered.node", defaultValue: "Not on this server · choose one with a backup route", comment: "Узел графа: у сервера нет резервного пути")
        }
    }

    /// Поповер у иконки подписки: заголовок и пояснение. `nil` — у причины поповера нет.
    var popover: (title: String, message: String)? {
        switch self {
        case .loadFailed:
            return (
                String(localized: "turn.reason.loadFailed.title", defaultValue: "Backup route settings failed to load", comment: "Поповер: заголовок"),
                String(localized: "turn.reason.loadFailed.message", defaultValue: "The server did not respond. Check your internet connection and update the subscription ↻.", comment: "Поповер: текст")
            )
        case .subscriptionNotFound:
            return (
                String(localized: "turn.reason.notFound.title", defaultValue: "Subscription not found", comment: "Поповер: заголовок"),
                String(localized: "turn.reason.notFound.message", defaultValue: "It may have expired or been deleted. Renew it in the bot and update ↻.", comment: "Поповер: текст")
            )
        case .noVkLink:
            return (
                String(localized: "turn.reason.noVkLink.title", defaultValue: "No VK call link", comment: "Поповер: заголовок"),
                String(localized: "turn.reason.noVkLink.message", defaultValue: "The backup route does not work without it. Update the subscription ↻; if that does not help, contact support.", comment: "Поповер: текст")
            )
        case .linkRejected:
            return (
                String(localized: "turn.reason.linkRejected.title", defaultValue: "VK call link has expired", comment: "Поповер: заголовок"),
                String(localized: "turn.reason.linkRejected.message", defaultValue: "Update the subscription ↻ to get a new one.", comment: "Поповер: текст")
            )
        case .captchaFailed, .runtimeFailed, .disabledInSettings, .serverNotCovered:
            return nil
        }
    }
}

/// Состояние иконки у имени подписки.
nonisolated enum TurnAvailability: Codable, Sendable, Hashable {
    /// У подписки есть резервный путь хотя бы для одного сервера.
    case available
    /// Сервер ответил, что у подписки резервного пути нет. Не `none`: с опциональным
    /// типом `.none` читался бы как `nil`.
    case absent
    /// Резервный путь должен быть, но им нельзя воспользоваться.
    case error(TurnUnavailableReason)
}

/// Чем закончился запрос `<подписка>/turn`.
nonisolated enum TurnFetchOutcome: Sendable, Hashable {
    /// 2xx. `nil` — блока `turn` в ответе нет (у подписки резервного пути нет).
    case loaded(TurnMetadata?)
    /// 404: подписки нет.
    case notFound
    /// Сеть, таймаут, иной HTTP-код, или у подписки нет адреса `/turn`.
    case failed
}

/// Чистые функции: что показать и что сохранить. Без зависимостей от хранилищ.
nonisolated enum TurnAvailabilityPolicy {

    /// Состояние подписки по исходу запроса и уже сохранённым настройкам.
    ///
    /// - Returns: состояние иконки и метаданные, которые нужно сохранить
    ///   (`keep` — оставить сохранённые как есть).
    static func resolve(
        outcome: TurnFetchOutcome,
        previous: TurnMetadata?,
        hasManualVKLink: Bool
    ) -> (availability: TurnAvailability, store: MetadataUpdate) {
        switch outcome {
        case .loaded(let metadata?):
            return (availability(of: metadata, hasManualVKLink: hasManualVKLink), .set(metadata))
        case .loaded(nil):
            return (.absent, .set(nil))
        case .notFound:
            return (.error(.subscriptionNotFound), .keep)
        case .failed:
            // Сохранённые настройки рабочие: сбой загрузки не повод их терять.
            if let previous {
                return (availability(of: previous, hasManualVKLink: hasManualVKLink), .keep)
            }
            return (.error(.loadFailed), .keep)
        }
    }

    /// Что делать с сохранёнными метаданными подписки.
    nonisolated enum MetadataUpdate: Sendable, Hashable {
        case keep
        case set(TurnMetadata?)
    }

    static func availability(of metadata: TurnMetadata, hasManualVKLink: Bool) -> TurnAvailability {
        let link = metadata.vkLink?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if link.isEmpty, metadata.vkLinkRequired != false, !hasManualVKLink {
            return .error(.noVkLink)
        }
        return .available
    }

    /// Почему выбранным сервером нельзя пойти резервным путём, когда он понадобился.
    /// `nil` — можно (или резервного пути у подписки нет вовсе и подключение идёт
    /// напрямую без тревоги, как раньше).
    ///
    /// - Parameters:
    ///   - mode: действующий режим; `nil` — фича выключена целиком.
    ///   - forced: сессия принудительно через резервный путь (удержание кнопки).
    ///   - availability: состояние подписки выбранного сервера; `nil` — неизвестно.
    ///   - metadata: сохранённые метаданные этой подписки.
    ///   - serverHost: адрес выбранного сервера.
    ///   - hasVKLink: есть ли ссылка на звонок (из подписки или введённая вручную).
    static func connectionReason(
        mode: TurnMode?,
        forced: Bool,
        availability: TurnAvailability?,
        metadata: TurnMetadata?,
        serverHost: String,
        hasVKLink: Bool
    ) -> TurnUnavailableReason? {
        if !forced {
            guard let mode else { return nil }
            if mode == .off { return .disabledInSettings }
        }
        switch availability {
        case .error(let reason)?:
            return reason
        case .absent?:
            // У подписки резервного пути нет — подключались напрямую и раньше. Тревожим
            // только когда его явно потребовали.
            return (forced || mode == .on) ? .serverNotCovered : nil
        case .available?, nil:
            break
        }
        guard let metadata else {
            return (forced || mode == .on) ? .serverNotCovered : nil
        }
        guard let server = metadata.server(for: serverHost), server.isUsable else {
            return .serverNotCovered
        }
        if !hasVKLink { return .noVkLink }
        return nil
    }

    /// Причина, которую ставит сторожок, когда резервный путь не поднялся вовремя.
    static func runtimeReason(inCaptcha: Bool) -> TurnUnavailableReason {
        inCaptcha ? .captchaFailed : .runtimeFailed
    }

    /// Показывать ли маленькую арку у серверов: только если резервный путь есть не у всех.
    static func marksServers(hosts: [String], metadata: TurnMetadata?) -> Set<String> {
        guard let metadata else { return [] }
        let covered = Set(hosts.filter { metadata.server(for: $0)?.isUsable == true })
        guard !covered.isEmpty, covered.count < Set(hosts).count else { return [] }
        return covered
    }
}
