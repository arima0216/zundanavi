import Foundation
import os

enum APIError: LocalizedError {
    case badURL
    case noToken
    case unauthorized
    case notFound
    case http(Int)
    case decode

    var errorDescription: String? {
        switch self {
        case .badURL: return "サーバー URL が正しくないのだ"
        case .noToken: return "トークンが未設定なのだ"
        case .unauthorized: return "トークンが違うのだ (401)"
        case .notFound: return "見つからないのだ (404)"
        case .http(let c): return "サーバーエラー (HTTP " + String(c) + ")"
        case .decode: return "返事の形が読めないのだ"
        }
    }
}

/// API 契約 v1 のクライアント。設定から毎回作る軽い値。
struct APIClient {
    let baseURL: String
    let token: String
    static let log = Logger(subsystem: "dev.momo.zundanavi", category: "api")

    static let askTimeout: TimeInterval = 120
    static let healthTimeout: TimeInterval = 5
    static let defaultTimeout: TimeInterval = 20

    func makeRequest(_ path: String, method: String = "GET", timeout: TimeInterval = APIClient.defaultTimeout) throws -> URLRequest {
        guard let url = Endpoint.url(base: baseURL, path: path) else { throw APIError.badURL }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = timeout
        r.setValue(token, forHTTPHeaderField: "X-Trip-Token")
        return r
    }

    func send(_ req: URLRequest) async throws -> Data {
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.http(-1) }
        switch http.statusCode {
        case 200..<300: return data
        case 401: throw APIError.unauthorized
        case 404: throw APIError.notFound
        default: throw APIError.http(http.statusCode)
        }
    }

    func health() async throws -> HealthInfo {
        let data = try await send(makeRequest("/v1/health", timeout: APIClient.healthTimeout))
        do { return try HealthInfo.decode(data) } catch { throw APIError.decode }
    }

    func ask(text: String?, audioWav: Data?, gps: GPSFix?, mode: String, requestID: String) async throws -> AskResponse {
        var form = MultipartForm()
        if let t = text, !t.isEmpty { form.addField("text", t) }
        if let a = audioWav { form.addFile("audio", filename: "speech.wav", mimeType: "audio/wav", data: a) }
        if let g = gps { form.addField("gps", g.jsonString()) }
        form.addField("mode", mode)
        form.addField("request_id", requestID)
        var req = try makeRequest("/v1/ask", method: "POST", timeout: APIClient.askTimeout)
        req.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        req.httpBody = form.finalized()
        let data = try await send(req)
        do { return try AskResponse.decode(data) } catch { throw APIError.decode }
    }

    func photo(jpeg: Data, note: String?, gps: GPSFix?) async throws -> AskResponse {
        var form = MultipartForm()
        form.addFile("image", filename: "photo.jpg", mimeType: "image/jpeg", data: jpeg)
        if let n = note, !n.isEmpty { form.addField("note", n) }
        if let g = gps { form.addField("gps", g.jsonString()) }
        var req = try makeRequest("/v1/photo", method: "POST", timeout: APIClient.askTimeout)
        req.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        req.httpBody = form.finalized()
        let data = try await send(req)
        do { return try AskResponse.decode(data) } catch { throw APIError.decode }
    }

    /// 無ければ nil（404）。
    func card() async throws -> CardInfo? {
        do {
            let data = try await send(makeRequest("/v1/card"))
            do { return try CardInfo.decode(data) } catch { throw APIError.decode }
        } catch APIError.notFound {
            return nil
        }
    }

    func history(limit: Int = 20) async throws -> [ServerHistoryItem] {
        let data = try await send(makeRequest("/v1/history?limit=" + String(limit)))
        do { return try ServerHistoryItem.decodeList(data) } catch { throw APIError.decode }
    }

    func quiet(minutes: Int) async throws {
        var req = try makeRequest("/v1/quiet", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["minutes": minutes])
        _ = try await send(req)
    }

    /// プランナーの見張り用。404 などは呼び出し側で無視する。
    func position(_ fix: GPSFix) async throws {
        var req = try makeRequest("/v1/position", method: "POST", timeout: 10)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = fix.jsonData()
        _ = try await send(req)
    }

    /// audio_url（相対でも絶対でも）から wav を取る。
    func fetchAudio(_ urlString: String) async throws -> Data {
        return try await send(makeRequest(urlString, timeout: 30))
    }

    func filler(_ name: String) async throws -> Data {
        return try await send(makeRequest("/v1/filler/" + name, timeout: 10))
    }

    /// WS /v1/events の接続要求（ヘッダでトークンを渡す）。
    func eventsRequest() -> URLRequest? {
        guard let url = Endpoint.websocketURL(base: baseURL, path: "/v1/events") else { return nil }
        var r = URLRequest(url: url)
        r.timeoutInterval = 30
        r.setValue(token, forHTTPHeaderField: "X-Trip-Token")
        return r
    }
}
