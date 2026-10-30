import Foundation
import zlib

// Read-only, anonymous PICS queries over Valve's TLS WebSocket transport.
// Message fields: SteamDatabase/Protobufs, steammessages_{base,clientserver_login,
// clientserver_appinfo}.proto. No account credentials or installed Steam process
// are used, and this client has no content download or installation commands.
protocol SteamCatalogFetching: Sendable {
    func products(appIDs: Set<String>) async throws -> [String: SteamProduct]
}

struct SteamCatalogClient: SteamCatalogFetching {
    var http: any HTTPClient = NetworkClient()

    func products(appIDs: Set<String>) async throws -> [String: SteamProduct] {
        guard !appIDs.isEmpty else { return [:] }
        guard appIDs.count <= 200, appIDs.allSatisfy({ UInt32($0).map { $0 > 0 } == true }) else {
            throw CheckError.invalidResponse
        }
        var request = URLRequest(url: URL(string: "https://api.steampowered.com/ISteamDirectory/GetCMListForConnect/v1/?cellid=0&cmtype=websockets")!)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let data = try await http.fetch(request)
        let endpoints = try Self.endpoints(data)
        var lastError: any Error = CheckError.invalidResponse
        for endpoint in endpoints.prefix(2) {
            try Task.checkCancellation()
            do {
                return try await SteamCMConnection(url: endpoint).products(appIDs: appIDs)
            } catch {
                try Task.checkCancellation()
                lastError = error
            }
        }
        throw lastError
    }

    static func endpoints(_ data: Data) throws -> [URL] {
        guard data.count <= 1_000_000,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = object["response"] as? [String: Any],
              let servers = response["serverlist"] as? [[String: Any]] else { throw CheckError.invalidResponse }
        let urls = servers.compactMap { server -> URL? in
            guard server["type"] as? String == "websockets",
                  let endpoint = server["endpoint"] as? String,
                  let url = URL(string: "wss://" + endpoint + "/cmsocket/"),
                  let host = url.host?.lowercased(), host.hasSuffix(".steamserver.net"),
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  url.path(percentEncoded: false) == "/cmsocket/", let port = url.port,
                  port == 443 || (27000...27100).contains(port) else { return nil }
            return url
        }
        // Port 443 also works on networks that block Steam's other ports.
        let sorted = urls.filter { $0.port == 443 } + urls.filter { $0.port != 443 }
        var seen = Set<URL>()
        let unique = sorted.filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { throw CheckError.invalidResponse }
        return unique
    }
}

private final class SteamCMConnection: Sendable {
    private let session: URLSession
    private let socket: URLSessionWebSocketTask

