import Foundation

struct OllamaModel: Identifiable {
    let name: String
    let size: Int64
    let loaded: Bool
    var id: String { name }
}

enum OllamaError: LocalizedError {
    case invalidResponse
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Ollama 返回了无法识别的数据"
        case .server(let code, let message):
            return message.isEmpty ? "Ollama 请求失败（HTTP \(code)）" : message
        }
    }
}

struct OllamaClient {
    private let baseURL = URL(string: "http://127.0.0.1:11434")!

    func models() async throws -> [OllamaModel] {
        let installed = try await request("/api/tags", timeout: 8)
        let running = try await request("/api/ps", timeout: 8)
        return try Self.parseModels(installed: installed, running: running)
    }

    func setLoaded(_ name: String, loaded: Bool) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "model": name, "prompt": "", "stream": false,
            "keep_alive": loaded ? -1 : 0
        ] as [String: Any])
        let response = try await request("/api/generate", method: "POST", body: body, timeout: 180)
        guard let result = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
              result["done"] as? Bool == true else { throw OllamaError.invalidResponse }
    }

    static func parseModels(installed: Data, running: Data) throws -> [OllamaModel] {
        guard let tags = try? JSONSerialization.jsonObject(with: installed) as? [String: Any],
              let installedRows = tags["models"] as? [[String: Any]],
              let ps = try? JSONSerialization.jsonObject(with: running) as? [String: Any],
              let runningRows = ps["models"] as? [[String: Any]] else {
            throw OllamaError.invalidResponse
        }
        let loaded = Set(runningRows.compactMap { $0["name"] as? String })
        return installedRows.compactMap { row in
            guard let name = row["name"] as? String, !name.isEmpty else { return nil }
            return OllamaModel(name: name, size: (row["size"] as? NSNumber)?.int64Value ?? 0,
                               loaded: loaded.contains(name))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil,
                         timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = timeout
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OllamaError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = json?["error"] as? String ?? ""
            throw OllamaError.server(http.statusCode, message)
        }
        return data
    }
}
