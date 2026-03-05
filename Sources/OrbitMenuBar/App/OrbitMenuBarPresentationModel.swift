import Foundation

@MainActor
final class OrbitMenuBarPresentationModel: ObservableObject {
    @Published var onboardingViewModel: OrbitOnboardingViewModel?
}
