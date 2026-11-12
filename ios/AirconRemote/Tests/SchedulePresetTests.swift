import XCTest

@testable import AirconRemote

// 予約時刻のチップ（操作画面）。「5分後」などは基準時刻から数え、「時刻を指定」は指定値をそのまま使う
final class SchedulePresetTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let custom = Date(timeIntervalSince1970: 1_800_100_000)

    func testRelativePresetsCountFromNow() {
        XCTAssertEqual(SchedulePreset.in5.executeAt(now: now, custom: custom), now.addingTimeInterval(5 * 60))
        XCTAssertEqual(SchedulePreset.in30.executeAt(now: now, custom: custom), now.addingTimeInterval(30 * 60))
        XCTAssertEqual(SchedulePreset.in60.executeAt(now: now, custom: custom), now.addingTimeInterval(60 * 60))
        XCTAssertEqual(SchedulePreset.in120.executeAt(now: now, custom: custom), now.addingTimeInterval(120 * 60))
    }

    func testCustomUsesPickedDate() {
        XCTAssertEqual(SchedulePreset.custom.executeAt(now: now, custom: custom), custom)
    }

    func testDefaultIsFiveMinutesFirst() {
        // デフォルト予約時間は5分後（c93f55a）。チップの先頭も5分後にしておく
        XCTAssertEqual(SchedulePreset.allCases.first, .in5)
    }

    func testModesHaveIcons() {
        for m in Mode.allCases { XCTAssertFalse(m.systemImage.isEmpty) }
    }
}
