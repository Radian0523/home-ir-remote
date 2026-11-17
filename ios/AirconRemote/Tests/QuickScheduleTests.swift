import XCTest

@testable import AirconRemote

// 操作画面の「よく使う予約」ボタン。時刻の決め方と、予約に載せる電源
final class QuickScheduleTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return c
    }()

    private func tokyo(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    func testOnAt0720IsTodayBeforeSevenTwenty() {
        let now = tokyo(2026, 11, 17, 6, 0)
        XCTAssertEqual(QuickSchedule.onAt0720.executeAt(now: now, calendar: calendar), tokyo(2026, 11, 17, 7, 20))
    }

    func testOnAt0720IsTomorrowAfterSevenTwenty() {
        let now = tokyo(2026, 11, 17, 23, 30)
        XCTAssertEqual(QuickSchedule.onAt0720.executeAt(now: now, calendar: calendar), tokyo(2026, 11, 18, 7, 20))
    }

    func testRelativeTimersCountFromNow() {
        let now = tokyo(2026, 11, 17, 23, 30)
        XCTAssertEqual(QuickSchedule.onIn7h20m.executeAt(now: now), now.addingTimeInterval(440 * 60))
        XCTAssertEqual(QuickSchedule.offIn10m.executeAt(now: now), now.addingTimeInterval(10 * 60))
    }

    func testPower() {
        XCTAssertTrue(QuickSchedule.onAt0720.power)
        XCTAssertTrue(QuickSchedule.onIn7h20m.power)
        XCTAssertFalse(QuickSchedule.offIn10m.power)
    }

    func testSettingKeepsBaseAndSwapsPower() {
        let base = Setting(power: false, mode: .heat, temp: 22, fan: .two, vane: .low)
        XCTAssertEqual(QuickSchedule.onAt0720.setting(base: base), Setting(power: true, mode: .heat, temp: 22, fan: .two, vane: .low))
        var on = base
        on.power = true
        XCTAssertEqual(QuickSchedule.offIn10m.setting(base: on), base)
    }
}
