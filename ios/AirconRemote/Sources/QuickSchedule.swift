import Foundation

// 操作画面の「よく使う予約」ボタン。押した時点から実行時刻を決め、前回のエアコン設定の電源だけを差し替えて予約する。
enum QuickSchedule: String, CaseIterable, Identifiable {
    /// 次に来る 7:20 に今の設定で運転開始（朝の起床用）
    case onAt0720
    /// 7時間20分後に今の設定で運転開始
    case onIn7h20m
    /// 10分後に電源OFF
    case offIn10m

    var id: String { rawValue }

    var label: String {
        switch self {
        case .onAt0720: "7:20 にONを予約"
        case .onIn7h20m: "7時間20分後に\nONを予約"
        case .offIn10m: "10分後に\nOFFを予約"
        }
    }

    var systemImage: String {
        switch self {
        case .onAt0720: "alarm"
        case .onIn7h20m: "sunrise"
        case .offIn10m: "timer"
        }
    }

    var power: Bool { self != .offIn10m }

    func executeAt(now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .onAt0720:
            // 今日の 7:20 を過ぎていれば明日の 7:20
            return calendar.nextDate(
                after: now, matching: DateComponents(hour: 7, minute: 20, second: 0), matchingPolicy: .nextTime
            ) ?? now.addingTimeInterval(24 * 60 * 60)
        case .onIn7h20m:
            return now.addingTimeInterval((7 * 60 + 20) * 60)
        case .offIn10m:
            return now.addingTimeInterval(10 * 60)
        }
    }

    /// 予約に載せる設定。OFF の予約でもモードや温度は前回のまま持たせる（全設定を送る、ADR-015）
    func setting(base: Setting) -> Setting {
        var s = base
        s.power = power
        return s
    }
}
