import SwiftUI

// 照明（ADR-022）。操作画面のカードの1枚。押したボタンを1回だけ送る。
// 照明の今の状態は誰にもわからないので状態は表示せず、「最後に送ったボタン」だけを端末に覚えて薄く示す。
@MainActor
struct LightSection: View {
    /// 送信結果を操作画面のトーストに渡す
    let onResult: @MainActor (Toast) -> Void

    @State private var sending: LightButton?
    @AppStorage("lastLightButton") private var lastButtonRaw = ""
    @AppStorage("lastLightSentAt") private var lastSentAt: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("照明").font(.headline)
                Spacer()
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ForEach(LightButton.allCases) { button in
                    Button {
                        Task { await send(button) }
                    } label: {
                        tile(button)
                    }
                    .buttonStyle(.plain)
                    .disabled(sending != nil)
                }
            }
        }
        .card()
    }

    private func tile(_ button: LightButton) -> some View {
        let isLast = lastButton == button
        return VStack(spacing: 4) {
            if sending == button {
                ProgressView().frame(height: 26)
            } else {
                Image(systemName: button.systemImage).font(.title3).frame(height: 26)
            }
            Text(button.label).font(.footnote)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            isLast ? Color.yellow.opacity(0.25) : Color(.tertiarySystemFill),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text(verbatim: isLast ? "最後に送ったボタン" : ""))
    }

    private var lastButton: LightButton? { LightButton(rawValue: lastButtonRaw) }

    private var caption: String {
        guard let button = lastButton, lastSentAt > 0 else { return "押したボタンを1回送ります" }
        let date = Date(timeIntervalSince1970: lastSentAt)
        let time = Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .shortened)
        return "最後に送信: \(button.label) · \(time)"
    }

    private func send(_ button: LightButton) async {
        sending = button
        defer { sending = nil }
        // ウィジェットの「最後の操作」も更新するため、共通の入口から送る
        let outcome = await RemoteActions.sendLight(button)
        if outcome.isSuccess {
            lastButtonRaw = button.rawValue
            lastSentAt = Date().timeIntervalSince1970
            onResult(Toast(message: "照明「\(button.label)」を送りました", isSuccess: true))
        } else {
            onResult(Toast(outcome))
        }
    }
}
