import Testing
@testable import PowerLens

@MainActor
struct DashboardSceneControllerTests {
    @Test
    func showDashboardUsesRegisteredSceneAction() {
        let controller = DashboardSceneController()
        var openCount = 0

        controller.setOpenDashboardWindowAction {
            openCount += 1
        }

        controller.showDashboard()

        #expect(openCount == 1)
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
