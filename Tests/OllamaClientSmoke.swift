import Foundation

@main
struct OllamaClientSmoke {
    static func main() async throws {
        let installed = Data(#"{"models":[{"name":"zeta:latest","size":1234},{"name":"alpha:latest","size":5678}]}"#.utf8)
        let running = Data(#"{"models":[{"name":"zeta:latest"}]}"#.utf8)
        let models = try OllamaClient.parseModels(installed: installed, running: running)
        precondition(models.map(\.name) == ["alpha:latest", "zeta:latest"])
        precondition(models.map(\.loaded) == [false, true])
        precondition(models.map(\.size) == [5678, 1234])
        do {
            _ = try OllamaClient.parseModels(installed: Data("{}".utf8), running: running)
            preconditionFailure("Malformed model list was accepted")
        } catch OllamaError.invalidResponse { }
        if CommandLine.arguments.contains("--live") {
            let live = try await OllamaClient().models()
            print("Live Ollama models: \(live.map(\.name).joined(separator: ", "))")
        }
        print("PASS: Ollama installed and loaded model parsing")
    }
}
