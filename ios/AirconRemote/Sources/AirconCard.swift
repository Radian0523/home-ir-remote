import SwiftUI

// エアコンの設定カード。温度を大きく見せ、モード・風量・風向は選択肢を常に表示して1タップで選べるようにする。
// 電源ボタンだけは押した瞬間に送る（リモコンと同じ。設定を変えるのは稀で、ON/OFF が操作のほとんどのため）。
// 温度・モード・風量・風向は設定値（SettingStore）を変えるだけで、送信は操作画面下端の「今すぐ送る」が行う。
struct AirconCard: View {
    @EnvironmentObject private var store: SettingStore

    /// 送信中か。電源ボタンにくるくるを出し、二重に押せないようにする
    let sending: Bool
    /// 今の設定を送る。電源ボタンを押したときに呼ぶ
    let onPowerToggle: () -> Void

    private var setting: Setting { store.setting }
    private var tint: Color { setting.mode.color }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            VStack(alignment: .leading, spacing: 14) {
                temperature
                field("モード") { modes }
                field("風量") {
                    Picker("風量", selection: $store.setting.fan) {
                        ForEach(Fan.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                field("風向") { vanes }
            }
            .disabled(!setting.power)
            .opacity(setting.power ? 1 : 0.35)
        }
        .card()
        .animation(.easeOut(duration: 0.2), value: setting)
        .sensoryFeedback(.selection, trigger: setting)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("エアコン").font(.headline)
                Text(setting.power ? setting.mode.label : "停止中")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(setting.power ? tint : Color.secondary)
                if !setting.power {
                    // 電源ボタン1回で何が送られるかを先に見せる
                    Text("電源ボタンで \(setting.mode.label) \(setting.temp)℃ で運転")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                store.setting.power.toggle()
                onPowerToggle()
            } label: {
                ZStack {
                    if sending {
                        ProgressView().tint(setting.power ? Color.white : Color.secondary)
                    } else {
                        Image(systemName: "power").font(.title3.weight(.semibold))
                    }
                }
                .frame(width: 56, height: 56)
                .foregroundStyle(setting.power ? Color.white : Color.secondary)
                .background(setting.power ? tint : Color(.tertiarySystemFill), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(sending)
            .accessibilityLabel("電源")
            .accessibilityValue(setting.power ? "オン" : "オフ")
            .accessibilityHint("押すとすぐエアコンに送ります")
        }
    }

    private var temperature: some View {
        let range = Setting.tempRange
        return VStack(spacing: 4) {
            HStack {
                tempButton("minus", label: "温度を下げる", enabled: setting.temp > range.lowerBound) {
                    if store.setting.temp > range.lowerBound { store.setting.temp -= 1 }
                }
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(setting.temp)")
                        .font(.system(size: 64, weight: .light, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(setting.temp)))
                    Text("℃").font(.title2.weight(.medium)).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("温度 \(setting.temp)℃")
                Spacer()
                tempButton("plus", label: "温度を上げる", enabled: setting.temp < range.upperBound) {
                    if store.setting.temp < range.upperBound { store.setting.temp += 1 }
                }
            }
            ProgressView(
                value: Double(setting.temp - range.lowerBound),
                total: Double(range.upperBound - range.lowerBound)
            )
            .tint(tint)
            .accessibilityHidden(true)
            HStack {
                Text("\(range.lowerBound)")
                Spacer()
                Text("\(range.upperBound)")
            }
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
    }

    private func tempButton(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title2.weight(.semibold))
                .frame(width: 56, height: 56)
                .background(Color(.tertiarySystemFill), in: Circle())
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private var modes: some View {
        HStack(spacing: 6) {
            ForEach(Mode.allCases) { mode in
                let selected = setting.mode == mode
                Button {
                    store.setting.mode = mode
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: mode.systemImage)
                            .font(.body.weight(.semibold))
                            .frame(height: 22)
                        Text(mode.label).font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .background(
                        selected ? mode.color : Color(.tertiarySystemFill),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private var vanes: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Vane.allCases) { vane in
                    ChipButton(label: vane.label, selected: setting.vane == vane, tint: tint) {
                        store.setting.vane = vane
                    }
                }
            }
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }
}
