# 引き継ぎ: iOS の各所から操作する（App Intents / ウィジェット / コントロール）

- ブランチ: `feat/ios-app-intents`
- PR: https://github.com/Radian0523/home-ir-remote/pull/2
- 設計: `docs/adr.md` ADR-023、`docs/design.md` §6.1

## 今の状態

- 実装・ドキュメント・テスト追加は済み、push 済み
- **一度もビルドしていない**（作業環境が Linux で Xcode が無かったため）。App Intents / WidgetKit の API は記憶に頼って書いた
- iPhone へのインストールも未実施

## 次のセッションでやること（Mac で）

1. ビルドを通す
   ```bash
   git fetch origin feat/ios-app-intents && git checkout feat/ios-app-intents
   cd ios/AirconRemote
   xcodegen generate && open AirconRemote.xcodeproj
   ```
2. Signing & Capabilities で `AirconRemote` と `AirconWidgets` の**両方に同じ Team** を選ぶ（無料 Apple ID 可）
3. コンパイルエラーを直す（下の「怪しい箇所」から見る）
4. `AirconRemoteTests` を実行（24 件。新規 9 件は `Tests/IntentLogicTests.swift`）
5. 実機（iPhone）にインストールし、下の「実機確認」をする
6. 直した分をコミットして同じブランチに push

## 怪しい箇所（コンパイルエラーが出やすい順）

| 場所 | 懸念 |
|---|---|
| `Widgets/Controls.swift` | `AppIntentControlConfiguration(kind:provider:)`、`AppIntentControlValueProvider` のメソッド形、`ControlConfigurationIntent` の `perform` 要否、`.promptsForUserConfiguration()` |
| `Shared/Intents.swift` | `AppEnum` の `caseDisplayRepresentations` を文字列リテラルで書いた部分、`IntentDialog(stringLiteral:)`、`LocalizedStringResource(stringLiteral:)`、`static var isDiscoverable` |
| `Shared/Intents.swift` | 省略可能な `@Parameter(title:description:) var temp: Int?` |
| `Sources/AppShortcuts.swift` | 引数付きフレーズ `\(\.$button)`、`AppShortcut(intent:phrases:shortTitle:systemImageName:)` |
| `Sources/AirconRemoteApp.swift` | Scene への `.onChange(of: scenePhase) { _, phase in }` |
| `Widgets/QuickActionWidget.swift` | `WidgetConfigurationIntent` の暗黙の `init()` |
| Swift 6 / 厳格な並行性 | `SWIFT_VERSION: "5.0"` 前提。`static var` や `Task` 内の `completion` 捕捉で警告が出ても動作上は問題ない想定 |

## 実機確認

- [ ] 既存の APP_TOKEN が引き継がれる（アプリを一度起動すると Keychain 共有グループへ移る）
- [ ] ホーム画面の「照明」「エアコン」「ワンタップ操作」ウィジェットが「未設定」にならず、ボタンで送れる
- [ ] コントロールセンターに「おうちリモコン」「おやすみタイマー」を置いて送れる（iOS 18+）
- [ ] ショートカット App に「おうちリモコン」のアクションが出る
- [ ] Siri: 「おうちリモコンで照明を消灯にして」「おうちリモコンでエアコンをつけて」「おうちリモコンの予約を確認」
- [ ] ショートカットで送った設定がアプリの画面にも反映される（前面に戻ったとき）
- [ ] 無料 Apple ID で Keychain 共有の権限（`keychain-access-groups`）付きで署名できる

## 設計の要点（変えるなら ADR-023 も直す）

- アプリと拡張の共有は **Keychain の共有アクセスグループ** `<Team ID>.local.aircon.shared` だけ。App Groups は無料 Apple ID で不安定なので使わない
  - グループ名は Info.plist の `AppIdentifierPrefix`（`$(AppIdentifierPrefix)`）から実行時に組み立てる（`Shared/Keychain.swift`）
  - 権限が無い場合（`errSecMissingEntitlement`）はアプリ既定のグループに保存し、アプリ単体では動く
- 共有する値: APP_TOKEN、Worker URL、前回の設定（ADR-015 の正本）、最後の送信結果（`Shared/SharedStore.swift`）
- どこから操作しても `Shared/RemoteActions.swift` を通る（結果の記録とウィジェット更新）
- エアコンの省略可能な引数は前回の設定で補う。202 になった設定を前回の設定として保存
- 状態は取れないので、コントロールは「1 回送るボタン」（トグルにしない）
- 202 は「送信要求を受け付けました」まで（ADR-012）。失敗はインテントのエラーにする
- ウィジェット拡張は iOS 18+、アプリ本体は iOS 17+。`developmentLanguage: ja`（Siri フレーズのため）
- サーバー側（Worker / DO / ESP32）は変更なし

## ファイル構成（変更分）

```text
ios/AirconRemote/
├ project.yml                 AirconWidgets ターゲット追加、entitlements、developmentLanguage: ja
├ Sources/                    アプリ本体
│  ├ AppShortcuts.swift        新規: Siri / Spotlight / アクションボタンのフレーズ
│  ├ AirconRemote.entitlements 新規
│  └ AirconRemoteApp.swift ほか 起動時の移行、RemoteActions 経由に変更
├ Shared/                     アプリと拡張の両方にコンパイル
│  ├ Models / APIClient / ScheduleAPI / Keychain   Sources/ から移動（Keychain は共有グループ対応）
│  ├ SharedStore.swift         新規
│  ├ RemoteActions.swift       新規
│  └ Intents.swift             新規: 全インテントと QuickAction
├ Widgets/                    新規: ウィジェット拡張
└ Tests/IntentLogicTests.swift 新規
```

## 今回やらなかったこと

- Live Activity（予約のカウントダウン表示など）
- Apple Watch 専用アプリ（Watch からはショートカット経由で操作可）
- 照明・エアコンの状態表示
