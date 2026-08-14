import Combine
import Foundation
import OrbitMacAppSupport

@MainActor
final class OrbitMenuBarPresentationModel: ObservableObject {
    @Published var onboardingViewModel: OrbitOnboardingViewModel?
    let updaterController: OrbitUpdaterController

    private var updaterObserver: AnyCancellable?

    convenience init() {
        self.init(updaterController: OrbitUpdaterController())
    }

    init(updaterController: OrbitUpdaterController) {
        self.updaterController = updaterController
        updaterObserver = updaterController.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }
}