    init(url: URL) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        session = URLSession(configuration: config)
        socket = session.webSocketTask(with: url)
        socket.maximumMessageSize = SteamWire.maximumSize
    }

    func products(appIDs: Set<String>) async throws -> [String: SteamProduct] {
        defer { socket.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
        return try await withThrowingTaskGroup(of: [String: SteamProduct].self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await self.readProducts(appIDs: appIDs)
                } onCancel: { self.socket.cancel(with: .goingAway, reason: nil) }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(20))
                throw CheckError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CheckError.invalidResponse }
            return result
        }
    }

    private func readProducts(appIDs: Set<String>) async throws -> [String: SteamProduct] {
        socket.resume()
        var steamID: UInt64 = 0x01a0_0000_0000_0000 // Public universe, anonymous user.
        var sessionID: UInt64 = 0
        func send(_ kind: UInt32, _ body: Data, job: UInt64? = nil) async throws {
            var header = SteamProto.fixed64(1, steamID) + SteamProto.integer(2, sessionID)
            if let job { header += SteamProto.fixed64(10, job) }
            try await socket.send(.data(SteamWire.message(kind, header: header, body: body)))
        }
        try await send(9805, SteamProto.integer(1, 65580)) // ClientHello.
        let logon = SteamProto.integer(1, 65580) + SteamProto.integer(7, UInt64(UInt32(bitPattern: -90)))
            + SteamProto.bytes(6, Data("english".utf8))
        try await send(5514, logon)
        var loggedOn = false
        var requestedProducts = false
        var result: [String: SteamProduct] = [:]
        var totalBytes = 0
        for _ in 0..<128 {
            try Task.checkCancellation()
            guard case .data(let data) = try await socket.receive() else { throw CheckError.invalidResponse }
            totalBytes += data.count
            guard totalBytes <= 32_000_000 else { throw CheckError.invalidResponse }
            for message in try SteamWire.decode(data) {
                switch message.kind {
                case 751: // ClientLogOnResponse.
                    let body = try SteamProto(message.body)
                    guard !loggedOn, body.number(1) == 1,
                          let assignedID = message.header.number(1), let assignedSession = message.header.number(2) else {
                        throw CheckError.invalidResponse
                    }
                    steamID = assignedID; sessionID = assignedSession; loggedOn = true
                    let request = appIDs.sorted().reduce(into: Data()) { $0 += SteamProto.integer(2, UInt64($1)!) }
                    try await send(8905, request, job: 1) // Public PICS access tokens, not user authentication.
                case 8906:
                    guard loggedOn, !requestedProducts, message.header.number(11) == 1 else { continue }
                    let body = try SteamProto(message.body)
                    var tokens: [String: UInt64] = [:]
                    for buffer in body.buffers(3) {
                        let token = try SteamProto(buffer)
                        if let id = token.number(1), let value = token.number(2), appIDs.contains(String(id)) {
                            tokens[String(id)] = value
                        }
                    }
                    var request = Data()
                    for id in appIDs.sorted() {
                        request += SteamProto.bytes(2, SteamProto.integer(1, UInt64(id)!) + SteamProto.integer(2, tokens[id] ?? 0))
                    }
                    requestedProducts = true
                    try await send(8903, request, job: 2) // PICSProductInfoRequest.
                case 8904:
                    guard requestedProducts, message.header.number(11) == 2 else { continue }
                    let body = try SteamProto(message.body)
                    for buffer in body.buffers(1) {
                        let app = try SteamProto(buffer)
                        guard let number = app.number(1), appIDs.contains(String(number)),
                              let buffer = app.buffers(5).first else { continue }
                        // PICS appinfo is a NUL-terminated text KeyValues document.
                        var text = buffer
                        if text.last == 0 { text.removeLast() }
                        if let product = try? SteamProduct.parse(text, appID: String(number), publicOnly: app.number(6) == 1) {
                            result[product.appID] = product
                        }
                    }
                    if body.number(6) != 1 { return result } // response_pending.
                case 757: // ClientLoggedOff.
                    throw CheckError.invalidResponse
                default: break
                }
            }
        }
        throw CheckError.invalidResponse
    }
}

// The small protobuf subset needed by the anonymous catalog protocol. Unknown
// fields are skipped; all lengths, varints, decompression and nesting are bounded.
struct SteamProto {
    enum Value { case number(UInt64), buffer(Data) }
    var fields: [Int: [Value]] = [:]

