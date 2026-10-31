import Foundation
import CryptoKit

/// Apple requests share pacing, cooldown, validated-lifetime caching and in-flight
/// work. This is independent of other providers and never changes app settings.
actor AppStoreHTTPClient: AppStoreResourceClient {
    static let shared = AppStoreHTTPClient()
    struct Policy: Sendable {
        var lookupInterval: TimeInterval = 3.1
        var pageInterval: TimeInterval = 2
        var retryLimit = 1
        var maximumWait: TimeInterval = 15
        var failureCooldown: TimeInterval = 30
        var resourceTimeout: TimeInterval = 20
    }
    private struct Cache: Codable {
        var data: Data
        var headers: [String: String]
        var checkedAt: Date
        var expiresAt: Date
    }
    private struct Flight {
        var id: UUID
        var task: Task<AppStoreHTTPResponse, Error>
        var waiters: Set<UUID>
    }
    private struct Gate { var next = Date.distantPast; var blocked = Date.distantPast; var failure: AppStoreRequestError? }
    private let client: any HTTPResponseClient
    private let directory: URL?
    private let policy: Policy
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var gates: [String: Gate] = [:]
    private var cache: [String: Cache] = [:]
    private var flights: [String: Flight] = [:]

    init(client: any HTTPResponseClient = NetworkClient(),
         directory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("UpPear/AppStore"),
         policy: Policy = Policy(), now: @escaping @Sendable () -> Date = { Date() },
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
             try await Task.sleep(for: .seconds(max(0, $0)))
         }) {
        self.client = client; self.directory = directory; self.policy = policy; self.now = now; self.sleep = sleep
    }

    func fetch(_ request: URLRequest) async throws -> Data {
        try AppStoreResource.requireSuccess(await resource(request, context: "default", maxAge: 900, refresh: false))
    }

    func resource(_ request: URLRequest, context: String, maxAge: TimeInterval, refresh: Bool) async throws -> AppStoreHTTPResponse {
        try Task.checkCancellation()
        guard let url = request.url, url.scheme == "https", ["itunes.apple.com", "apps.apple.com"].contains(url.host),
              url.user == nil, url.password == nil, url.fragment == nil else { throw CheckError.invalidResponse }
        let key = Self.key(request, context: context)
        if !refresh, let stored = cached(key), stored.checkedAt <= now(), stored.expiresAt > now(),
           now().timeIntervalSince(stored.checkedAt) < maxAge {
            return .init(payload: .init(data: stored.data, status: 200, headers: stored.headers), checkedAt: stored.checkedAt, isCached: true)
        }
        let waiter = UUID(), task: Task<AppStoreHTTPResponse, Error>, flightID: UUID
        if var flight = flights[key] {
            flight.waiters.insert(waiter); flights[key] = flight; task = flight.task; flightID = flight.id
        } else {
            flightID = UUID()
            task = Task { try await self.perform(request, key: key, maxAge: maxAge) }
            flights[key] = Flight(id: flightID, task: task, waiters: [waiter])
        }
        return try await withTaskCancellationHandler {
            defer { finished(key: key, id: flightID, waiter: waiter) }
            let response = try await task.value
            try Task.checkCancellation()
            return response
        } onCancel: {
            Task { await self.cancel(key: key, id: flightID, waiter: waiter) }
        }
    }

    func invalidate(_ request: URLRequest, context: String) {
        let key = Self.key(request, context: context); cache.removeValue(forKey: key)
        if let directory { try? FileManager.default.removeItem(at: directory.appendingPathComponent(key + ".json")) }
    }

    func seed(_ request: URLRequest, context: String, data: Data, checkedAt: Date) {
        guard data.count <= 6_000_000 else { return }
        let key = Self.key(request, context: context)
        let value = Cache(data: data, headers: [:], checkedAt: checkedAt, expiresAt: checkedAt.addingTimeInterval(900))
        cache[key] = value; save(value, key: key)
    }

    private func perform(_ request: URLRequest, key: String, maxAge: TimeInterval) async throws -> AppStoreHTTPResponse {
        let host = request.url!.host!
        for attempt in 0...policy.retryLimit {
            try Task.checkCancellation()
            try await acquire(host)
            let payload: HTTPPayload
            do { payload = try await Self.response(request, client: client, timeout: policy.resourceTimeout) }
            catch {
                try Task.checkCancellation()
                if attempt < policy.retryLimit { try await sleep(1); continue }
                var gate = gates[host] ?? Gate()
                gate.blocked = now().addingTimeInterval(policy.failureCooldown)
                gate.failure = .init(retryAt: gate.blocked, message: "商店网络查询失败，请重试。")
                gates[host] = gate
                throw error
            }
            try Task.checkCancellation()
            guard payload.data.count <= 6_000_000 else { throw CheckError.invalidResponse }
            let date = now()
            if payload.status == 429 {
                let until = Self.retryDate(payload.headers["retry-after"], now: date) ?? date.addingTimeInterval(6)
                var gate = gates[host] ?? Gate(); gate.blocked = max(gate.blocked, until); gates[host] = gate
                if attempt < policy.retryLimit, until.timeIntervalSince(date) <= policy.maximumWait { continue }
                gate.blocked = max(gate.blocked, date.addingTimeInterval(policy.failureCooldown))
                gate.failure = .init(status: 429, retryAt: gate.blocked); gates[host] = gate
            } else if (500...599).contains(payload.status), attempt < policy.retryLimit {
                try await sleep(1); continue
            }
            if (500...599).contains(payload.status) {
                var gate = gates[host] ?? Gate(); gate.blocked = date.addingTimeInterval(policy.failureCooldown)
                gate.failure = .init(status: payload.status, retryAt: gate.blocked); gates[host] = gate
            }
            if payload.status == 200, maxAge > 0 {
                var lifetime = maxAge
                if let object = try? JSONSerialization.jsonObject(with: payload.data) as? [String: Any], object["resultCount"] as? Int == 0 {
                    lifetime = min(lifetime, 60)
                }
                let headers = payload.headers.filter { ["cache-control", "date", "etag", "last-modified", "age"].contains($0.key) }
                let stored = Cache(data: payload.data, headers: headers, checkedAt: date, expiresAt: date.addingTimeInterval(lifetime))
                cache[key] = stored; save(stored, key: key)
            }
            let retryAt = payload.status >= 400 ? gates[host]?.failure?.retryAt : nil
            return .init(payload: payload, checkedAt: date, isCached: false, retryAt: retryAt)
        }
        throw CheckError.invalidResponse
    }

    private static func response(_ request: URLRequest, client: any HTTPResponseClient, timeout: TimeInterval) async throws -> HTTPPayload {
        try await withThrowingTaskGroup(of: HTTPPayload.self) { group in
            group.addTask { try await client.response(request) }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw CheckError.timedOut
            }
            defer { group.cancelAll() }
            guard let response = try await group.next() else { throw CheckError.invalidResponse }
            return response
        }
    }

    private func acquire(_ host: String) async throws {
        while true {
            try Task.checkCancellation()
            let gate = gates[host] ?? Gate(), date = now(), allowed = max(gate.next, gate.blocked)
            let wait = allowed.timeIntervalSince(date)
            if wait <= 0 {
                var next = gate
                next.next = date.addingTimeInterval(host == "itunes.apple.com" ? policy.lookupInterval : policy.pageInterval)
                gates[host] = next; return
            }
            guard wait <= policy.maximumWait else { throw gate.failure ?? AppStoreRequestError(status: 429, retryAt: allowed) }
            try await sleep(wait)
        }
    }

    private func finished(key: String, id: UUID, waiter: UUID) {
        guard var flight = flights[key], flight.id == id else { return }
        flight.waiters.remove(waiter)
        if flight.waiters.isEmpty { flights.removeValue(forKey: key) }
        else { flights[key] = flight }
    }
    private func cancel(key: String, id: UUID, waiter: UUID) {
        guard var flight = flights[key], flight.id == id else { return }
        flight.waiters.remove(waiter)
        if flight.waiters.isEmpty { flight.task.cancel(); flights.removeValue(forKey: key) }
        else { flights[key] = flight }
    }
    private static func key(_ request: URLRequest, context: String) -> String {
        SHA256.hash(data: Data(((request.url?.absoluteString ?? "") + "\n" + context).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func cached(_ key: String) -> Cache? {
        if let stored = cache[key] { return stored }
        guard let directory else { return nil }
        let url = directory.appendingPathComponent(key + ".json")
        guard ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max) <= 8_100_000,
              let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode(Cache.self, from: data),
              stored.data.count <= 6_000_000 else { return nil }
        cache[key] = stored; return stored
    }
    private func save(_ stored: Cache, key: String) {
        if cache.count > 64 {
            let victims = cache.sorted { $0.value.checkedAt < $1.value.checkedAt }.prefix(cache.count - 64)
            for (key, _) in victims {
                cache.removeValue(forKey: key)
                if let directory { try? FileManager.default.removeItem(at: directory.appendingPathComponent(key + ".json")) }
            }
        }
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(stored) { try? data.write(to: directory.appendingPathComponent(key + ".json"), options: .atomic) }
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let entries = files.filter { $0.pathExtension == "json" && $0.deletingPathExtension().lastPathComponent.count == 64 }
                .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                    < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            for file in entries.prefix(max(0, entries.count - 64)) { try? FileManager.default.removeItem(at: file) }
        }
    }
    static func retryDate(_ value: String?, now: Date) -> Date? {
        guard let value else { return nil }
        if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 { return now.addingTimeInterval(min(seconds, 86400)) }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return formatter.date(from: value)
    }
}
