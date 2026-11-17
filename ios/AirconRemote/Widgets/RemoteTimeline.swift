import SwiftUI
import WidgetKit

// ウィジェットに出す内容。前回の設定・最後の操作は SharedStore（Keychain 共有グループ）から、
// 予約は GET /schedule（一覧）から取る。照明の状態は誰にもわからないので出さない（ADR-022）。
struct RemoteEntry: TimelineEntry {
    var date: Date
    var configured: Bool
    var setting: Setting
    /// 予約（早い順）
    var schedules: [ScheduleRecord]
    var scheduleUnknown: Bool
    var lastResult: LastResult?

    static let placeholder = RemoteEntry(
        date: .now, configured: true,
        setting: Setting(power: true, mode: .cool, temp: 26, fan: .auto, vane: .auto),
        schedules: [], scheduleUnknown: false, lastResult: nil)

    static func local() -> RemoteEntry {
        RemoteEntry(
            date: .now, configured: SharedStore.client() != nil, setting: SharedStore.lastSetting,
            schedules: [], scheduleUnknown: false, lastResult: SharedStore.lastResult)
    }
}

struct RemoteProvider: TimelineProvider {
    /// 予約を表示するウィジェットだけ通信する
    var fetchSchedule: Bool

    func placeholder(in context: Context) -> RemoteEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (RemoteEntry) -> Void) {
        completion(context.isPreview ? .placeholder : .local())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RemoteEntry>) -> Void) {
        Task {
            var entry = RemoteEntry.local()
            if fetchSchedule && entry.configured {
                switch await RemoteActions.getSchedules() {
                case .ok(let list): entry.schedules = list
                default: entry.scheduleUnknown = true
                }
            }
            // 30 分ごと。予約があれば一番早い予約の直後にも更新して表示を進める
            var next = Date().addingTimeInterval(30 * 60)
            if let record = entry.schedules.first, let at = ExecuteAtFormat.date(from: record.executeAt), at > Date() {
                next = min(next, at.addingTimeInterval(60))
            }
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }
}

// MARK: - 共通の部品

struct ResultLine: View {
    let result: LastResult?

    var body: some View {
        if let result {
            HStack(spacing: 4) {
                Image(systemName: result.success ? "checkmark.circle" : "exclamationmark.triangle")
                Text("\(result.at.formatted(date: .omitted, time: .shortened)) \(result.success ? result.action : result.message)")
            }
            .font(.caption2)
            .foregroundStyle(result.success ? Color.secondary : Color.orange)
            .lineLimit(1)
        }
    }
}

struct NotConfiguredView: View {
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "gear")
            Text("アプリで Worker URL と APP_TOKEN を設定してください")
                .font(.caption2)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct WidgetHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.bold())
            .foregroundStyle(.secondary)
    }
}
