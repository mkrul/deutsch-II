import Foundation

enum SpeechError: Error {
    case missingKey
    case rejected
    case failed
}

actor GermanSpeech {
    static let shared = GermanSpeech()

    private let voice = "JBFqnCBsd6RMkjVDRZzb"
    private let speed = 0.7
    private var cache: [String: Data] = [:]

    func audio(apiKey: String, german: String) async throws -> Data {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty { throw SpeechError.missingKey }
        let cacheKey = "\(speed):\(german)"
        if let cached = cache[cacheKey] { return cached }
        let bytes = try await fetch(key: key, german: german)
        if cache.count >= 100 { cache.removeAll() }
        cache[cacheKey] = bytes
        return bytes
    }

    private func fetch(key: String, german: String) async throws -> Data {
        guard let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voice)") else {
            throw SpeechError.failed
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        let body: [String: Any] = [
            "text": german,
            "model_id": "eleven_flash_v2_5",
            "language_code": "de",
            "voice_settings": ["speed": speed],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SpeechError.failed
        }
        guard let http = response as? HTTPURLResponse else { throw SpeechError.failed }
        if http.statusCode == 401 || http.statusCode == 403 { throw SpeechError.rejected }
        if !(200...299).contains(http.statusCode) { throw SpeechError.failed }
        if data.isEmpty || data.count > 8 * 1024 * 1024 { throw SpeechError.failed }
        return data
    }
}
