import Foundation

// 設定値の正本（ADR-015）。端末に保存し、操作ごとに全項目を送る。
// ショートカットやウィジェットから送った設定も同じ場所（SharedStore）に入るので、前面に戻るたびに読み直す。
@MainActor
final class SettingStore: ObservableObject {
    @Published var setting: Setting {
        didSet {
            if setting != oldValue { SharedStore.lastSetting = setting }
        }
    }

    /// 最後にエアコンへ送って受け付けられた設定。画面の「未送信」表示に使う。
    /// 保存は RemoteActions.sendAircon が行うので、ここでは画面に反映するだけ
    @Published var lastSent: Setting?

    var hasUnsentChanges: Bool { lastSent != setting }

    init() {
        setting = SharedStore.lastSetting
        lastSent = SharedStore.lastSentSetting
    }

    func reload() {
        let saved = SharedStore.lastSetting
        if saved != setting { setting = saved }
        let sent = SharedStore.lastSentSetting
        if sent != lastSent { lastSent = sent }
    }
}
