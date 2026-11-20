import SwiftUI

/// What the main window restores on relaunch beside the open chat and its scroll position
/// (`MainWindow`): the sidebar's filter and whether the inspector is open. A chat that was
/// deleted meanwhile opens nothing: the app model drops a selection the chat list lacks.
struct WindowRestoration: ViewModifier {
    @Bindable var model: AppModel
    @SceneStorage("sidebarFilter") private var storedFilter = SidebarFilter.all.rawValue
    @SceneStorage("inspectorVisible") private var storedInspector = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                if let filter = SidebarFilter(rawValue: storedFilter), filter != model.sidebarFilter
                {
                    model.sidebarFilter = filter
                }
                if storedInspector != model.inspectorVisible {
                    model.inspectorVisible = storedInspector
                }
            }
            .onChange(of: model.sidebarFilter) { _, filter in
                storedFilter = filter.rawValue
            }
            .onChange(of: model.inspectorVisible) { _, visible in
                storedInspector = visible
            }
    }
}
