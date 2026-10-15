import Foundation

protocol HTTPClient: Sendable {
    func fetch(_ request: URLRequest) async throws -> Data
}

struct NetworkClient: HTTPClient {
    func fetch(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw CheckError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw CheckError.httpStatus(response.statusCode)
        }
        return data
    }
}

enum CheckError: Error, LocalizedError {
    case invalidResponse, noMetadata, httpStatus(Int), timedOut
    var errorDescription: String? {
        switch self {
        case .invalidResponse: "更新源返回了无法读取的数据。"
        case .noMetadata: "更新源没有可比较的版本信息。"
        case .httpStatus(let code): "更新源返回 HTTP \(code)。"
        case .timedOut: "检查超时，请稍后重试。"
        }
    }
}

/// Bound network concurrency without launching every application at once.
func checkInBatches<Input: Sendable, Output: Sendable>(
    _ inputs: [Input], size: Int = 4,
    operation: @escaping @Sendable (Input) async -> Output
) async -> [Output] {
    var results: [Output] = []
    for start in stride(from: 0, to: inputs.count, by: size) {
        if Task.isCancelled { break }
        let batch = Array(inputs[start..<min(start + size, inputs.count)])
        let batchResults = await withTaskGroup(of: Output.self) { group in
            for input in batch { group.addTask { await operation(input) } }
            var values: [Output] = []
            for await value in group { values.append(value) }
            return values
        }
        results.append(contentsOf: batchResults)
    }
    return results
}
