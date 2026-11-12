import SwiftUI

// 操作画面で共通に使う部品（カード、チップ、トースト、モードの色）。

extension Mode {
    /// モードごとの色。温度バー・選択中の項目・送信ボタンをこの色でそろえる
    var color: Color {
        switch self {
        case .auto: .purple
        case .cool: .blue
        case .dry: .teal
        case .heat: .orange
        case .fan: .gray
        }
    }
}

extension View {
    /// 操作画面のカード。Form の行の代わりに、まとまりごとに角丸の面で区切る
    func card() -> some View {
        padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// 選択肢を常に見せる丸いボタン。風向と予約時刻に使う
struct ChipButton: View {
    let label: String
    let selected: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? tint : Color(.tertiarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 画面上部に出る結果表示。成功は数秒で消え、失敗はタップするまで残す
struct Toast: Equatable, Identifiable {
    let id = UUID()
    let message: String
    let isSuccess: Bool

    init(message: String, isSuccess: Bool) {
        self.message = message
        self.isSuccess = isSuccess
    }

    init(_ outcome: CommandOutcome) {
        self.init(message: outcome.message, isSuccess: outcome.isSuccess)
    }
}

struct ToastView: View {
    let toast: Toast

    var body: some View {
        Label {
            Text(toast.message).font(.subheadline.weight(.semibold))
        } icon: {
            Image(systemName: toast.isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(toast.isSuccess ? Color.green : Color.orange)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .padding(.horizontal)
        .accessibilityAddTraits(.isStaticText)
    }
}
