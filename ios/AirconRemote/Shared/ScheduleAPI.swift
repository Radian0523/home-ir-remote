import Foundation

// 予約 API（design.md §5.5、ADR-024）。一覧の取得・1件追加・1件取り消し・全取り消し。予約は最大2件。
struct ScheduleRecord: Codable, Equatable, Identifiable {
    var id: String
    var executeAt: String  // UTC 正規形 YYYY-MM-DDTHH:mm:ssZ
    var setting: Setting
}

/// POST /schedule の body。id はサーバーが付ける
struct NewSchedule: Encodable {
    var executeAt: String
    var setting: Setting
}

enum ScheduleLimit {
    /// Worker が同時に持てる予約の数（ADR-024）
    static let max = 2
}

enum ScheduleOutcome<T: Equatable>: Equatable {
    case ok(T)
    case badRequest, unauthorized, serverError
    /// すでに上限まで予約がある（409）
    case full
    case unexpected(Int)
    case network(String)
    case notConfigured

    var message: String? {
        switch self {
        case .ok: nil
        case .badRequest: "予約の送信形式に不具合があります（アプリの問題）"
        case .unauthorized: "APP_TOKEN が Worker の設定と一致しません"
        case .full: "予約は\(ScheduleLimit.max)件までです。どれかを取り消してから入れてください"
        case .serverError: "Cloudflare 側でエラーが起きました。Worker のログを確認してください"
        case .unexpected(let code): "想定外の応答です（HTTP \(code)）"
        case .network(let detail): "通信できませんでした: \(detail)"
        case .notConfigured: "設定画面で Worker URL と APP_TOKEN を入力してください"
        }
    }
}

enum ExecuteAtFormat {
    /// §5.2 の正規形。UTC、小数秒なし、末尾 Z
    static func string(from date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        // 秒未満を切り捨てる
        let whole = Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
        return f.string(from: whole)
    }

    static func date(from string: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: string)
    }
}

extension APIClient {
    private func request(_ method: String, path: String, body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = body
        return request
    }

    private func run<T: Equatable>(_ req: URLRequest, decode: (Data) throws -> T) async -> ScheduleOutcome<T> {
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { return .unexpected(0) }
            switch http.statusCode {
            case 200: return .ok(try decode(data))
            case 400: return .badRequest
            case 401: return .unauthorized
            case 409: return .full
            case 500: return .serverError
            default: return .unexpected(http.statusCode)
            }
        } catch is DecodingError {
            return .unexpected(-1)  // 200 だが形式が想定外
        } catch {
            return .network(error.localizedDescription)
        }
    }

    /// 予約を早い順で返す（なければ空配列）
    func getSchedules() async -> ScheduleOutcome<[ScheduleRecord]> {
        await run(request("GET", path: "schedule")) { data in
            try JSONDecoder().decode([ScheduleRecord].self, from: data)
        }
    }

    func addSchedule(executeAt: Date, setting: Setting) async -> ScheduleOutcome<ScheduleRecord> {
        let body = NewSchedule(executeAt: ExecuteAtFormat.string(from: executeAt), setting: setting)
        guard let data = try? JSONEncoder().encode(body) else { return .badRequest }
        return await run(request("POST", path: "schedule", body: data)) { data in
            try JSONDecoder().decode(ScheduleRecord.self, from: data)
        }
    }

    func deleteSchedule(id: String) async -> ScheduleOutcome<Bool> {
        await run(request("DELETE", path: "schedule/\(id)")) { _ in true }
    }

    func deleteAllSchedules() async -> ScheduleOutcome<Bool> {
        await run(request("DELETE", path: "schedule")) { _ in true }
    }
}
