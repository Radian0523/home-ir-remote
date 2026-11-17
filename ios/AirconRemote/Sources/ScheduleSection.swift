import SwiftUI

// 一発予約（design.md §6、ADR-024）。予約は最大2件。一覧の取得・1件追加・1件取り消しを行う。
// 予約中の表示は操作画面上部のバナー、作成はよく使う予約ボタンと下の方のカードに分けるため、状態はこのモデルで共有する。
@MainActor
final class ScheduleModel: ObservableObject {
    /// 予約（早い順）
    @Published private(set) var schedules: [ScheduleRecord] = []
    @Published private(set) var loading = false
    /// 読み込み失敗の表示。保存・取り消しの結果はトーストで出す
    @Published private(set) var loadError: String?

    var isFull: Bool { schedules.count >= ScheduleLimit.max }

    /// 未設定のときは何もしない（未設定の案内は操作画面側で出す）
    func load(configured: Bool) async {
        guard configured else { return }
        loading = true
        defer { loading = false }
        switch await RemoteActions.getSchedules() {
        case .ok(let list): schedules = list; loadError = nil
        case let other: loadError = other.message
        }
    }

    /// 成功なら nil、失敗なら表示する文言を返す
    func save(executeAt: Date, setting: Setting) async -> String? {
        loading = true
        defer { loading = false }
        switch await RemoteActions.addSchedule(executeAt: executeAt, setting: setting) {
        case .ok(let rec):
            schedules = (schedules + [rec]).sorted { $0.executeAt < $1.executeAt }
            loadError = nil
            return nil
        case .full:
            // ほかの端末やショートカットで増えていることがあるので読み直す
            await reloadQuietly()
            return ScheduleOutcome<ScheduleRecord>.full.message
        case let other: return other.message ?? "予約できませんでした"
        }
    }

    /// 成功なら nil、失敗なら表示する文言を返す
    func cancel(id: String) async -> String? {
        loading = true
        defer { loading = false }
        switch await RemoteActions.deleteSchedule(id: id) {
        case .ok: schedules.removeAll { $0.id == id }; loadError = nil; return nil
        case let other: return other.message ?? "取り消せませんでした"
        }
    }

    private func reloadQuietly() async {
        if case .ok(let list) = await RemoteActions.getSchedules() { schedules = list }
    }
}

/// 予約の作成カード。「5分後」などのチップで時刻を選び、上のエアコン設定をその時刻に予約する
@MainActor
struct ScheduleSection: View {
    @ObservedObject var model: ScheduleModel
    /// 実行時刻と、その時刻に送る電源（ON なら上の設定で運転、OFF なら停止）
    let onSave: @MainActor (Date, Bool) async -> Void

    @State private var preset: SchedulePreset = .in5
    @State private var power = true
    /// 「時刻を指定」のときの時刻。デフォルトは5分後
    @State private var customAt = Date().addingTimeInterval(5 * 60)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("予約").font(.headline)
                Spacer()
                Text("\(ScheduleLimit.max)件まで（いま\(model.schedules.count)件）").font(.caption).foregroundStyle(.secondary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(SchedulePreset.allCases) { p in
                        ChipButton(label: p.label, selected: preset == p, tint: .accentColor) { preset = p }
                    }
                }
            }

            Picker("予約する操作", selection: $power) {
                Text("ON（上の設定で運転）").tag(true)
                Text("OFF（停止）").tag(false)
            }
            .pickerStyle(.segmented)

            if preset == .custom {
                DatePicker("実行時刻", selection: $customAt, in: Date()..., displayedComponents: [.date, .hourAndMinute])
            }

            TimelineView(.everyMinute) { context in
                let at = preset.executeAt(now: context.date, custom: customAt)
                Button {
                    // 「5分後」は押した時点から数える
                    Task { await onSave(preset.executeAt(now: Date(), custom: customAt), power) }
                } label: {
                    ZStack {
                        if model.loading { ProgressView() } else { Text(saveTitle(at)).fontWeight(.semibold) }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: 12))
                .disabled(model.loading)
            }

            if let error = model.loadError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .card()
    }

    private func saveTitle(_ at: Date) -> String {
        let time = Calendar.current.isDateInToday(at)
            ? at.formatted(date: .omitted, time: .shortened)
            : at.formatted(date: .abbreviated, time: .shortened)
        return power ? "\(time) にONを予約" : "\(time) にOFFを予約"
    }
}

/// 予約中のもの（最大2件）を操作画面の上部に出す。取り消しは1件ずつここから行う
struct ScheduleBanner: View {
    let record: ScheduleRecord
    let loading: Bool
    let onCancel: () -> Void

    var body: some View {
        if let date = ExecuteAtFormat.date(from: record.executeAt) {
            HStack(spacing: 12) {
                Image(systemName: "clock.badge.checkmark")
                    .font(.title3)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    TimelineView(.everyMinute) { _ in
                        Text("\(date.formatted(date: .abbreviated, time: .shortened)) に予約中 · \(date.formatted(.relative(presentation: .named)))")
                            .font(.subheadline.weight(.semibold))
                    }
                    Text(Setting.summary(record.setting))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button("取り消す", role: .destructive, action: onCancel)
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.borderless)
                    .disabled(loading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

// 予約時刻の選び方。「5分後」などは押した瞬間ではなく、予約ボタンを押した時点から数える
enum SchedulePreset: String, CaseIterable, Identifiable {
    case in5, in30, in60, in120, custom
    var id: String { rawValue }

    var minutes: Int? {
        switch self {
        case .in5: 5
        case .in30: 30
        case .in60: 60
        case .in120: 120
        case .custom: nil
        }
    }

    var label: String {
        switch self {
        case .in5: "5分後"
        case .in30: "30分後"
        case .in60: "1時間後"
        case .in120: "2時間後"
        case .custom: "時刻を指定"
        }
    }

    func executeAt(now: Date, custom: Date) -> Date {
        guard let minutes else { return custom }
        return now.addingTimeInterval(TimeInterval(minutes * 60))
    }
}
