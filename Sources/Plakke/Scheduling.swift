import AppKit

extension Timer {
    /// Schedules a repeating timer that keeps firing while a menu or any other tracking loop is up.
    ///
    /// `Timer.scheduledTimer` registers in `.default` only, which is why an open menu-bar menu used
    /// to suspend clipboard polling and let a secret outlive its countdown. `.common` alone isn't
    /// enough either — event tracking is only a member of the common set once AppKit says so — so
    /// both modes are registered explicitly.
    @discardableResult
    static func plakkeRepeating(_ interval: TimeInterval,
                                tolerance: TimeInterval = 0,
                                _ body: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in body() }
        timer.tolerance = tolerance
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        return timer
    }
}
