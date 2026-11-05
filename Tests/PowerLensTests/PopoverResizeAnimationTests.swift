import Testing
@testable import PowerLens

struct PopoverResizeAnimationTests {
    private let ease = PopoverResizeAnimation.curve

    @Test
    func curveStartsAndEndsAtTheEndpoints() {
        #expect(ease.value(at: 0) == 0)
        #expect(abs(ease.value(at: 1) - 1) < 1e-6)
        #expect(ease.value(at: -0.5) == 0)
        #expect(abs(ease.value(at: 1.5) - 1) < 1e-6)
    }

    @Test
    func curveEasesInAndOutSymmetrically() {
        #expect(abs(ease.value(at: 0.5) - 0.5) < 1e-6)
        #expect(ease.value(at: 0.1) < 0.1)
        #expect(abs(ease.value(at: 0.25) + ease.value(at: 0.75) - 1) < 1e-6)
    }

    @Test
    func curveNeverMovesBackward() {
        let samples = stride(from: 0.0, through: 1.0, by: 0.01).map(ease.value(at:))
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 })
    }
}
