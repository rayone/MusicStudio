import SwiftUI

/// Legacy wrapper redirecting to the Unified SettingsView with the API tab selected.
public struct SongwriterSettingsView: View {
    @ObservedObject var vm: StudioViewModel

    public init(vm: StudioViewModel) {
        self.vm = vm
    }

    public var body: some View {
        SettingsView(vm: vm)
            .onAppear {
                vm.settingsTab = .api
            }
    }
}
