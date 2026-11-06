//
//  SubscriptionFetcher.swift
//  Anywhere
//
//  Created by NodePassProject on 3/1/26.
//

import Foundation

nonisolated struct SubscriptionFetcher {
    struct Result {
        let configurations: [ProxyConfiguration]
        let stableKeys: [UUID: String]
        let name: String?
        let upload: Int64?
        let download: Int64?
        let total: Int64?
        let expire: Date?
        /// TURN relays advertised next to the subscription, fetched separately (see
        /// `fetchTurnEndpoint`). `nil` when the server offers no `turn` block.
        var turn: TurnMetadata? = nil
        /// Revision and push endpoints from the same response. `nil` when the server
        /// offers no `push` block.
        var push: SubscriptionPushInfo? = nil
        /// How the `/turn` request ended — tells «no backup route» apart from «could not
        /// load it» and «subscription not found» for the status icon.
        var turnOutcome: TurnFetchOutcome = .failed
        let iconLight: Data?
        let iconDark: Data?
    }

    static func fetch(url urlString: String) async throws -> Result {
        guard let url = URL(string: urlString) else {
            throw AnywhereError.subscription(.invalidURL)
        }

        var request = URLRequest(url: url)
        request.setValue("Anywhere", forHTTPHeaderField: "User-Agent")
        request.setValue(AJSONParser.formatHeaderValue, forHTTPHeaderField: "X-Anywhere-Format")
        if AWCore.getRemnawaveHWIDEnabled() {
            request.setValue(AWCore.getRemnawaveHWID(), forHTTPHeaderField: "x-hwid")
        }

        let allowInsecure = AWCore.getAllowInsecure()
        let (data, response): (Data, URLResponse)
        do {
            if let viaUpstream = try await fetchViaConfiguredDNS(request, allowInsecure: allowInsecure) {
                (data, response) = viaUpstream
            } else if allowInsecure {
                let session = URLSession(configuration: .default, delegate: InsecureSessionDelegate(), delegateQueue: nil)
                defer { session.finishTasksAndInvalidate() }
                (data, response) = try await session.data(for: request)
            } else {
                (data, response) = try await URLSession.shared.data(for: request)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw error
        } catch {
            throw AnywhereError.subscription(.fetchFailed(underlying: error))
        }

        let httpResponse = response as? HTTPURLResponse

        let profileTitle = parseProfileTitle(from: httpResponse)
        let userInfo = parseSubscriptionUserInfo(from: httpResponse)
        let iconLight = parseIcon(from: httpResponse, field: "aw-icon-light")
        let iconDark = parseIcon(from: httpResponse, field: "aw-icon-dark")

        if let rawString = String(data: data, encoding: .utf8), AJSONParser.looksLikeDocument(rawString) {
            let document = try AJSONParser.parse(rawString)
            guard !document.configurations.isEmpty else {
                throw AnywhereError.subscription(.noConfigurations)
            }
            return Result(
                configurations: document.configurations,
                stableKeys: document.stableKeys,
                name: document.name ?? profileTitle,
                upload: document.upload ?? userInfo.upload,
                download: document.download ?? userInfo.download,
                total: document.total ?? userInfo.total,
                expire: document.expire ?? userInfo.expire,
                iconLight: document.iconLight ?? iconLight,
                iconDark: document.iconDark ?? iconDark
            )
        }

        // Second, optional request for the `turn` and `push` blocks. Never fatal — see
        // fetchTurnEndpoint.
        let (turnOutcome, push) = await fetchTurnEndpoint(url: url, withRemnawaveHWID: AWCore.getRemnawaveHWIDEnabled())
        let turn: TurnMetadata? = if case .loaded(let metadata) = turnOutcome { metadata } else { nil }

        let bodyString: String
        if let decoded = Data(base64Encoded: data, options: .ignoreUnknownCharacters),
           let decodedString = String(data: decoded, encoding: .utf8),
           ProxyConfiguration.subscriptionEntryPrefixes.contains(where: { decodedString.contains($0) }) {
            bodyString = decodedString
        } else if let rawString = String(data: data, encoding: .utf8) {
            bodyString = rawString
        } else {
            throw AnywhereError.subscription(.noConfigurations)
        }

        if bodyString.contains("proxies:") {
            let result = try ClashProxyParser.parse(yaml: bodyString)
            guard !result.configurations.isEmpty else {
                throw AnywhereError.subscription(.noConfigurations)
            }
            return Result(
                configurations: result.configurations,
                stableKeys: [:],
                name: profileTitle,
                upload: userInfo.upload,
                download: userInfo.download,
                total: userInfo.total,
                expire: userInfo.expire,
                turn: turn,
                push: push,
                turnOutcome: turnOutcome,
                iconLight: iconLight,
                iconDark: iconDark
            )
        }

        let configurations = bodyString
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { ProxyConfiguration.canParseSubscriptionEntry($0) }
            .compactMap { try? ProxyConfiguration.parseSubscriptionEntry(url: $0) }

        guard !configurations.isEmpty else {
            throw AnywhereError.subscription(.noConfigurations)
        }

        return Result(
            configurations: configurations,
            stableKeys: [:],
            name: profileTitle,
            upload: userInfo.upload,
            download: userInfo.download,
            total: userInfo.total,
            expire: userInfo.expire,
            turn: turn,
            push: push,
            turnOutcome: turnOutcome,
            iconLight: iconLight,
            iconDark: iconDark
        )
    }

    // MARK: - TURN Metadata and Push

    /// Fetches the `turn` and `push` blocks for a subscription.
    ///
    /// Asks the dedicated `<subscription>/turn` endpoint, served next to the subscription:
    /// it returns `{"turn": {...}, "push": {...}}` with only the user's own relays. There is
    /// deliberately no fallback to the sing-box rendering of the subscription — that one
    /// lists every relay, not just the user's, and sing-box subscriptions are being retired.
    ///
    /// The `push` block (revision + push endpoints) is read even with the TURN feature
    /// off; only the `turn` block is dropped then.
    ///
    /// Entirely best-effort: a non-JSON body, missing blocks, an HTTP error or a dead
    /// network all yield `nil`s, and the subscription is added exactly as before.
    private static func fetchTurnEndpoint(url: URL, withRemnawaveHWID: Bool) async -> (TurnFetchOutcome, SubscriptionPushInfo?) {
        guard let endpoint = turnEndpointURL(for: url) else { return (.failed, nil) }

        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 15
        if withRemnawaveHWID {
            request.setValue(AWCore.getRemnawaveHWID(), forHTTPHeaderField: "x-hwid")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await send(request)
        } catch {
            logger.debug("TURN metadata probe failed: \(error.localizedDescription)")
            return (.failed, nil)
        }
        return outcome(data: data, status: (response as? HTTPURLResponse)?.statusCode)
    }

    /// Classifies a `/turn` response. The `turn` block is kept even with the TURN
    /// feature switched off: a session forced through TURN still needs the relays.
    ///
    /// Only our server answers `/turn` with JSON. A non-JSON answer (an HTML 404 from a
    /// third-party subscription host) means the server knows nothing of a backup route,
    /// which is «none», not a failure; a 5xx or no answer at all is a failure.
    static func outcome(data: Data, status: Int?) -> (TurnFetchOutcome, SubscriptionPushInfo?) {
        let isJSON = (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
        if let status, status >= 500 { return (.failed, nil) }
        if let status, !(200...299).contains(status) {
            if !isJSON { return (.loaded(nil), nil) }
            return (status == 404 ? .notFound : .failed, nil)
        }
        guard isJSON else { return (.loaded(nil), nil) }
        let push = SubscriptionPushInfo.extract(from: data)
        let turn = TurnMetadata.extract(fromSingBoxJSON: data)
        logger.debug("TURN metadata: \(turn?.servers.count ?? 0) server(s), push: \(push != nil)")
        return (.loaded(turn), push)
    }

    /// `https://host/<id>` → `https://host/<id>/turn`; query kept, fragment dropped.
    /// `nil` for anything that is not an http(s) URL with a non-empty path.
    static func turnEndpointURL(for url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else {
            return nil
        }
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        guard !path.isEmpty else { return nil }
        components.percentEncodedPath = path + "/turn"
        components.fragment = nil
        return components.url
    }

    // MARK: - Transport

    /// Performs a request the same way the subscription itself is fetched: through the
    /// configured DNS upstream when one is set, honouring "allow insecure", with the
    /// app's `Anywhere` user agent unless the request sets its own.
    ///
    /// The DNS-upstream path speaks GET only (`ResolvedHostFetcher` writes the request
    /// line itself), so other methods always go through `URLSession`.
    static func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var request = request
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue("Anywhere", forHTTPHeaderField: "User-Agent")
        }
        let allowInsecure = AWCore.getAllowInsecure()
        let isGET = (request.httpMethod ?? "GET").uppercased() == "GET"
        if isGET, let viaUpstream = try await fetchViaConfiguredDNS(request, allowInsecure: allowInsecure) {
            return viaUpstream
        } else if allowInsecure {
            let session = URLSession(configuration: .default, delegate: InsecureSessionDelegate(), delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            return try await session.data(for: request)
        } else {
            return try await URLSession.shared.data(for: request)
        }
    }

    // MARK: - Configured DNS
    
    private static func fetchViaConfiguredDNS(_ request: URLRequest, allowInsecure: Bool) async throws -> (Data, URLResponse)? {
        let upstream = AWCore.getSubscriptionDNSUpstream()
        guard !upstream.isSystem else { return nil }

        let result = try await ResolvedHostFetcher.fetch(request, allowInsecure: allowInsecure) { host in
            try await DNSUpstreamClient.resolve(host, via: upstream).first
        }
        return (result.data, result.response)
    }

    // MARK: - Header Parsing

    private static func parseProfileTitle(from response: HTTPURLResponse?) -> String? {
        guard let value = response?.value(forHTTPHeaderField: "profile-title") else { return nil }
        let decoded: String
        if value.hasPrefix("base64:") {
            let encoded = String(value.dropFirst("base64:".count))
            if let data = Data(base64Encoded: encoded),
               let utf8 = String(data: data, encoding: .utf8) {
                decoded = utf8
            } else {
                decoded = value
            }
        } else {
            decoded = value
        }
        let trimmed = decoded.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : decoded
    }

    private static func parseIcon(from response: HTTPURLResponse?, field: String) -> Data? {
        guard let value = response?.value(forHTTPHeaderField: field) else { return nil }
        return Data(iconBase64: value)
    }

    private static func parseSubscriptionUserInfo(from response: HTTPURLResponse?) -> (upload: Int64?, download: Int64?, total: Int64?, expire: Date?) {
        guard let value = response?.value(forHTTPHeaderField: "subscription-userinfo") else {
            return (nil, nil, nil, nil)
        }

        var upload: Int64?
        var download: Int64?
        var total: Int64?
        var expire: Date?

        // Format: upload=X; download=Y; total=Z; expire=T
        for part in value.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            let keyValue = trimmed.split(separator: "=", maxSplits: 1)
            guard keyValue.count == 2 else { continue }
            let key = keyValue[0].trimmingCharacters(in: .whitespaces)
            let valueString = keyValue[1].trimmingCharacters(in: .whitespaces)

            switch key {
            case "upload":
                upload = Int64(valueString)
            case "download":
                download = Int64(valueString)
            case "total":
                total = Int64(valueString)
            case "expire":
                if let timestamp = TimeInterval(valueString) {
                    expire = Date(timeIntervalSince1970: timestamp)
                }
            default:
                break
            }
        }

        return (upload, download, total, expire)
    }
}

nonisolated private final class InsecureSessionDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            return (.useCredential, URLCredential(trust: trust))
        }
        return (.performDefaultHandling, nil)
    }
}
