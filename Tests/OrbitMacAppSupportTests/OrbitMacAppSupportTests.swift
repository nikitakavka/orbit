import Foundation
import Testing
@testable import OrbitMacAppSupport

struct OrbitApplicationLocationTests {
    @Test
    func recognizesSystemAndUserApplicationsDirectories() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

        #expect(OrbitApplicationLocation.isInstalledInApplications(
            appURL: URL(fileURLWithPath: "/Applications/Orbit.app"),
            homeDirectoryURL: home
        ))
        #expect(OrbitApplicationLocation.isInstalledInApplications(
            appURL: URL(fileURLWithPath: "/Users/tester/Applications/Orbit.app"),
            homeDirectoryURL: home
        ))
    }

    @Test
    func rejectsDownloadsDiskImagesAndBareExecutables() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

        #expect(!OrbitApplicationLocation.isInstalledInApplications(
            appURL: URL(fileURLWithPath: "/Users/tester/Downloads/Orbit.app"),
            homeDirectoryURL: home
        ))
        #expect(!OrbitApplicationLocation.isInstalledInApplications(
            appURL: URL(fileURLWithPath: "/Volumes/Orbit/Orbit.app"),
            homeDirectoryURL: home
        ))
        #expect(!OrbitApplicationLocation.isInstalledInApplications(
            appURL: URL(fileURLWithPath: "/Applications/orbit-menubar"),
            homeDirectoryURL: home
        ))
    }
}

struct OrbitUpdaterConfigurationTests {
    @Test
    func acceptsSecureProductionConfiguration() {
        let configuration = OrbitUpdaterConfiguration(
            isApplicationBundle: true,
            feedURL: URL(string: "https://nikitakavka.github.io/orbit/appcast.xml"),
            publicEDKey: "public-key"
        )

        #expect(configuration.isValid)
        #expect(configuration.validationError == nil)
    }

    @Test
    func acceptsLoopbackHTTPForEndToEndTesting() {
        let configuration = OrbitUpdaterConfiguration(
            isApplicationBundle: true,
            feedURL: URL(string: "http://127.0.0.1:8765/appcast.xml"),
            publicEDKey: "public-key"
        )

        #expect(configuration.isValid)
    }

    @Test
    func rejectsMissingKeyAndInsecureRemoteFeed() {
        let missingKey = OrbitUpdaterConfiguration(
            isApplicationBundle: true,
            feedURL: URL(string: "https://example.com/appcast.xml"),
            publicEDKey: nil
        )
        let insecureFeed = OrbitUpdaterConfiguration(
            isApplicationBundle: true,
            feedURL: URL(string: "http://example.com/appcast.xml"),
            publicEDKey: "public-key"
        )

        #expect(!missingKey.isValid)
        #expect(!insecureFeed.isValid)
    }
}

@MainActor
private final class MockLoginItemService: OrbitLoginItemServicing {
    var status: OrbitLaunchAtLoginStatus
    var registerCallCount = 0
    var unregisterCallCount = 0

    init(status: OrbitLaunchAtLoginStatus) {
        self.status = status
    }

    func register() throws {
        registerCallCount += 1
        status = .enabled
    }

    func unregister() async throws {
        unregisterCallCount += 1
        status = .notRegistered
    }
}

@MainActor
struct OrbitLaunchAtLoginControllerTests {
    private let appURL = URL(fileURLWithPath: "/Applications/Orbit.app")
    private let homeURL = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

    @Test
    func registersAndUnregistersMainApplication() async {
        let service = MockLoginItemService(status: .notRegistered)
        let controller = OrbitLaunchAtLoginController(
            service: service,
            appURL: appURL,
            homeDirectoryURL: homeURL
        )

        await controller.setEnabled(true)
        #expect(controller.status == .enabled)
        #expect(controller.isRegistered)
        #expect(service.registerCallCount == 1)

        await controller.setEnabled(false)
        #expect(controller.status == .notRegistered)
        #expect(!controller.isRegistered)
        #expect(service.unregisterCallCount == 1)
    }

    @Test
    func refusesRegistrationOutsideApplications() async {
        let service = MockLoginItemService(status: .notRegistered)
        let controller = OrbitLaunchAtLoginController(
            service: service,
            appURL: URL(fileURLWithPath: "/Users/tester/Downloads/Orbit.app"),
            homeDirectoryURL: homeURL
        )

        await controller.setEnabled(true)

        #expect(service.registerCallCount == 0)
        #expect(controller.status == .notRegistered)
        #expect(controller.errorMessage != nil)
    }

    @Test
    func treatsApprovalPendingServiceAsRegistered() async {
        let service = MockLoginItemService(status: .requiresApproval)
        let controller = OrbitLaunchAtLoginController(
            service: service,
            appURL: appURL,
            homeDirectoryURL: homeURL
        )

        #expect(controller.isRegistered)
        #expect(controller.statusTitle == "Waiting for macOS approval")

        await controller.setEnabled(false)
        #expect(service.unregisterCallCount == 1)
    }
}
