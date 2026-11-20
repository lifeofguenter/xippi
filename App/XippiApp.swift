import SwiftUI

@main
struct XippiApp: App {
    /// Closes the sessions when the app quits.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var launch: AppLaunch
    @State private var settings: AppSettings
    /// Away while idle or locked, and client state, for the sessions.
    @State private var idle: IdleMonitor
    /// The call UI, which every account's calls are attached to.
    @State private var calls: CallCoordinator
    /// Message and call notifications.
    @State private var notifications: NotificationController
    /// `xmpp:` links opened from outside.
    @State private var links: XMPPURIHandler
    @State private var presenter: MainWindowPresenter

    init() {
        // R83: a second launch hands over to the running Xippi and quits, before anything
        // opens the database.
        guard SingleInstance.claim() else { exit(0) }
        LaunchWarmUp.start()
        let settings = AppSettings()
        let presenter = MainWindowPresenter()
        let notifications = NotificationController(settings: settings, presenter: presenter)
        let calls = CallCoordinator(alerts: notifications)
        notifications.calls = calls
        let links = XMPPURIHandler(presenter: presenter)
        let idle = IdleMonitor(settings: settings)
        #if DEBUG || UITEST_HOOKS
            CallFixtures.attachIfTesting(to: calls)
            DebugSnapshot.calls = calls
            DebugSnapshot.notifications = notifications
            DebugSnapshot.links = links
        #endif
        _settings = State(initialValue: settings)
        _idle = State(initialValue: idle)
        _calls = State(initialValue: calls)
        _notifications = State(initialValue: notifications)
        _links = State(initialValue: links)
        _presenter = State(initialValue: presenter)
        let launch = AppLaunch.start(settings: settings, calls: calls, idle: idle)
        AppDelegate.model = launch.model
        AppDelegate.links = links
        if let model = launch.model {
            notifications.attach(to: model)
            links.attach(to: model)
            model.userStatus.follow(model)
        }
        _launch = State(initialValue: launch)
    }

    var body: some Scene {
        Window(Copy.appName, id: MainWindowPresenter.windowID) {
            Group {
                switch launch {
                case .ready(let model):
                    MainWindow(model: model)
                        .environment(settings)
                        .environment(links)
                        .preferredColorScheme(settings.appearance.colorScheme)
                case .failed(let reason):
                    ContentUnavailableView {
                        Label(
                            Copy.databaseFailed, systemImage: "externaldrive.badge.exclamationmark")
                    } description: {
                        Text(reason)
                            .font(.appBody)
                    }
                    .frame(minWidth: 480, minHeight: 320)
                }
            }
            .modifier(CallWindowPresenter(coordinator: calls, model: launch.model))
            .modifier(MainWindowOpener(presenter: presenter))
        }
        .defaultSize(width: 1120, height: 760)
        .commands {
            MainCommands(model: launch.model)
            ChannelCommands()
            ToolsCommands(model: launch.model, settings: settings)
        }
        CallWindowScene(coordinator: calls)
        ToolScenes(model: launch.model, settings: settings)
        Settings {
            SettingsView(settings: settings, model: launch.model)
                .preferredColorScheme(settings.appearance.colorScheme)
        }
        Window(Copy.status, id: StatusWindow.windowID) {
            StatusWindow(model: launch.model)
                .preferredColorScheme(settings.appearance.colorScheme)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        MenuBarExtra(isInserted: $settings.showMenuBarItem) {
            // The unread count is read inside the content's own body: read here, every
            // message would run this App body again and rebuild the main menu.
            MenuBarExtraContent(model: launch.model, presenter: presenter)
        } label: {
            MenuBarStatusLabel(model: launch.model)
        }
    }
}

/// Menu commands of the main window.
struct MainCommands: Commands {
    let model: AppModel?
    /// The main window's room and contact sheets.
    @FocusedValue(\.chatSheets) private var sheets

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button(Copy.newChat) { sheets?.sheet = .newChat }
                .keyboardShortcut("n")
                .disabled(sheets == nil)
            Button(Copy.joinRoom) { sheets?.sheet = .joinRoom }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(sheets == nil)
            Button(Copy.createRoom) { sheets?.sheet = .createRoom() }
                .disabled(sheets == nil)
            Button(Copy.addContact) { sheets?.sheet = .addContact }
                .disabled(sheets == nil)
        }
        CommandGroup(replacing: .saveItem) {
            // The file Quick Look shows, or the one of the message with the focus.
            let file = model?.fileToSave
            Button(Copy.saveAs) { model?.saveFileAs?() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(file == nil || file?.unavailable != nil)
                .help(file?.unavailable ?? "")
        }
        CommandGroup(after: .sidebar) {
            Button(Copy.goToChat) { model?.showQuickSwitcher() }
                .keyboardShortcut("k")
            Button(Copy.searchEverywhere) { model?.showSearchEverywhere() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Divider()
            Button(model?.inspectorVisible == true ? Copy.hideInspector : Copy.showInspector) {
                model?.inspectorVisible.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
        }
        CommandGroup(before: .textEditing) {
            Button(Copy.findInChat) { model?.showFindInChat() }
                .keyboardShortcut("f")
                .disabled(model?.hasSelection != true)
        }
    }
}