    init(_ data: Data) throws {
        guard data.count <= SteamWire.maximumSize else { throw CheckError.invalidResponse }
        let bytes = Array(data); var index = 0
        func varint() throws -> UInt64 {
            var result: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard index < bytes.count else { throw CheckError.invalidResponse }
                let byte = bytes[index]; index += 1
                guard shift < 63 || byte <= 1 else { throw CheckError.invalidResponse }
                result |= UInt64(byte & 127) << shift
                if byte & 128 == 0 { return result }
            }
            throw CheckError.invalidResponse
        }
        func fixed(_ count: Int) throws -> UInt64 {
            guard count <= bytes.count - index else { throw CheckError.invalidResponse }
            var value: UInt64 = 0
            for offset in 0..<count { value |= UInt64(bytes[index + offset]) << (8 * offset) }
            index += count; return value
        }
        while index < bytes.count {
            let key = try varint(), field = key >> 3
            guard field > 0, field < 1 << 29 else { throw CheckError.invalidResponse }
            let value: Value
            switch key & 7 {
            case 0: value = .number(try varint())
            case 1: value = .number(try fixed(8))
            case 2:
                let size = try varint()
                guard size <= UInt64(bytes.count - index) else { throw CheckError.invalidResponse }
                value = .buffer(Data(bytes[index..<index + Int(size)])); index += Int(size)
            case 5: value = .number(try fixed(4))
            default: throw CheckError.invalidResponse
            }
            fields[Int(field), default: []].append(value)
        }
    }

    func number(_ field: Int) -> UInt64? {
        guard case .number(let value) = fields[field]?.first else { return nil }; return value
    }
    func buffers(_ field: Int) -> [Data] {
        (fields[field] ?? []).compactMap { if case .buffer(let data) = $0 { data } else { nil } }
    }
    private static func varint(_ value: UInt64) -> Data {
        var value = value; var data = Data()
        while value >= 128 { data.append(UInt8(value & 127) | 128); value >>= 7 }
        data.append(UInt8(value)); return data
    }
    static func integer(_ field: Int, _ value: UInt64) -> Data { varint(UInt64(field << 3)) + varint(value) }
    static func fixed64(_ field: Int, _ value: UInt64) -> Data {
        var value = value.littleEndian
        return varint(UInt64(field << 3 | 1)) + withUnsafeBytes(of: &value) { Data($0) }
    }
    static func bytes(_ field: Int, _ value: Data) -> Data {
        varint(UInt64(field << 3 | 2)) + varint(UInt64(value.count)) + value
    }
}

enum SteamWire {
    static let maximumSize = 8_000_000
    struct Message { var kind: UInt32; var header: SteamProto; var body: Data }
    static func message(_ kind: UInt32, header: Data, body: Data) -> Data {
        var kind = (kind | 0x8000_0000).littleEndian, size = UInt32(header.count).littleEndian
        return withUnsafeBytes(of: &kind) { Data($0) } + withUnsafeBytes(of: &size) { Data($0) } + header + body
    }
    static func decode(_ data: Data, depth: Int = 0) throws -> [Message] {
        var budget = 16_000_000
        return try decode(data, depth: depth, budget: &budget)
    }
    private static func decode(_ data: Data, depth: Int, budget: inout Int) throws -> [Message] {
        guard data.count >= 8, data.count <= maximumSize, depth < 4, data.count <= budget else { throw CheckError.invalidResponse }
        budget -= data.count
        let kind = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        guard kind & 0x8000_0000 != 0 else { return [] }
        let size = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian })
        guard size <= data.count - 8 else { throw CheckError.invalidResponse }
        let header = try SteamProto(data.subdata(in: 8..<8 + size))
        let body = data.subdata(in: 8 + size..<data.count)
        guard kind & 0x7fff_ffff == 1 else { return [Message(kind: kind & 0x7fff_ffff, header: header, body: body)] }
        let multi = try SteamProto(body)
        guard let packed = multi.buffers(2).first else { throw CheckError.invalidResponse }
        let unpacked = try multi.number(1).map { $0 > 0 ? try gunzip(packed, expected: $0) : packed } ?? packed
        guard unpacked.count <= budget else { throw CheckError.invalidResponse }
        budget -= unpacked.count
        var index = 0, result: [Message] = []
        while index < unpacked.count {
            guard unpacked.count - index >= 4, result.count < 512 else { throw CheckError.invalidResponse }
            let count = Int(unpacked.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: index, as: UInt32.self).littleEndian })
            index += 4
            guard count > 0, count <= unpacked.count - index else { throw CheckError.invalidResponse }
            let nested = try decode(unpacked.subdata(in: index..<index + count), depth: depth + 1, budget: &budget)
            guard nested.count <= 512 - result.count else { throw CheckError.invalidResponse }
            result += nested
            index += count
        }
        return result
    }

    static func gunzip(_ data: Data, expected: UInt64) throws -> Data {
        guard expected > 0, expected <= maximumSize else { throw CheckError.invalidResponse }
        var stream = z_stream()
        guard inflateInit2_(&stream, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw CheckError.invalidResponse
        }
        defer { inflateEnd(&stream) }
        var output = Data(count: Int(expected))
        let status = data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { destination in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(data.count)
                stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(expected)
                return inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END, stream.total_out == expected, stream.avail_in == 0 else { throw CheckError.invalidResponse }
        return output
    }
}
