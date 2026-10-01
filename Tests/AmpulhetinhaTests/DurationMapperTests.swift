import XCTest
@testable import Ampulhetinha

final class DurationMapperTests: XCTestCase {
    // 12:17:40 de hoje
    let now = Calendar.current.date(bySettingHour: 12, minute: 17, second: 40, of: Date())!

    /// Opção mais perto de `raw` minutos, como (minutos, "HH:mm:ss" do disparo).
    func pick(_ raw: Double, fine: Bool = false) -> (Int, String) {
        let c = DurationMapper.snap(raw, fine: fine, now: now)
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        return (c.minutes, f.string(from: c.start.addingTimeInterval(TimeInterval(c.minutes * 60))))
    }

    func testIntercalaRelativosEHorariosRedondos() {
        XCTAssertEqual(pick(3).0, 3);  XCTAssertEqual(pick(3).1, "12:20:00")
        XCTAssertEqual(pick(5).0, 5);  XCTAssertEqual(pick(5).1, "12:22:40")
        XCTAssertEqual(pick(8).0, 8);  XCTAssertEqual(pick(8).1, "12:25:00")
        XCTAssertEqual(pick(10).0, 10); XCTAssertEqual(pick(10).1, "12:27:40")
    }

    func testOptionAndaDeMinutoEmMinuto() {
        XCTAssertEqual(pick(7, fine: true).0, 7)
        XCTAssertEqual(pick(7, fine: true).1, "12:24:40")
    }

    func testRedondoColadoNoAgoraPula() {
        // 12:19:50 → 12:20 está a 10 s: a primeira opção redonda vira 12:25.
        let late = Calendar.current.date(bySettingHour: 12, minute: 19, second: 50, of: Date())!
        let c = DurationMapper.snap(1, fine: false, now: late)
        XCTAssertEqual(c.minutes, 5)
        XCTAssertGreaterThan(c.start.addingTimeInterval(TimeInterval(c.minutes * 60)).timeIntervalSince(late), 60)
    }

    func testDistancia400PrimeiraHoraDepois100PorHora() {
        let z = DurationMapper.deadZone
        XCTAssertEqual(DurationMapper.choice(distance: z + 400, fine: true, now: now).minutes, 60)
        XCTAssertEqual(DurationMapper.choice(distance: z + 200, fine: true, now: now).minutes, 30)
        XCTAssertEqual(DurationMapper.choice(distance: z + 500, fine: true, now: now).minutes, 120)
        XCTAssertEqual(DurationMapper.choice(distance: z - 1, fine: true, now: now).minutes, 0)
    }
}
