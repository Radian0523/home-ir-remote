import SwiftUI

// 操作画面。上から 予約中バナー → 照明 → エアコン → 予約 のカードを並べ、「今すぐ送る」は画面下端に固定する。
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

                    if let current = schedule.current {
                        ScheduleBanner(record: current, loading: schedule.loading) {
                            Task { await cancelSchedule() }
                        }
                    }

                    LightSection(onResult: show)
                    AirconCard(sending: sending) { Task { await send() } }
                    ScheduleSection(model: schedule) { at in await saveSchedule(at) }
                }
                .padding(.horizontal)
                .padding(.bottom, 12)
                .animation(.easeOut(duration: 0.2), value: schedule.current)
            }
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .bottom) { sendDock }
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

    /// 画面下端に固定する送信ボタンと、今送る内容の要約
    private var sendDock: some View {
        let setting = store.setting
        return VStack(spacing: 8) {
            HStack(spacing: 6) {
                if store.hasUnsentChanges {
                    Circle().fill(.orange).frame(width: 7, height: 7)
                    Text("未送信 ·")
                } else {
                    Text("送信済み ·")
                }
                Text(Setting.summary(setting))
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)

            Button {
                Task { await send() }
            } label: {
                ZStack {
                    if sending {
                        ProgressView().tint(.white)
                    } else {
                        Text(setting.power ? "今すぐ送る" : "電源OFFを送る").font(.headline)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 36)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .tint(setting.power ? setting.mode.color : .gray)
            .disabled(sending)
        }
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.bar)
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

    private func cancelSchedule() async {
        if let error = await schedule.cancel() {
            show(Toast(message: error, isSuccess: false))
        } else {
            show(Toast(message: "予約を取り消しました", isSuccess: true))
        }
    }
}
