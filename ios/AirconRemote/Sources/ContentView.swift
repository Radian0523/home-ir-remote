import SwiftUI

// 操作画面。よく使う操作だけを上に並べる: 予約中バナー → 照明（4ボタン）→ エアコン（つける・けす・よく使う予約）。
// 細かい設定（モード・温度・風量・風向、時刻を選ぶ予約）は下の「その他の操作」に折りたたむ。
// 結果は画面上部のトーストで出す。別画面は設定（SettingsView）だけ。
@MainActor
struct ContentView: View {
    @EnvironmentObject private var config: AppConfig
    @EnvironmentObject private var store: SettingStore
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var schedule = ScheduleModel()
    @State private var showSettings = false
    @State private var sending = false
    @State private var toast: Toast?
    @State private var toastTask: Task<Void, Never>?
    @AppStorage("showMoreControls") private var showMore = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if !config.isConfigured {
                        Button {
                            showSettings = true
                        } label: {
                            Label("Worker URL と APP_TOKEN を設定する", systemImage: "gear")
                                .fontWeight(.semibold)
                        }
                        .card()
                    }

                    ForEach(schedule.schedules) { record in
                        ScheduleBanner(record: record, loading: schedule.loading) {
                            Task { await cancelSchedule(id: record.id) }
                        }
                    }

                    LightSection(onResult: show)
                    QuickAirconCard(
                        sending: sending,
                        scheduling: schedule.loading,
                        onPower: { power in Task { await send(power: power) } },
                        onSchedule: { quick in Task { await saveQuickSchedule(quick) } }
                    )
                    moreControls
                }
                .padding(.horizontal)
                .padding(.bottom, 12)
                .animation(.easeOut(duration: 0.2), value: schedule.schedules)
            }
            .background(Color(.systemGroupedBackground))
            .overlay(alignment: .top) {
                if let toast {
                    ToastView(toast: toast)
                        .onTapGesture { self.toast = nil }
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.top, 4)
                }
            }
            .animation(.spring(duration: 0.3), value: toast)
            .sensoryFeedback(trigger: toast) { _, new in
                guard let new else { return nil }
                return new.isSuccess ? .success : .error
            }
            .refreshable { await loadSchedule() }
            .navigationTitle("今日もお疲れ様でした。")
            .toolbar {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gear")
                }
                .accessibilityLabel("設定")
            }
            .sheet(isPresented: $showSettings, onDismiss: { Task { await loadSchedule() } }) {
                SettingsView()
            }
            .task { await loadSchedule() }
            // ショートカットやウィジェットで予約が変わることがあるので、前面に戻るたびに読み直す
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await loadSchedule() } }
            }
        }
    }

    /// 普段は使わない操作。開閉状態は端末に覚えておく
    private var moreControls: some View {
        VStack(spacing: 12) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { showMore.toggle() }
            } label: {
                HStack {
                    Text("その他の操作").font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(showMore ? 180 : 0))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(showMore ? "開いている" : "閉じている")

            if showMore {
                AirconCard(sending: sending) { Task { await send() } }
                ScheduleSection(model: schedule) { at in await saveSchedule(at) }
            }
        }
        .padding(.top, 4)
    }

    private func loadSchedule() async {
        await schedule.load(configured: config.isConfigured)
    }

    /// 成功は2秒で消す。失敗はタップするか次の結果が出るまで残す
    private func show(_ new: Toast) {
        toastTask?.cancel()
        toast = new
        guard new.isSuccess else { return }
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled, toast?.id == new.id { toast = nil }
        }
    }

    /// 電源を指定して今の設定を送る（「つける」「けす」）
    private func send(power: Bool) async {
        store.setting.power = power
        await send()
    }

    private func send() async {
        sending = true
        defer { sending = false }
        let setting = store.setting
        // ウィジェットの「最後の操作」も更新するため、共通の入口から送る
        let outcome = await RemoteActions.sendAircon(setting)
        if outcome.isSuccess { store.lastSent = setting }
        show(Toast(outcome))
    }

    private func saveSchedule(_ at: Date) async {
        if let error = await schedule.save(executeAt: at, setting: store.setting) {
            show(Toast(message: error, isSuccess: false))
        } else {
            show(Toast(message: "予約しました", isSuccess: true))
        }
    }

    private func saveQuickSchedule(_ quick: QuickSchedule) async {
        let at = quick.executeAt(now: Date())
        if let error = await schedule.save(executeAt: at, setting: quick.setting(base: store.setting)) {
            show(Toast(message: error, isSuccess: false))
        } else {
            let time = Calendar.current.isDateInToday(at)
                ? at.formatted(date: .omitted, time: .shortened)
                : "明日 " + at.formatted(date: .omitted, time: .shortened)
            show(Toast(message: "\(time) に\(quick.power ? "ON" : "OFF")を予約しました", isSuccess: true))
        }
    }

    private func cancelSchedule(id: String) async {
        if let error = await schedule.cancel(id: id) {
            show(Toast(message: error, isSuccess: false))
        } else {
            show(Toast(message: "予約を取り消しました", isSuccess: true))
        }
    }
}

/// エアコンのよく使う操作。つける・けすは押した瞬間に送り、予約ボタンは押した時点から時刻を決めて予約する
struct QuickAirconCard: View {
    @EnvironmentObject private var store: SettingStore

    let sending: Bool
    let scheduling: Bool
    let onPower: (Bool) -> Void
    let onSchedule: (QuickSchedule) -> Void

    private var setting: Setting { store.setting }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("エアコン").font(.headline)
                Spacer()
                Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 8) {
                powerTile(on: true)
                powerTile(on: false)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(QuickSchedule.allCases) { quick in
                    Button {
                        onSchedule(quick)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: quick.systemImage)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(quick.power ? setting.mode.color : Color.secondary)
                                .frame(width: 22)
                            Text(quick.label)
                                .font(.footnote.weight(.semibold))
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(scheduling)
                    .accessibilityLabel(quick.label.replacingOccurrences(of: "\n", with: ""))
                }
            }
        }
        .card()
    }

    /// 送る内容（OFF でもモード・温度は前回のまま）
    private var caption: String {
        let detail = "\(setting.mode.label) \(setting.temp)℃"
        return store.hasUnsentChanges ? "未送信の変更あり · \(detail)" : detail
    }

    private func powerTile(on: Bool) -> some View {
        let tint = on ? setting.mode.color : Color.gray
        let active = store.lastSent?.power == on
        return Button {
            onPower(on)
        } label: {
            VStack(spacing: 6) {
                if sending && setting.power == on {
                    ProgressView().frame(height: 34)
                } else {
                    Image(systemName: on ? "power" : "power.circle")
                        .font(.title.weight(.semibold))
                        .frame(height: 34)
                }
                Text(on ? "つける" : "けす").font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .foregroundStyle(active ? Color.white : Color.primary)
            .background(active ? tint : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(sending)
        .accessibilityHint(on ? "\(setting.mode.label) \(setting.temp)℃ ですぐ送ります" : "すぐ電源OFFを送ります")
    }
}
