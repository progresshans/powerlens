import Testing
@testable import PowerLens

struct RollingDigitsTests {
    @Test
    func onlyChangedDigitsRoll() {
        #expect(RollingDigits.plan(from: "15.0W", to: "18.0W") == .roll(positions: [1], upward: true))
        #expect(RollingDigits.plan(from: "18.4W", to: "12.9W") == .roll(positions: [1, 3], upward: false))
    }

    @Test
    func shapeChangesRedrawWithoutMotion() {
        #expect(RollingDigits.plan(from: "9.9W", to: "10.0W") == .redraw)
        #expect(RollingDigits.plan(from: "--", to: "7.2W") == .redraw)
        #expect(RollingDigits.plan(from: "", to: "7.2W") == .redraw)
    }

    @Test
    func identicalReadingsDoNothing() {
        #expect(RollingDigits.plan(from: "7.2W", to: "7.2W") == .unchanged)
    }
}
