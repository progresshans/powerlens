import Testing
@testable import PowerLens

@MainActor
struct DashboardSceneControllerTests {
    @Test
    func reopenWithoutVisibleWindowsRequestsDashboard() {
        let controller = DashboardSceneController()
        var openCount = 0

        controller.setOpenDashboardWindowAction {
            openCount += 1
        }

        let shouldContinueDefaultHandling = controller.handleReopen(hasVisibleWindows: false)

        #expect(openCount == 1)
        #expect(shouldContinueDefaultHandling == false)
    }

    @Test
    func reopenWithVisibleWindowsKeepsDefaultHandling() {
        let controller = DashboardSceneController()
        var openCount = 0

        controller.setOpenDashboardWindowAction {
            openCount += 1
        }

        let shouldContinueDefaultHandling = controller.handleReopen(hasVisibleWindows: true)

        #expect(openCount == 0)
        #expect(shouldContinueDefaultHandling == true)
    }

    @Test
    func pendingOpenRequestIsDeliveredWhenSceneActionArrives() {
        let controller = DashboardSceneController()
        var openCount = 0

        controller.showDashboard()
        controller.setOpenDashboardWindowAction {
            openCount += 1
        }

        #expect(openCount == 1)
    }
}
