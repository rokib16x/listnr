import Foundation

protocol Transcriber: Actor {
    var modelID: String { get }
    func warmUp() async throws
    func transcribe(_ audio: [Float]) async throws -> String
}

enum TranscriberError: Error, LocalizedError {
    case missingEngineID
    case notLoaded

    var errorDescription: String? {
        switch self {
        case .missingEngineID: return "model missing WhisperKit id"
        case .notLoaded: return "transcriber not loaded — call warmUp() first"
        }
    }
}
