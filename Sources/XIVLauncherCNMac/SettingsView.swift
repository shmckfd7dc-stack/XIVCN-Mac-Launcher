import AppKit
import SwiftUI

private final class WindowControlAlignmentNSView: NSView {
    var onCenterYChange: ((CGFloat) -> Void)?
    private var lastCenterY: CGFloat?

    override func layout() {
        super.layout()
        reportCenterY()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportCenterY()
    }

    func reportCenterY() {
        guard window != nil else { return }
        let centerY = convert(bounds, to: nil).midY
        guard lastCenterY != centerY else { return }
        lastCenterY = centerY
        onCenterYChange?(centerY)
    }

    func remeasureAfterWindowTransition() {
        lastCenterY = nil
        needsLayout = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lastCenterY = nil
            self.window?.contentView?.layoutSubtreeIfNeeded()
            self.reportCenterY()
        }
    }
}

private struct WindowControlAlignmentAnchor: NSViewRepresentable {
    let onCenterYChange: (CGFloat) -> Void
    let revision: Int

    func makeNSView(context: Context) -> WindowControlAlignmentNSView {
        let view = WindowControlAlignmentNSView()
        view.onCenterYChange = onCenterYChange
        context.coordinator.revision = revision
        return view
    }

    func updateNSView(_ view: WindowControlAlignmentNSView, context: Context) {
        view.onCenterYChange = onCenterYChange
        view.needsLayout = true
        guard context.coordinator.revision != revision else { return }
        context.coordinator.revision = revision
        view.remeasureAfterWindowTransition()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var revision = 0
    }
}

private struct WinePrefixSettingsSnapshot: Equatable {
    let macOSScalingEnabled: Bool
    let leftOptionIsAlt: Bool
    let rightOptionIsAlt: Bool
    let leftCommandIsControl: Bool
    let rightCommandIsControl: Bool

    init(_ settings: LauncherSettings) {
        macOSScalingEnabled = settings.macOSScalingEnabled
        leftOptionIsAlt = settings.leftOptionIsAlt
        rightOptionIsAlt = settings.rightOptionIsAlt
        leftCommandIsControl = settings.leftCommandIsControl
        rightCommandIsControl = settings.rightCommandIsControl
    }
}

enum LauncherDestination: String, CaseIterable, Identifiable {
    case home, general, graphics, account, game, dalamud, advanced

    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return "主页"
        case .general: return "通用"
        case .account: return "账号"
        case .game: return "游戏"
        case .graphics: return "图形"
        case .dalamud: return "Dalamud"
        case .advanced: return "高级"
        }
    }
    var icon: String {
        switch self {
        case .home: return "house"
        case .general: return "gear"
        case .account: return "person.crop.circle"
        case .game: return "gamecontroller"
        case .graphics: return "display"
        case .dalamud: return "puzzlepiece.extension"
        case .advanced: return "wrench.and.screwdriver"
        }
    }
}

struct LauncherRootView: View {
    @ObservedObject var app: AppDelegate
    @ObservedObject var store: SettingsStore
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.colorScheme) private var colorScheme
    @State private var destination: LauncherDestination = .home
    @State private var sidebarVisible = true
    @State private var sidebarWidth: CGFloat = 220
    @State private var sidebarDragStartWidth: CGFloat?
    @State private var sidebarDividerHovered = false
    @State private var account: String
    @State private var password: String
    @State private var passwordVisible: Bool
    @State private var selectedQuickAccount: String
    @State private var loginInputIssue: CNLoginInputIssue?
    @FocusState private var focusedLoginField: CNLoginInputField?
    private let bundledLauncherIcon: NSImage

    init(app: AppDelegate, store: SettingsStore) {
        self.app = app
        self.store = store
        let savedAccounts = store.savedAccounts
        let quickAccounts = savedAccounts.filter(\.hasQuickLogin)
        let initialAccount = quickAccounts.contains(where: { $0.account == store.settings.cnAccount })
            ? store.settings.cnAccount
            : (quickAccounts.first?.account ?? savedAccounts.first?.account ?? store.settings.cnAccount)
        _account = State(initialValue: initialAccount)
        // Password login is intentionally session-only. Persistent login uses
        // the server-issued 30-day secret, never a silently stored password.
        _password = State(initialValue: "")
        _passwordVisible = State(initialValue: false)
        _selectedQuickAccount = State(initialValue: initialAccount)
        _loginInputIssue = State(initialValue: nil)
        if let url = Bundle.main.url(forResource: "XIVLauncherCNMac", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            bundledLauncherIcon = image
        } else {
            bundledLauncherIcon = NSApplication.shared.applicationIconImage
        }
    }

    var body: some View {
        ZStack {
            LauncherBackdrop(tint: store.settings.accentTint)
            Group {
                if app.showsFirstLaunchSetup {
                    FirstLaunchSetupView(app: app, store: store)
                        .transition(.opacity)
                } else {
                    launcherContent
                        .transition(.opacity)
                }
            }
        }
        .animation(.snappy(duration: 0.2), value: app.showsFirstLaunchSetup)
        .launcherTheme(store.settings.accentTint)
        .preferredColorScheme(app.resolvedColorScheme)
        .onReceive(NotificationCenter.default.publisher(for: .openLauncherSettings)) { _ in
            guard !app.showsFirstLaunchSetup else { return }
            destination = .general
        }
        .onReceive(NotificationCenter.default.publisher(for: .openLauncherHome)) { _ in
            guard !app.showsFirstLaunchSetup else { return }
            destination = .home
        }
        .onChange(of: store.settings.appearance) { _, mode in
            app.applyAppearance(mode)
        }
        .onChange(of: WinePrefixSettingsSnapshot(store.settings)) { _, _ in
            app.scheduleWinePrefixSettingsSynchronization()
        }
        .onChange(of: store.settings.cnAccount) { _, value in
            guard value != account else { return }
            account = value
            selectedQuickAccount = value
            password = ""
            passwordVisible = false
        }
        .onChange(of: app.authState) { _, state in
            if case .authenticated = state {
                password = ""
                passwordVisible = false
                loginInputIssue = nil
            }
        }
        .onChange(of: app.importedWeGameCredentials) { _, credentials in
            guard let credentials else { return }
            account = credentials.userID
            password = credentials.token
            passwordVisible = false
            store.settings.selectedLoginMethod = .weGame
            loginInputIssue = nil
        }
        .onAppear {
            app.normalizeLoginMethodSelection()
            app.applyAppearance(store.settings.appearance)
        }
        .onExitCommand {
            if !app.showsFirstLaunchSetup, destination != .home { destination = .home }
        }
    }

    private var launcherContent: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
            // Keep the material and List alive while collapsing. Recreating
            // both during the transition makes the title-bar control flash
            // and forces the full sidebar hierarchy to lay out every frame.
            HStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    if appearsActive {
                        ZStack {
                            Rectangle()
                                .fill(colorScheme == .dark
                                      ? Color(red: 0.12, green: 0.12, blue: 0.13).opacity(0.44)
                                      : Color.white.opacity(0.28))
                            LauncherSidebarMaterial()
                        }
                    } else {
                        Rectangle().fill(Color(nsColor: .underPageBackgroundColor).opacity(0.96))
                    }
                    List {
                        sidebarLabel(LauncherDestination.home)
                        Section("设置") {
                            ForEach(LauncherDestination.allCases.filter { $0 != .home }) { item in
                                sidebarLabel(item)
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                    .padding(.top, 46)
                }
                .frame(width: sidebarWidth)
                .frame(maxHeight: .infinity, alignment: .topLeading)

                sidebarDragHandle
            }
            .frame(width: sidebarWidth + 1)
            .frame(width: sidebarVisible ? sidebarWidth + 1 : 0, alignment: .trailing)
            .clipped()
            .allowsHitTesting(sidebarVisible)
            .accessibilityHidden(!sidebarVisible)

            Group {
                if destination == .home {
                    home
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                } else {
                    SettingsView(app: app, store: store, section: destination)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .id(destination)
            .animation(.snappy(duration: 0.2), value: destination)
            .frame(minWidth: 540, maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, sidebarVisible ? 0 : 46)
            }

            // Use the root layout coordinate space. macOS rebuilds title-bar
            // safe-area overlays after zoom and full-screen transitions.
            sidebarToggleButton
                .background {
                    WindowControlAlignmentAnchor(
                        onCenterYChange: { centerY in
                            app.alignWindowControls(toWindowY: centerY)
                        },
                        revision: app.windowControlAlignmentRevision
                    )
                }
                .padding(.leading, 82)
                .padding(.top, 8)
        }
        .animation(.smooth(duration: 0.2), value: sidebarVisible)
        .ignoresSafeArea(.container, edges: .top)
        .background(LauncherTheme.pageFill(for: colorScheme))
        .sheet(isPresented: $app.showsGameNotFound) {
            GameNotFoundView(app: app)
                .frame(width: 500, height: 280)
                .presentationBackground(.clear)
        }
        .sheet(isPresented: $app.showsUpdateWindow) {
            UpdateProgressView(app: app)
                .frame(width: 500, height: 270)
                .presentationBackground(.clear)
                .interactiveDismissDisabled(app.isBusy || app.updateCompletionMessage != nil)
        }
        .sheet(isPresented: Binding(
            get: { app.runtimeResetPhase != nil },
            set: { if !$0 { app.dismissRuntimeResetWindow() } }
        )) {
            RuntimeResetProgressView(app: app, tint: store.settings.accentTint)
                .frame(width: 440, height: 230)
                .presentationBackground(.clear)
                .interactiveDismissDisabled(app.runtimeResetPhase == .running)
        }
        .alert("游戏下载", isPresented: $app.showsManagedGameDownloadPreparationNotice) {
            Button("好", role: .cancel) {}
        } message: {
            Text("游戏正在准备下载，下载进度会显示在主页。")
        }
    }

    private var sidebarDragHandle: some View {
        Color.clear
            .frame(width: 1)
            .background {
                Rectangle()
                    .fill(.primary.opacity(sidebarDividerHovered ? 0.32 : 0.14))
                    .frame(width: sidebarDividerHovered ? 2 : 1)
            }
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { hovered in
                        sidebarDividerHovered = hovered
                        (hovered ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { value in
                                if sidebarDragStartWidth == nil {
                                    sidebarDragStartWidth = sidebarWidth
                                }
                                let start = sidebarDragStartWidth ?? sidebarWidth
                                sidebarWidth = min(360, max(200, start + value.translation.width))
                            }
                            .onEnded { _ in
                                sidebarDragStartWidth = nil
                            }
                    )
            }
            .zIndex(2)
            .animation(.easeOut(duration: 0.12), value: sidebarDividerHovered)
            .accessibilityLabel("调整侧栏宽度")
    }

    private var sidebarToggleButton: some View {
        Button {
            sidebarVisible.toggle()
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(.primary.opacity(0.10), lineWidth: 0.6)
                        .allowsHitTesting(false)
                }
        }
        .buttonStyle(.plain)
        .help(sidebarVisible ? "隐藏侧栏" : "显示侧栏")
    }

    private func sidebarLabel(_ item: LauncherDestination) -> some View {
        Button {
            destination = item
        } label: {
            Label {
                Text(item.title)
            } icon: {
                Image(systemName: item.icon)
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(sidebarForeground(for: item, inactive: .secondary))
            }
            .foregroundStyle(sidebarForeground(for: item, inactive: .primary))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(destination == item
                          ? LauncherTheme.sidebarSelectionFill(for: store.settings.accentTint,
                                                               colorScheme: colorScheme,
                                                               isActive: appearsActive)
                          : .clear)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(destination == item ? .isSelected : [])
        .contentShape(Rectangle())
        .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func sidebarForeground(for item: LauncherDestination, inactive: Color) -> Color {
        guard destination == item else { return inactive }
        // Native Sidebar selection becomes accent-filled while the window is
        // active. Use the accent's readable foreground in that state; when
        // inactive, the icon returns to the accent color on the muted row.
        return appearsActive ? store.settings.accentTint.primaryForeground : store.settings.accentTint.color
    }

    private var home: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 20) {
                productHeader
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 18) {
                        launchPanel
                        runtimePanel(fixedWidth: true)
                    }
                    VStack(alignment: .leading, spacing: 18) {
                        launchPanel
                        runtimePanel(fixedWidth: false)
                    }
                }
                newsPanel
            }
            .padding(24)
            .frame(maxWidth: 980, alignment: .topLeading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(LauncherTheme.pageFill(for: colorScheme))
    }

    private var productHeader: some View {
        HStack(spacing: 16) {
            Image(nsImage: bundledLauncherIcon)
                .resizable()
                .scaledToFill()
                .scaleEffect(1.06)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("XIVCN Mac Launcher").font(.system(size: 27, weight: .semibold))
                    Text("v\(launcherVersion)")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.tertiary)
                }
                Text("最终幻想 XIV 国服").font(.title3).foregroundStyle(.secondary)
            }
            Spacer()
            if app.isManagedGameDownloadActive || app.managedGameDownloadCompletionMessage != nil {
                ManagedGameDownloadView(app: app)
                    .frame(maxWidth: 360)
            }
        }
    }

    private var launchPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("国服登录", systemImage: "person.badge.key").font(.headline)
                Spacer()
                loginMethodSelector
                .disabled(app.isBusy || app.isGameRunning || app.isRefreshingAreas)
            }

            accountSummary

            if loginMethod == .quickLogin {
                Picker("快速续登账号", selection: quickAccountBinding) {
                    ForEach(savedQuickAccounts) { saved in
                        Text(saved.account).tag(saved.account)
                    }
                }
                .disabled(app.isBusy || app.isGameRunning || app.isRefreshingAreas)
            } else if loginMethod != .qrCode {
                TextField("国服账号", text: $account)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedLoginField, equals: .account)
                    .overlay(loginFieldBorder(.account))
                    .disabled(app.isBusy || app.isGameRunning)
                    .onSubmit { submitLogin() }
                    .onChange(of: account) { _, value in
                        if loginInputIssue?.applies(to: .account) == true {
                            loginInputIssue = nil
                        }
                    }
                if let issue = loginInputIssue, issue.focusedField == .account {
                    loginValidationLabel(issue.message)
                }
            }
            if loginMethod == .password || loginMethod == .weGame {
                ZStack(alignment: .trailing) {
                    Group {
                        if passwordVisible {
                            TextField(loginMethod == .weGame ? "WeGame Token" : "密码", text: $password)
                        } else {
                            SecureField(loginMethod == .weGame ? "WeGame Token" : "密码", text: $password)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedLoginField, equals: .password)
                    .overlay(loginFieldBorder(.password))
                    .disabled(app.isBusy || app.isGameRunning)
                    .onSubmit { submitLogin() }
                    .onChange(of: password) { _, _ in
                        if loginInputIssue?.applies(to: .password) == true {
                            loginInputIssue = nil
                        }
                    }
                    Button {
                        passwordVisible.toggle()
                    } label: {
                        Image(systemName: passwordVisible ? "eye.slash" : "eye")
                            .frame(width: 28, height: 24)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(passwordVisible ? "隐藏密码" : "显示密码")
                    .disabled(app.isBusy || app.isGameRunning)
                }
                if let issue = loginInputIssue, issue.focusedField == .password {
                    loginValidationLabel(issue.message)
                }
                if loginMethod == .weGame {
                    Button {
                        app.importWeGameCredentials()
                    } label: {
                        Label("导入登录信息", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderless)
                    .tint(store.settings.accentTint.color)
                    .disabled(app.isBusy || app.isGameRunning)
                }
            }

            if loginMethod == .slide, let code = app.loginVerificationCode {
                VStack(alignment: .leading, spacing: 5) {
                    Label("叨鱼 App 确认请求", systemImage: "iphone.and.arrow.forward")
                        .font(.caption.weight(.semibold))
                    Text(code)
                        .font(.system(.title3, design: .monospaced).weight(.semibold))
                        .textSelection(.enabled)
                    Text("请在叨鱼 App 中核对该请求编号并确认登录，无需在启动器中输入验证码。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(10)
                .launcherInsetSurface()
            }

            Picker("大区", selection: areaSelection) {
                if app.availableAreas.isEmpty {
                    Text("正在获取国服大区…").tag("")
                } else {
                    ForEach(app.availableAreas) { area in
                        Text(area.status == 1 ? area.name : "\(area.name)（维护）").tag(area.id)
                    }
                }
            }
            .disabled(app.isBusy || app.isGameRunning || app.isRefreshingAreas || app.availableAreas.isEmpty)

            if app.areaStatusText.contains("失败") {
                Label(app.areaStatusText, systemImage: "wifi.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if shouldShowQRCode {
                Group {
                    if let data = app.qrCodeData, let image = NSImage(data: data) {
                        Image(nsImage: image).resizable().interpolation(.none).scaledToFit()
                    } else if app.isLoginInProgress {
                        VStack(spacing: 8) {
                            ProgressView()
                            Text("正在获取国服登录二维码…")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "qrcode")
                                .resizable().scaledToFit().padding(30).foregroundStyle(.tertiary)
                            Text("切换扫码登录后自动获取")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: 142, height: 142)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("国服登录二维码")
                Button {
                    app.refreshQRCode()
                } label: {
                    Label("刷新二维码", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .tint(store.settings.accentTint.color)
                .disabled(app.isGameRunning || app.isRefreshingAreas)
            }

            Toggle("保存 30 天快速续登凭据", isOn: quickLoginPersistenceBinding)
                .disabled(app.isBusy || app.isGameRunning || app.isRefreshingAreas)
                .toggleStyle(AccentCheckboxToggleStyle(tint: store.settings.accentTint))

            Divider()
            HStack(spacing: 8) {
                Menu {
                    ForEach(GameOwnership.allCases) { ownership in
                        Button { app.selectGameInstall(ownership) } label: {
                            Label(ownership.title,
                                  systemImage: store.settings.gameOwnership == ownership ? "checkmark" : ownership.icon)
                        }
                    }
                } label: {
                    Label(store.settings.gameOwnership.title, systemImage: store.settings.gameOwnership.icon)
                }
                .menuStyle(.borderlessButton)
                .disabled(app.isBusy || app.isGameRunning)
                Spacer()
                if store.settings.gameOwnership == .external {
                    Button { app.chooseExistingGame() } label: {
                        Label(store.settings.externalGamePath.isEmpty ? "选择目录" : "更换目录",
                              systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.borderless)
                    .help("选择外部 FFXIV 国服目录")
                    .tint(store.settings.accentTint.color)
                    .disabled(app.isBusy || app.isGameRunning)
                }
            }
            .font(.caption).foregroundStyle(.secondary)

            if managedGameMissing {
                Text("（未检测到游戏，点击“开始游戏”后将自动检查并下载）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button { submitLogin() } label: {
                    if app.isLoginInProgress && loginMethod != .qrCode {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text("登录中…")
                        }
                    } else {
                        Label(loginMethod == .qrCode
                                  ? (app.authState.isAuthenticated ? "重新扫码登录" : "刷新二维码")
                                  : "登录",
                              systemImage: loginMethod == .qrCode ? "qrcode" : "person.badge.key")
                    }
                }
                .modifier(PrimaryGlassButton(tint: store.settings.accentTint))
                .keyboardShortcut(.return, modifiers: [])
                .disabled(app.isBusy || app.isGameRunning || app.isRefreshingAreas)
                .tint(store.settings.accentTint.color)

                if app.isLoginInProgress {
                    Button { app.cancelLogin() } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless).help("取消登录")
                        .tint(store.settings.accentTint.color)
                }
                Spacer()
                Button { app.launchGame() } label: {
                    Label(app.isGameRunning ? "游戏运行中" : "开始游戏", systemImage: "play.fill")
                }
                .modifier(PrimaryGlassButton(tint: store.settings.accentTint))
                .tint(store.settings.accentTint.color)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(app.isBusy || app.isGameRunning || app.isRefreshingAreas ||
                          !app.authState.isAuthenticated)
            }

            Label(launchUpdateHint, systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !app.loginMethodStatus.isEmpty && app.loginMethodStatus != app.statusText {
                Text(app.loginMethodStatus)
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .launcherGlassPanel()
    }

    private var loginMethodSelector: some View {
        HStack(spacing: 2) {
            ForEach(visibleLoginMethods) { method in
                Button {
                    loginMethodBinding.wrappedValue = method
                } label: {
                    Text(method.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(loginMethod == method
                                         ? store.settings.accentTint.primaryForeground
                                         : .primary)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(loginMethod == method
                                      ? store.settings.accentTint.color.opacity(0.88)
                                      : .clear)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(loginMethod == method ? .isSelected : [])
                .accessibilityLabel(method.title)
            }
        }
        .padding(3)
        .frame(width: 300)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.78))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.primary.opacity(0.12), lineWidth: 0.6)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var accountSummary: some View {
        if let activeAccount = app.authState.authenticatedAccount {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Label("国服账号", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Text(authenticationBadgeText).font(.caption).foregroundStyle(.green)
                }
                HStack(spacing: 18) {
                    LabeledContent("账号", value: activeAccount)
                    LabeledContent("大区", value: selectedAreaName)
                }
                .font(.caption)
                Button(role: .destructive) { app.logout() } label: {
                    Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .disabled(app.isBusy || app.isGameRunning)
                .help("退出当前国服会话；保留已保存的快速续登凭据")
            }
            .padding(10)
            .launcherInsetSurface()
        } else if case .restoring(let account) = app.authState {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在验证已保存的国服账号 \(account)…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            Label("尚未登录国服账号", systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func runtimePanel(fixedWidth: Bool) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Label("当前状态", systemImage: "waveform.path.ecg").font(.headline)
            HStack(alignment: .top, spacing: 9) {
                if app.isBusy { ProgressView().controlSize(.small) }
                else { Image(systemName: "info.circle.fill").foregroundStyle(.secondary) }
                Text(app.statusText).font(.callout).lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if app.showsLaunchDetectionCancel {
                    Button { app.dismissLaunchDetectionFailure() } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("关闭启动检测")
                }
            }
            Divider()
            capability("游戏本体", detail: gameStatusDetail,
                       ready: app.isGameRunning || gameReady, icon: "gamecontroller")
            capability("国服大区", detail: selectedAreaName,
                       ready: selectedAreaReady, icon: "network")
            let selectedDalamudRoot = store.paths.dalamudRoot(for: store.settings.dalamudVariant)
            let selectedDalamudVersion = CNDalamudUpdater.activeVersion(in: selectedDalamudRoot)
            let selectedDalamudHealthy = store.settings.dalamudVariant != .disabled &&
                CNDalamudUpdater.activeInstallationIsReady(in: selectedDalamudRoot) &&
                CNWindowsRuntimeInstaller.installedVersion(paths: store.paths,
                                                           variant: store.settings.dalamudVariant) != nil
            capability("Dalamud",
                       detail: store.settings.dalamudVariant == .disabled
                           ? "未启用" : selectedDalamudVersion.map {
                               "\(store.settings.dalamudVariant.title) · \($0) · " +
                                   (selectedDalamudHealthy ? "正常" : "需要修复")
                           } ?? "\(store.settings.dalamudVariant.title) · 未安装",
                       ready: selectedDalamudHealthy,
                       optional: store.settings.dalamudVariant == .disabled,
                       icon: "puzzlepiece.extension")
            capability("Wine", detail: BundledRuntime.wineVersion,
                       ready: true, icon: "shippingbox")
            capability("DXMT", detail: BundledRuntime.dxmtVersion,
                       ready: true, icon: "cpu")
            capability("MSync",
                       detail: store.settings.msyncEnabled ? "已启用" : "已关闭",
                       ready: store.settings.msyncEnabled, optional: true,
                       icon: "arrow.triangle.2.circlepath")
            capability("Retina",
                       detail: store.settings.retinaEnabled ? "已启用" : "未启用",
                       ready: store.settings.retinaEnabled, optional: true, icon: "display")
            capability("MetalFX",
                       detail: store.settings.superResolutionEnabled
                           ? (store.settings.xomMetalFxModeEnabled ? "XOM 模式" : "默认")
                           : "未启用",
                       ready: store.settings.superResolutionEnabled, optional: true,
                       icon: "sparkles.rectangle.stack")
            capability("Metal HUD", detail: store.settings.metalHUDEnabled ? "已启用" : "未启用",
                       ready: store.settings.metalHUDEnabled, optional: true,
                       icon: "gauge.with.dots.needle.67percent")
        }
        .padding(18)
        .frame(width: fixedWidth ? 300 : nil, alignment: .leading)
        .frame(maxWidth: fixedWidth ? nil : .infinity, alignment: .leading)
        .launcherGlassPanel()
    }

    private var newsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("国服资讯", systemImage: "newspaper").font(.headline)
                Spacer()
                Button { app.refreshNews() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("刷新国服资讯")
                .disabled(app.isGameRunning || app.newsState == .loading)
            }
            switch app.newsState {
            case .idle, .loading:
                HStack { ProgressView().controlSize(.small); Text("正在读取国服官方资讯…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, minHeight: 80)
            case .failed(let message):
                ContentUnavailableView {
                    Label("资讯暂时不可用", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("重试") { app.refreshNews() }
                        .tint(store.settings.accentTint.color)
                        .disabled(app.isGameRunning)
                }
                .frame(minHeight: 120)
            case .loaded:
                if app.newsItems.isEmpty {
                    ContentUnavailableView("暂无资讯", systemImage: "newspaper")
                        .frame(minHeight: 110)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(app.newsItems.prefix(6)) { item in
                            Button { app.openNews(item) } label: {
                                HStack(spacing: 11) {
                                    AsyncImage(url: item.imageURL) { phase in
                                        if let image = phase.image {
                                            image.resizable().scaledToFill()
                                        } else {
                                            Image(systemName: "newspaper.fill")
                                                .resizable().scaledToFit().padding(18).foregroundStyle(.tertiary)
                                        }
                                    }
                                    .frame(width: 96, height: 62).clipped()
                                    .transaction { transaction in
                                        transaction.animation = nil
                                    }
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(item.title).font(.callout.weight(.medium)).lineLimit(2)
                                        if let date = item.publishedAt {
                                            Text(date, format: .dateTime.year().month().day())
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(8)
                            .launcherFloatingInsetSurface()
                        }
                    }
                }
            }
        }
    }

    private func capability(_ title: String, detail: String?, ready: Bool,
                            optional: Bool = false, icon: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let detail, !detail.isEmpty {
                    Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: ready ? "checkmark.circle.fill" : (optional ? "circle" : "exclamationmark.circle"))
                .foregroundStyle(ready ? Color.green : (optional ? Color.secondary : Color.orange))
        }
        .font(.callout)
    }

    private var gameReady: Bool {
        if case .ready = app.gameState { return true }
        return false
    }

    private var managedGameMissing: Bool {
        guard store.settings.gameOwnership == .managed else { return false }
        if case .ready = app.gameState { return false }
        return true
    }

    private var gameStateText: String {
        switch app.gameState {
        case .missing:
            if store.settings.gameOwnership == .managed { return "启动器管理 · 尚未下载游戏" }
            if store.settings.gamePath.isEmpty { return "外部游戏 · 尚未选择目录" }
            return "外部游戏 · 未找到游戏"
        case .incomplete(let reason): return "\(store.settings.gameOwnership.title) · 游戏不完整：\(reason)"
        case .ready(let version): return "\(store.settings.gameOwnership.title) · 国服游戏 \(version)"
        }
    }

    private var gameStatusDetail: String {
        if app.isGameRunning { return "\(store.settings.gameOwnership.title) · 运行中" }
        return "\(store.settings.gameOwnership.title) · \(selectedGameSummary)"
    }

    private var selectedAreaReady: Bool {
        guard !store.settings.cnAreaID.isEmpty, !store.settings.cnLobbyHost.isEmpty else { return false }
        return app.availableAreas.first(where: { $0.id == store.settings.cnAreaID })?.status == 1 ||
            app.availableAreas.isEmpty
    }

    private var launchUpdateHint: String {
        switch store.settings.dalamudVariant {
        case .china:
            return "启动时检查游戏及所选的Dalamud国服版本；版本过旧会先更新再启动"
        case .soil:
            return "启动时检查游戏及所选的Dalamud Soil版本；版本过旧会先更新再启动"
        case .disabled: return "启动时检查游戏版本；版本过旧会先更新再启动"
        }
    }

    private var selectedGameSummary: String {
        switch app.gameState {
        case .missing:
            return store.settings.gameOwnership == .managed ? "尚未下载" : "尚未检测到完整客户端"
        case .incomplete(let reason): return "不完整：\(reason)"
        case .ready(let version): return "当前版本：\(version)"
        }
    }

    private var gameStateIcon: String {
        gameReady ? "checkmark.circle.fill" : "exclamationmark.triangle"
    }

    private var areaSelection: Binding<String> {
        Binding(get: { store.settings.cnAreaID }, set: { id in
            if let area = app.availableAreas.first(where: { $0.id == id && $0.status == 1 }) {
                app.selectArea(area)
            }
        })
    }

    private var loginMethod: CNLoginMethod { store.settings.selectedLoginMethod }

    private var shouldShowQRCode: Bool {
        loginMethod == .qrCode &&
        (!app.authState.isAuthenticated || app.isLoginInProgress || app.qrCodeData != nil)
    }

    private var loginMethodBinding: Binding<CNLoginMethod> {
        Binding(get: { store.settings.selectedLoginMethod }, set: { method in
            loginInputIssue = nil
            focusedLoginField = nil
            passwordVisible = false
            app.loginMethodChanged(method)
        })
    }

    private func submitLogin() {
        let selectedAccount = loginMethod == .quickLogin
            ? quickAccountBinding.wrappedValue
            : account
        if let issue = CNLoginInputValidator.issue(method: loginMethod,
                                                   account: selectedAccount,
                                                   password: password) {
            loginInputIssue = issue
            focusedLoginField = issue.focusedField
            app.login(method: loginMethod, account: selectedAccount, password: password)
            return
        }
        loginInputIssue = nil
        focusedLoginField = nil
        if loginMethod == .qrCode {
            app.beginQRCodeLogin()
        } else {
            app.login(method: loginMethod, account: selectedAccount, password: password)
        }
    }

    private func loginFieldBorder(_ field: CNLoginInputField) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(loginInputIssue?.applies(to: field) == true ? Color.red : Color.clear,
                    lineWidth: 1)
            .allowsHitTesting(false)
    }

    private func loginValidationLabel(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.red)
    }

    private var visibleLoginMethods: [CNLoginMethod] {
        CNLoginMethod.userVisibleCases(hasSavedQuickLogin: !savedQuickAccounts.isEmpty)
    }

    private var savedQuickAccounts: [CNSavedAccount] {
        store.savedAccounts.filter(\.hasQuickLogin)
    }

    private var quickAccountBinding: Binding<String> {
        Binding(get: {
            if savedQuickAccounts.contains(where: { $0.account == selectedQuickAccount }) {
                return selectedQuickAccount
            }
            return savedQuickAccounts.first?.account ?? ""
        }, set: { value in
            selectedQuickAccount = value
            account = value
            password = ""
        })
    }

    private var authenticationBadgeText: String {
        if case .switching = app.authState { return "已登录 · 正在切换" }
        return "已登录"
    }

    private var quickLoginPersistenceBinding: Binding<Bool> {
        Binding(get: { store.settings.quickLoginEnabled }, set: { app.setQuickLoginPersistence($0) })
    }

    private var selectedAreaName: String {
        if let area = app.availableAreas.first(where: { $0.id == store.settings.cnAreaID }) {
            return area.status == 1 ? area.name : "\(area.name)（维护）"
        }
        return store.settings.cnAreaID.isEmpty ? "未选择" : store.settings.cnAreaID
    }

    private var launcherVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
    }
}

enum FirstLaunchSetupPage: Int, CaseIterable, Identifiable {
    case welcome, gameSource, dalamud, optionalFeatures, appearance, review

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .welcome: return "欢迎"
        case .gameSource: return "游戏来源"
        case .dalamud: return "Dalamud"
        case .optionalFeatures: return "可选功能"
        case .appearance: return "外观"
        case .review: return "确认设置"
        }
    }
    var icon: String {
        switch self {
        case .welcome: return "sparkles"
        case .gameSource: return "gamecontroller"
        case .dalamud: return "puzzlepiece.extension"
        case .optionalFeatures: return "switch.2"
        case .appearance: return "paintpalette"
        case .review: return "checklist"
        }
    }
}

struct FirstLaunchSetupView: View {
    @ObservedObject var app: AppDelegate
    @ObservedObject var store: SettingsStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var page: FirstLaunchSetupPage = .welcome

    init(app: AppDelegate, store: SettingsStore) {
        self.app = app
        self.store = store
        let saved = min(max(store.settings.firstLaunchStep, 0), FirstLaunchSetupPage.allCases.count - 1)
        _page = State(initialValue: FirstLaunchSetupPage(rawValue: saved) ?? .welcome)
    }

    var body: some View {
        ZStack {
            // The native sidebar material samples whatever is behind the app
            // window. A setup assistant must have a stable page background,
            // especially while an NSOpenPanel is presented over it.
            LauncherTheme.pageFill(for: colorScheme)
                .ignoresSafeArea()

            VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: page.icon)
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(store.settings.accentTint.color)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(page.title).font(.title2.weight(.semibold))
                    Text("首次启动设置 · \(page.rawValue + 1) / \(FirstLaunchSetupPage.allCases.count)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(24)

            AccentProgressBar(value: Double(page.rawValue + 1),
                              total: Double(FirstLaunchSetupPage.allCases.count),
                              tint: store.settings.accentTint)
                .padding(.horizontal, 24)

            Divider().padding(.top, 16)

            ScrollView(.vertical) {
                pageContent
                    .padding(26)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.automatic)

            Divider()
            HStack {
                Button("稍后设置") { app.cancelFirstLaunchSetup() }
                    .tint(store.settings.accentTint.color)
                    .disabled(app.isFirstLaunchDalamudPreparing)
                Spacer()
                if page != .welcome {
                    Button { move(-1) } label: { Label("上一步", systemImage: "chevron.left") }
                        .tint(store.settings.accentTint.color)
                        .disabled(app.isFirstLaunchDalamudPreparing)
                }
                Button {
                    if page == .review {
                        app.completeFirstLaunchSetup()
                    } else if page == .dalamud {
                        app.startFirstLaunchDalamudPreparation { success in
                            if success { move(1) }
                        }
                    } else {
                        move(1)
                    }
                } label: {
                    Label(page == .review ? "完成" : "下一步",
                          systemImage: page == .review ? "checkmark" : "chevron.right")
                }
                .modifier(PrimaryGlassButton(tint: store.settings.accentTint))
                .tint(store.settings.accentTint.color)
                .disabled(app.isFirstLaunchDalamudPreparing || (page == .dalamud && app.isBusy))
            }
                .padding(20)
            }
            .frame(maxWidth: 680, maxHeight: 580)
            .launcherGlassPanel(radius: 18)
            .padding(24)
        }
        .launcherTheme(store.settings.accentTint)
        .preferredColorScheme(app.resolvedColorScheme)
        .onChange(of: page) { _, value in
            store.settings.firstLaunchStep = value.rawValue
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .welcome:
            VStack(alignment: .leading, spacing: 16) {
                Text("XIVCN Mac Launcher").font(.system(size: 30, weight: .semibold))
                Text("设置国服游戏来源、Dalamud 流程、图形功能和外观。之后仍可在设置中修改。")
                    .foregroundStyle(.secondary)
                Label("Apple Silicon · DXMT-only · Metal", systemImage: "cpu")
                Label("所有开关都连接到实际启动环境或配置", systemImage: "checkmark.seal")
            }
        case .gameSource:
            VStack(alignment: .leading, spacing: 16) {
                Picker("游戏来源", selection: gameOwnershipBinding) {
                    ForEach(GameOwnership.allCases) { ownership in
                        Label(ownership.title, systemImage: ownership.icon).tag(ownership)
                    }
                }
                .pickerStyle(.segmented)
                Text(store.settings.gameOwnership == .managed
                     ? "游戏将安装在启动器管理目录。完整卸载会删除这个版本。"
                     : "使用您已下载的外部游戏文件，卸载启动器时不会连带删除。")
                    .font(.callout).foregroundStyle(.secondary)
                LabeledContent("当前目录", value: store.settings.gamePath.isEmpty ? "尚未设置" : store.settings.gamePath)
                LabeledContent("检测结果", value: gameStateDescription)
                if store.settings.gameOwnership == .external {
                    Button { app.chooseExistingGame(requireValid: true) } label: {
                        Label("选择并验证已有游戏", systemImage: "folder.badge.checkmark")
                    }
                    .disabled(app.isBusy || app.isGameRunning)
                    .tint(store.settings.accentTint.color)
                } else {
                    Text("首次启动游戏若本体不存在，会提供本体下载/安装流程。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        case .dalamud:
            VStack(alignment: .leading, spacing: 16) {
                Picker("启动时使用", selection: $store.settings.dalamudVariant) {
                    ForEach(DalamudVariant.allCases) { variant in
                        Text(variant.title).tag(variant)
                    }
                }
                .pickerStyle(.radioGroup)
                .disabled(app.isFirstLaunchDalamudPreparing || app.isBusy)
                Text(store.settings.dalamudVariant.description)
                    .font(.callout).foregroundStyle(.secondary)
                if app.isFirstLaunchDalamudPreparing {
                    FirstLaunchDalamudProgressView(app: app)
                } else if let error = app.firstLaunchDalamudError {
                    Text(error)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        case .optionalFeatures:
            VStack(alignment: .leading, spacing: 15) {
                Toggle("Retina 高清分辨率模式", isOn: retinaBinding)
                Toggle("MSync", isOn: $store.settings.msyncEnabled)
                Toggle("MetalFX 超分辨率", isOn: $store.settings.superResolutionEnabled)
                if store.settings.superResolutionEnabled {
                    Picker("MetalFX 模式", selection: $store.settings.xomMetalFxModeEnabled) {
                        Text("默认").tag(false)
                        Text("XOM 模式").tag(true)
                    }
                    .pickerStyle(.segmented)
                    Text(store.settings.xomMetalFxModeEnabled
                         ? "游戏会以2倍分辨率模运行，可理解为拍照模式"
                         : "游戏会以正常分辨率生效动态DLSS功能")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .appearance:
            VStack(alignment: .leading, spacing: 18) {
                Picker("外观", selection: $store.settings.appearance) {
                    appearanceChoice(.auto, "跟随系统")
                    appearanceChoice(.light, "浅色")
                    appearanceChoice(.dark, "深色")
                }
                .pickerStyle(.segmented)
                Text("强调色").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 105))], spacing: 10) {
                    ForEach(AccentTint.allCases) { tint in
                        Button {
                            store.settings.accentTint = tint
                        } label: {
                            HStack(spacing: 8) {
                                Circle().fill(tint.color).frame(width: 14, height: 14)
                                Text(tint.title)
                                Spacer(minLength: 0)
                                if store.settings.accentTint == tint {
                                    Image(systemName: "checkmark").font(.caption.weight(.bold))
                                }
                            }
                            .padding(.horizontal, 10).frame(height: 34)
                        }
                        .buttonStyle(.bordered)
                        .tint(store.settings.accentTint == tint ? tint.color : nil)
                    }
                }
                Text("强调色会统一应用到按钮、选择、进度、图标与交互高亮。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .review:
            VStack(alignment: .leading, spacing: 13) {
                reviewRow("游戏来源", store.settings.gameOwnership.title, "gamecontroller")
                reviewRow("游戏状态", gameStateDescription, "internaldrive")
                reviewRow("Dalamud", store.settings.dalamudVariant.title, "puzzlepiece.extension")
                reviewRow("Retina", store.settings.retinaEnabled ? "启用" : "禁用", "display.2")
                reviewRow("MSync", store.settings.msyncEnabled ? "启用" : "禁用", "arrow.triangle.branch")
                reviewRow("MetalFX", store.settings.superResolutionEnabled
                          ? (store.settings.xomMetalFxModeEnabled ? "XOM 模式" : "默认")
                          : "禁用", "sparkles")
                reviewRow("外观", appearanceTitle, "circle.lefthalf.filled")
                reviewRow("强调色", store.settings.accentTint.title, "paintpalette")
            }
        }
    }

    private var gameOwnershipBinding: Binding<GameOwnership> {
        Binding(get: { store.settings.gameOwnership }, set: { app.selectGameInstall($0) })
    }

    private var retinaBinding: Binding<Bool> {
        Binding(get: { store.settings.retinaEnabled }, set: { store.settings.macOSScalingEnabled = !$0 })
    }

    private var gameStateDescription: String {
        switch app.gameState {
        case .missing: return store.settings.gameOwnership == .managed ? "尚未下载" : "尚未选择或未找到"
        case .incomplete(let reason): return "不完整：\(reason)"
        case .ready(let version): return "可用 · \(version)"
        }
    }

    private var appearanceTitle: String {
        switch store.settings.appearance {
        case .auto: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    private func move(_ offset: Int) {
        let value = min(max(page.rawValue + offset, 0), FirstLaunchSetupPage.allCases.count - 1)
        if let next = FirstLaunchSetupPage(rawValue: value) { page = next }
    }

    private func reviewRow(_ title: String, _ value: String, _ icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 22)
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(10)
        .launcherInsetSurface()
    }

    @ViewBuilder
    private func appearanceChoice(_ mode: AppearanceMode, _ title: String) -> some View {
        HStack(spacing: 6) {
            switch mode {
            case .auto:
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(colors: [.white, .gray, .black], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 16, height: 16)
            case .light:
                Circle().fill(.white).overlay(Circle().stroke(.gray, lineWidth: 0.5)).frame(width: 16, height: 16)
            case .dark:
                Circle().fill(.black).overlay(Circle().stroke(.gray, lineWidth: 0.5)).frame(width: 16, height: 16)
            }
            Text(title)
        }
        .tag(mode)
    }
}

struct GameNotFoundView: View {
    @ObservedObject var app: AppDelegate

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.title2.weight(.semibold))
            Text(detail).foregroundStyle(.secondary)
            Spacer()
            HStack {
                Button { app.showsGameNotFound = false } label: { Text("返回") }
                    .tint(app.store.settings.accentTint.color)
                Spacer()
                if app.store.settings.gameOwnership == .managed {
                    Button { app.downloadManagedGame() } label: {
                        Label("下载游戏", systemImage: "arrow.down.circle")
                    }
                    .modifier(PrimaryGlassButton(tint: app.store.settings.accentTint))
                    .tint(app.store.settings.accentTint.color)
                } else {
                    Button { app.chooseExistingGame(requireValid: true) } label: {
                        Label("重新选择游戏目录", systemImage: "folder")
                    }
                    .tint(app.store.settings.accentTint.color)
                    Button {
                        app.selectGameInstall(.managed)
                        app.showsGameNotFound = false
                    } label: {
                        Label("使用启动器管理的游戏", systemImage: "internaldrive")
                    }
                    .modifier(PrimaryGlassButton(tint: app.store.settings.accentTint))
                        .tint(app.store.settings.accentTint.color)
                }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .launcherDialogSurface()
        .launcherTheme(app.store.settings.accentTint)
    }

    private var title: String {
        app.store.settings.gameOwnership == .managed
            ? "没有检测到 FFXIV 游戏本体"
            : "没有找到你设置的游戏本体"
    }

    private var detail: String {
        if case .incomplete(let reason) = app.gameState {
            return "当前目录不完整：\(reason)。"
        }
        return app.store.settings.gameOwnership == .managed
            ? "启动器管理目录中尚无可用客户端。可以立即下载并安装国服游戏。"
            : "原先记录的外部游戏目录不可用。请重新选择有效目录，或切换到启动器管理版本。"
    }
}

private struct ManagedGameDownloadView: View {
    @ObservedObject var app: AppDelegate

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                Text(title).font(.callout.weight(.medium)).lineLimit(1)
                Spacer(minLength: 4)
                if app.isManagedGameDownloadRunning { ProgressView().controlSize(.small) }
            }
            if let completion = app.managedGameDownloadCompletionMessage {
                Text(completion).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                HStack {
                    Spacer()
                    Button("完成") { app.dismissManagedGameDownloadCompletion() }
                        .tint(app.store.settings.accentTint.color)
                }
            } else if let error = app.managedGameDownloadError {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                HStack(spacing: 10) {
                    Button { app.retryManagedGameDownload() } label: {
                        Label("重试", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    Button { app.cancelManagedGameDownload() } label: {
                        Label("取消并清理", systemImage: "trash")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                }
            } else if app.isManagedGameDownloadPaused {
                Text("已暂停，已完成的文件会保留。")
                    .font(.caption).foregroundStyle(.secondary)
                downloadActions
            } else if let progress = app.managedGameDownloadProgress {
                Text(progress.currentFile.isEmpty ? progress.phase : "\(progress.phase) · \(progress.currentFile)")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                if progress.totalBytes > 0 {
                    AccentProgressBar(value: Double(progress.completedBytes),
                                      total: Double(progress.totalBytes),
                                      tint: app.store.settings.accentTint)
                    HStack(spacing: 5) {
                        Text(ByteCountFormatter.string(fromByteCount: progress.completedBytes, countStyle: .file))
                        Text("/")
                        Text(ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file))
                        Spacer(minLength: 4)
                        if progress.bytesPerSecond > 0 {
                            Text("\(ByteCountFormatter.string(fromByteCount: Int64(progress.bytesPerSecond), countStyle: .file))/s")
                            Text(eta(progress))
                        }
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                } else if progress.totalFiles > 0 {
                    AccentProgressBar(value: Double(progress.completedFiles),
                                      total: Double(progress.totalFiles),
                                      tint: app.store.settings.accentTint)
                } else {
                    ProgressView()
                }
                downloadActions
            } else {
                ProgressView()
                downloadActions
            }
        }
        .padding(10)
        .frame(minWidth: 250, alignment: .leading)
        .launcherInsetSurface()
    }

    private var title: String {
        if app.managedGameDownloadCompletionMessage != nil { return "国服游戏下载完成" }
        if app.managedGameDownloadError != nil { return "国服游戏下载失败" }
        if app.isManagedGameDownloadPaused { return "国服游戏下载已暂停" }
        return "下载国服游戏"
    }

    private var statusIcon: String {
        if app.managedGameDownloadCompletionMessage != nil { return "checkmark.circle.fill" }
        return app.managedGameDownloadError == nil ? "arrow.down.circle" : "exclamationmark.octagon.fill"
    }

    private var statusColor: Color {
        if app.managedGameDownloadCompletionMessage != nil { return .green }
        return app.managedGameDownloadError == nil ? app.store.settings.accentTint.color : .red
    }

    @ViewBuilder
    private var downloadActions: some View {
        HStack(spacing: 10) {
            if app.isManagedGameDownloadRunning {
                Button { app.pauseManagedGameDownload() } label: {
                    Label("暂停", systemImage: "pause.fill")
                }
                .buttonStyle(.borderless)
            } else if app.isManagedGameDownloadPaused {
                Button { app.resumeManagedGameDownload() } label: {
                    Label("继续", systemImage: "play.fill")
                }
                .buttonStyle(.borderless)
            }
            Button { app.cancelManagedGameDownload() } label: {
                Label("取消并清理", systemImage: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
        }
        .font(.caption)
    }

    private func eta(_ progress: CNDownloadProgress) -> String {
        let remaining = Double(max(0, progress.totalBytes - progress.completedBytes))
        guard progress.bytesPerSecond > 0 else { return "" }
        let seconds = Int(remaining / progress.bytesPerSecond)
        if seconds >= 3600 { return "约 \(seconds / 3600) 小时" }
        if seconds >= 60 { return "约 \(seconds / 60) 分" }
        return "约 \(seconds) 秒"
    }
}

struct FirstLaunchDalamudProgressView: View {
    @ObservedObject var app: AppDelegate

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在下载 \(app.store.settings.dalamudVariant.title)…")
                    .font(.callout.weight(.medium))
            }
            if let progress = app.updateProgress {
                Text(progress.currentFile.isEmpty ? progress.phase : "\(progress.phase)：\(progress.currentFile)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if progress.totalBytes > 0 {
                    AccentProgressBar(value: Double(progress.completedBytes),
                                      total: Double(progress.totalBytes),
                                      tint: app.store.settings.accentTint)
                    Text("\(ByteCountFormatter.string(fromByteCount: progress.completedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if progress.totalFiles > 0 {
                    AccentProgressBar(value: Double(progress.completedFiles),
                                      total: Double(progress.totalFiles),
                                      tint: app.store.settings.accentTint)
                }
            }
        }
        .padding(12)
        .launcherInsetSurface()
    }
}

struct UpdateProgressView: View {
    @ObservedObject var app: AppDelegate

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
                HStack {
                    Label(app.updateError == nil ? app.updateTitle : "\(app.updateTitle)失败",
                          systemImage: app.updateError != nil
                            ? "exclamationmark.octagon.fill"
                            : (app.updateCompletionMessage != nil
                               ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath"))
                        .font(.headline)
                    Spacer()
                    if app.isBusy { ProgressView().controlSize(.small) }
                }

                if let error = app.updateError {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                    Spacer()
                    HStack {
                        Button("返回登录界面") { app.returnToLogin() }
                            .tint(app.store.settings.accentTint.color)
                        Spacer()
                        Button { app.retryUpdate() } label: { Label("重试", systemImage: "arrow.clockwise") }
                            .modifier(PrimaryGlassButton(tint: app.store.settings.accentTint))
                            .tint(app.store.settings.accentTint.color)
                    }
                } else if let completion = app.updateCompletionMessage {
                    Text(completion).foregroundStyle(.primary)
                    Spacer()
                    HStack {
                        Spacer()
                        Button("完成") { app.confirmUpdateCompletion() }
                            .modifier(PrimaryGlassButton(tint: app.store.settings.accentTint))
                            .tint(app.store.settings.accentTint.color)
                    }
                } else if let progress = app.updateProgress {
                    Text(progress.currentFile.isEmpty ? progress.phase : "\(progress.phase) · \(progress.currentFile)")
                        .lineLimit(2).truncationMode(.middle)
                    if progress.totalBytes > 0 {
                        AccentProgressBar(value: Double(progress.completedBytes),
                                          total: Double(progress.totalBytes),
                                          tint: app.store.settings.accentTint)
                        HStack {
                            Text(ByteCountFormatter.string(fromByteCount: progress.completedBytes, countStyle: .file))
                            Text("/")
                            Text(ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file))
                            Spacer()
                            if progress.bytesPerSecond > 0 {
                                Text("\(ByteCountFormatter.string(fromByteCount: Int64(progress.bytesPerSecond), countStyle: .file))/s")
                                Text(eta(progress))
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    } else if progress.totalFiles > 0 {
                        AccentProgressBar(value: Double(progress.completedFiles),
                                          total: Double(progress.totalFiles),
                                          tint: app.store.settings.accentTint)
                    } else {
                        ProgressView()
                    }
                    Spacer()
                    HStack {
                        Text(fileCount(progress)).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("取消") { app.cancelUpdate() }.disabled(!app.isBusy)
                            .tint(app.store.settings.accentTint.color)
                    }
                } else {
                    ProgressView()
                    Text(app.updateStatusText).foregroundStyle(.secondary)
                    Spacer()
                    HStack {
                        Spacer()
                        Button("取消") { app.cancelUpdate() }
                            .disabled(!app.isBusy)
                            .tint(app.store.settings.accentTint.color)
                    }
                }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .launcherDialogSurface()
        .launcherTheme(app.store.settings.accentTint)
    }

    private func fileCount(_ progress: CNDownloadProgress) -> String {
        guard progress.totalFiles > 0 else { return "" }
        return "\(progress.completedFiles) / \(progress.totalFiles) 个文件"
    }

    private func eta(_ progress: CNDownloadProgress) -> String {
        let remaining = Double(max(0, progress.totalBytes - progress.completedBytes))
        guard progress.bytesPerSecond > 0 else { return "" }
        let seconds = Int(remaining / progress.bytesPerSecond)
        if seconds >= 3600 { return "剩余约 \(seconds / 3600) 小时 \((seconds % 3600) / 60) 分" }
        if seconds >= 60 { return "剩余约 \(seconds / 60) 分 \(seconds % 60) 秒" }
        return "剩余约 \(seconds) 秒"
    }
}

private struct RuntimeResetProgressView: View {
    @ObservedObject var app: AppDelegate
    let tint: AccentTint

    var body: some View {
        VStack(spacing: 16) {
            switch app.runtimeResetPhase ?? .running {
            case .running:
                ProgressView()
                    .controlSize(.large)
                    .tint(tint.color)
                Text("正在重置 Wine / DXMT 运行环境")
                    .font(.headline)
                Text("正在重建 Wine Prefix、部署内置 DXMT 并同步当前设置。完成前请勿退出启动器。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            case .succeeded(let message):
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.green)
                Text("运行环境重置完成")
                    .font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("完成") { app.dismissRuntimeResetWindow() }
                    .keyboardShortcut(.defaultAction)
                    .tint(tint.color)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.orange)
                Text("运行环境重置失败")
                    .font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("关闭") { app.dismissRuntimeResetWindow() }
                    .keyboardShortcut(.cancelAction)
                    .tint(tint.color)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

extension Notification.Name {
    static let openLauncherSettings = Notification.Name("FFXIVCN.OpenSettings")
    static let openLauncherHome = Notification.Name("FFXIVCN.OpenHome")
}

struct PrimaryGlassButton: ViewModifier {
    let tint: AccentTint

    func body(content: Content) -> some View {
        content
            .buttonStyle(AccentPrimaryButtonStyle(tint: tint))
    }
}

private struct AccentPrimaryButtonStyle: ButtonStyle {
    let tint: AccentTint
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let foreground = isEnabled ? tint.primaryForeground : Color.secondary
        let fill = isEnabled
            ? tint.color.opacity(configuration.isPressed ? 0.76 : 0.88)
            : Color(nsColor: .controlBackgroundColor).opacity(0.72)
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                fill,
                in: RoundedRectangle(cornerRadius: LauncherTheme.controlRadius,
                                     style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: LauncherTheme.controlRadius,
                                 style: .continuous)
                    .stroke(.white.opacity(isEnabled
                                           ? (colorScheme == .dark ? 0.20 : 0.28)
                                           : 0.08), lineWidth: 0.6)
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct AccentCheckboxToggleStyle: ToggleStyle {
    let tint: AccentTint
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(configuration.isOn ? tint.color : .secondary)
                configuration.label
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "已启用" : "未启用")
    }
}

struct SettingsView: View {
    @ObservedObject var app: AppDelegate
    @ObservedObject var store: SettingsStore
    @Environment(\.colorScheme) private var colorScheme
    let section: LauncherDestination
    @State private var confirmsManagedDelete = false
    @State private var confirmsCleanUninstall = false
    @State private var confirmsDCTravelEnable = false
    @State private var confirmsRuntimeReset = false
    @State private var accountPendingDeletion: String?
    @State private var dalamudPendingRemoval: DalamudVariant?
    @State private var localError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: section.icon)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(store.settings.accentTint.color)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.title).font(.title2.weight(.semibold))
                    Text(sectionSubtitle).font(.callout).foregroundStyle(.secondary)
                }
            }
            selectedForm
                .scrollContentBackground(.hidden)
                .scrollIndicators(.automatic)
        }
        .padding(28)
        .frame(maxWidth: 760, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(LauncherTheme.pageFill(for: colorScheme))
        .alert("删除启动器管理的游戏？", isPresented: $confirmsManagedDelete) {
            Button("取消", role: .cancel) {}
            Button("删除游戏", role: .destructive) {
                do { try app.removeManagedGame() } catch { localError = error.localizedDescription }
            }
        } message: {
            Text("只会删除明确记录为“启动器管理”的游戏目录；外部游戏永远不会被删除。")
        }
        .alert("重置 Wine / DXMT 运行环境？", isPresented: $confirmsRuntimeReset) {
            Button("取消", role: .cancel) {}
            Button("重置", role: .destructive) { app.resetRuntimeEnvironment() }
        } message: {
            Text("将重建 Wine Prefix、重新部署内置 DXMT，并同步当前 Wine 图形与键盘设置。游戏、登录信息、Dalamud 插件和启动器设置不会被删除。")
        }
        .alert("操作失败", isPresented: Binding(get: { localError != nil }, set: { if !$0 { localError = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(localError ?? "") }
        .alert("启用超域旅行服务？", isPresented: $confirmsDCTravelEnable) {
            Button("取消", role: .cancel) {}
            Button("仍要启用") { app.setDCTravelEnabled(true) }
        } message: {
            Text("此功能依赖国服游戏内插件与本地服务配合，当前可能存在兼容性问题或不稳定情况。仅在了解风险后启用；关闭时不需要确认。")
        }
        .confirmationDialog("移除所有 XIVCN Mac Launcher 数据？", isPresented: $confirmsCleanUninstall,
                            titleVisibility: .visible) {
            Button("移除所有数据并退出", role: .destructive) {
                do { try app.cleanUninstall() }
                catch { localError = error.localizedDescription }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将精确删除本项目的 Keychain Service、账号和 Token、设置、设备标识、缓存、日志、启动器管理的游戏，以及两套 Dalamud 及其相关数据。外部游戏绝不会删除。把 App 拖入废纸篓不会自动清理这些数据。")
        }
        .confirmationDialog("删除已保存账号？",
                            isPresented: Binding(get: { accountPendingDeletion != nil },
                                                 set: { if !$0 { accountPendingDeletion = nil } }),
                            titleVisibility: .visible) {
            Button("删除账号信息", role: .destructive) {
                if let accountPendingDeletion { app.deleteSavedAccount(accountPendingDeletion) }
                accountPendingDeletion = nil
            }
            Button("取消", role: .cancel) { accountPendingDeletion = nil }
        } message: {
            Text("将从系统钥匙串删除该账号的密码、快速续登凭据和保存会话，不影响其他账号。")
        }
        .confirmationDialog("清除 Dalamud？",
                            isPresented: Binding(get: { dalamudPendingRemoval != nil },
                                                 set: { if !$0 { dalamudPendingRemoval = nil } }),
                            titleVisibility: .visible) {
            Button(dalamudPendingRemoval.map { "清除 \($0.title)" } ?? "清除 Dalamud", role: .destructive) {
                if let variant = dalamudPendingRemoval {
                    do { try app.removeDalamud(variant) }
                    catch { localError = error.localizedDescription }
                }
                dalamudPendingRemoval = nil
            }
            Button("取消", role: .cancel) { dalamudPendingRemoval = nil }
        } message: {
            Text("将清除该 Dalamud 及其相关插件和数据。")
        }
        .onChange(of: confirmsManagedDelete) { _, isPresented in
            if !isPresented { app.restoreContentFocusAfterDialog() }
        }
        .onChange(of: confirmsCleanUninstall) { _, isPresented in
            if !isPresented { app.restoreContentFocusAfterDialog() }
        }
        .onChange(of: confirmsDCTravelEnable) { _, isPresented in
            if !isPresented { app.restoreContentFocusAfterDialog() }
        }
        .onChange(of: confirmsRuntimeReset) { _, isPresented in
            if !isPresented { app.restoreContentFocusAfterDialog() }
        }
        .onChange(of: accountPendingDeletion) { _, account in
            if account == nil { app.restoreContentFocusAfterDialog() }
        }
        .onChange(of: dalamudPendingRemoval) { _, variant in
            if variant == nil { app.restoreContentFocusAfterDialog() }
        }
    }

    @ViewBuilder
    private var selectedForm: some View {
        switch section {
        case .general: general
        case .account: account
        case .game: game
        case .graphics: graphics
        case .dalamud: dalamud
        case .advanced: advanced
        case .home: EmptyView()
        }
    }

    private var sectionSubtitle: String {
        switch section {
        case .general: return "外观、登录与启动行为"
        case .account: return "国服凭据与真实大区"
        case .game: return "安装类型、目录与完整性"
        case .graphics: return "Retina、Metal 与渲染比例"
        case .dalamud: return "国服核心、插件与超域旅行"
        case .advanced: return "Wine、键盘映射与文件"
        case .home: return ""
        }
    }

    private var general: some View {
        Form {
            Section("主题与外观") {
                HStack(spacing: 10) {
                    appearanceSwatch(store.settings.appearance)
                    Picker("外观", selection: $store.settings.appearance) {
                        appearanceChoice(.auto, title: "跟随系统")
                        appearanceChoice(.light, title: "浅色")
                        appearanceChoice(.dark, title: "深色")
                    }
                    .pickerStyle(.menu)
                }
                HStack(spacing: 10) {
                    Circle()
                        .fill(store.settings.accentTint.color)
                        .overlay(Circle().stroke(.primary.opacity(0.22), lineWidth: 0.5))
                        .frame(width: 13, height: 13)
                    Picker("强调色", selection: $store.settings.accentTint) {
                        ForEach(AccentTint.allCases) { tint in
                            HStack(spacing: 7) {
                                Circle().fill(tint.color).frame(width: 10, height: 10)
                                Text(tint.title)
                            }
                            .tag(tint)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            Section("登录与启动") {
                Toggle("自动使用已保存凭据登录", isOn: $store.settings.autoLogin)
                    .disabled(!store.savedAccounts.contains(where: \.hasQuickLogin))
                if !store.savedAccounts.contains(where: \.hasQuickLogin) {
                    Text("保存有效的 30 天快速续登凭据后才可启用。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("登录后自动启动游戏", isOn: $store.settings.autoLaunch)
                Toggle("游戏启动后自动关闭启动器", isOn: $store.settings.autoCloseLauncher)
                Toggle("不自动关闭时最小化启动器", isOn: $store.settings.minimizeAfterLaunch)
                    .disabled(store.settings.autoCloseLauncher)
                Button { app.runFirstLaunchSetup() } label: {
                    Label("重新运行首次启动设置", systemImage: "wand.and.stars")
                }
                .tint(store.settings.accentTint.color)
                .disabled(app.isBusy || app.isGameRunning)
            }
            .disabled(app.isBusy || app.isGameRunning)
        }.formStyle(.grouped)
    }

    private var account: some View {
        Form {
            Section("国服账号") {
                LabeledContent("当前账号", value: app.authState.authenticatedAccount ?? "未登录")
                Toggle("保存 30 天快速续登凭据", isOn: quickLoginPersistenceBinding)
                    .disabled(app.isBusy || app.isGameRunning)
                if app.authState.isAuthenticated {
                    Button(role: .destructive) { app.logout() } label: {
                        Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .disabled(app.isBusy || app.isGameRunning)
                }
                Button(role: .destructive) { app.clearLogin() } label: {
                    Label("清除当前账号凭据", systemImage: "key.slash")
                }
                .tint(.red)
                .disabled(store.settings.cnAccount.isEmpty || app.isBusy || app.isGameRunning)
            }
            Section("已保存账号") {
                if store.savedAccounts.isEmpty {
                    Text("没有已保存的账号信息。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.savedAccounts) { saved in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(saved.account).textSelection(.enabled)
                                Text(savedAccountDetail(saved))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if saved.account == app.authState.authenticatedAccount {
                                Text("当前").font(.caption).foregroundStyle(.secondary)
                            }
                            Button(role: .destructive) { accountPendingDeletion = saved.account } label: {
                                Image(systemName: "trash")
                            }
                            .help("删除 \(saved.account) 的保存信息")
                            .disabled(app.isBusy || app.isGameRunning)
                        }
                    }
                }
            }
            Section("国服大区") {
                Picker("大区", selection: areaBinding) {
                    ForEach(app.availableAreas) { area in
                        Text(area.status == 1 ? area.name : "\(area.name)（维护）").tag(area.id)
                    }
                }
                .disabled(app.isBusy || app.isGameRunning || app.isRefreshingAreas || app.availableAreas.isEmpty)
                Button { Task { await app.refreshAreas() } } label: {
                    Label("刷新大区列表", systemImage: "arrow.clockwise")
                }
                .tint(store.settings.accentTint.color)
                .disabled(app.isBusy || app.isGameRunning || app.isRefreshingAreas)
                Text(app.areaStatusText)
                    .font(.caption)
                    .foregroundStyle(app.areaStatusText.contains("失败") ? Color.red : Color.secondary)
            }
        }.formStyle(.grouped)
    }

    private var game: some View {
        Form {
            Section("游戏来源") {
                Picker("当前来源", selection: gameOwnershipBinding) {
                    ForEach(GameOwnership.allCases) { ownership in
                        Text(ownership.title).tag(ownership)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(app.isBusy || app.isGameRunning)
                LabeledContent("状态", value: gameStateDescription)
            }
            if store.settings.gameOwnership == .managed {
                Section("启动器管理") {
                    LabeledContent("安装目录", value: store.paths.managedGame.path)
                    Text("此目录由启动器负责下载、更新、修复与卸载。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("维护") {
                    HStack {
                        Button { app.downloadManagedGame() } label: {
                            Label(gameReady ? "重新验证并更新" : "下载游戏", systemImage: "arrow.down.circle")
                        }
                        Button { app.repairGameNow() } label: {
                            Label("完整性检查与修复", systemImage: "stethoscope")
                        }
                        .disabled(!gameReady)
                    }
                    .tint(store.settings.accentTint.color)
                    Button(role: .destructive) { confirmsManagedDelete = true } label: {
                        Label("删除启动器管理的游戏", systemImage: "trash")
                    }
                    .tint(.red)
                    .disabled((!gameReady && !app.isManagedGameDownloadActive) || app.isBusy || app.isGameRunning)
                }
                .disabled(app.isBusy || app.isGameRunning)
            } else {
                Section("外部游戏") {
                    HStack {
                        TextField("FFXIV 国服目录", text: externalGamePathBinding)
                            .disabled(app.isBusy || app.isGameRunning)
                        Button { app.chooseExistingGame() } label: { Image(systemName: "folder") }
                            .help("选择外部游戏目录")
                            .disabled(app.isBusy || app.isGameRunning)
                            .tint(store.settings.accentTint.color)
                    }
                    if !store.settings.externalGamePath.isEmpty {
                        Button { app.openSelectedGameDirectory() } label: {
                            Label("在 Finder 中显示", systemImage: "folder.badge.gearshape")
                        }
                        .tint(store.settings.accentTint.color)
                        .disabled(app.isBusy || app.isGameRunning)
                    }
                    Text("外部游戏文件由您管理；启动器会更新当前选择的国服客户端，卸载启动器时不会连带删除。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("版本") {
                    HStack {
                        Button { app.checkGameUpdate() } label: {
                            Label("检查更新", systemImage: "magnifyingglass")
                        }
                        Button { app.repairGameNow() } label: {
                            Label("完整性检查与修复", systemImage: "stethoscope")
                        }
                    }
                    .tint(store.settings.accentTint.color)
                    Text("登录相关项目")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .disabled(store.settings.externalGamePath.isEmpty || app.isBusy || app.isGameRunning)
            }
        }.formStyle(.grouped)
    }

    private var graphics: some View {
        Form {
            Section("图形后端") {
                LabeledContent("图形后端", value: "DXMT-only · Metal")
                Toggle("Retina 高清分辨率模式", isOn: retinaBinding)
                Toggle("MSync", isOn: $store.settings.msyncEnabled)
                Toggle("Metal HUD", isOn: $store.settings.metalHUDEnabled)
            }
            .disabled(app.isBusy || app.isGameRunning)
            Section("MetalFX 设置") {
                Toggle("MetalFX 超分辨率", isOn: $store.settings.superResolutionEnabled)
                Picker("MetalFX 模式", selection: $store.settings.xomMetalFxModeEnabled) {
                    Text("默认").tag(false)
                    Text("XOM 模式").tag(true)
                }
                .pickerStyle(.segmented)
                    .disabled(!store.settings.superResolutionEnabled)
                if store.settings.superResolutionEnabled {
                    Text(store.settings.xomMetalFxModeEnabled
                         ? "游戏会以2倍分辨率模运行，可理解为拍照模式"
                         : "游戏会以正常分辨率生效动态DLSS功能")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(app.isBusy || app.isGameRunning)
            Section("帧率") {
                Stepper("帧率上限：\(store.settings.maxFrameRate == 0 ? "关闭" : "\(store.settings.maxFrameRate) FPS")",
                        value: $store.settings.maxFrameRate, in: 0...240, step: 10)
            }
            .disabled(app.isBusy || app.isGameRunning)
        }.formStyle(.grouped)
    }

    private var dalamud: some View {
        Form {
            Section("Dalamud") {
                Picker("启动时使用", selection: dalamudVariantBinding) {
                    ForEach(DalamudVariant.allCases) { variant in
                        Text(variant.title).tag(variant)
                    }
                }
                .pickerStyle(.radioGroup)
                .disabled(app.isBusy || app.isGameRunning)
                Toggle("禁用第三方插件", isOn: $store.settings.noThirdPartyPlugins)
                    .disabled(store.settings.dalamudVariant == .disabled || app.isBusy || app.isGameRunning)
                Text(store.settings.dalamudVariant.description)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("游戏内跨大区传送") {
                Toggle("启用超域旅行服务", isOn: dcTravelBinding)
                    .disabled(store.settings.dalamudVariant == .disabled || app.isBusy || app.isGameRunning)
                Text("默认关闭。开启后为游戏内插件启动真实的国服超域旅行本地服务；游戏运行期间启动器会保持最小化，不会自动退出。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("注入") {
                HStack {
                    Text("延迟")
                    Slider(value: $store.settings.dalamudInjectionDelay, in: 0...15, step: 0.5)
                    Text("\(store.settings.dalamudInjectionDelay, specifier: "%.1f") s").monospacedDigit()
                }
                .disabled(store.settings.dalamudVariant == .disabled || app.isBusy || app.isGameRunning)
            }
            if store.settings.dalamudVariant != .disabled,
               dalamudIsInstalled(store.settings.dalamudVariant) {
                Section("插件目录") {
                    HStack {
                        Text(dalamudPluginDirectoryTitle)
                        Spacer(minLength: 16)
                        Text(store.paths.dalamudPluginDirectory(for: store.settings.dalamudVariant).path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button {
                            app.openDalamudPluginDirectory(store.settings.dalamudVariant)
                        } label: {
                            Image(systemName: "folder")
                        }
                        .help("打开插件目录")
                    }
                    Button {
                        app.openDalamudPluginDirectory(store.settings.dalamudVariant)
                    } label: {
                        Label("在 Finder 中显示", systemImage: "folder.badge.gearshape")
                    }
                    .tint(store.settings.accentTint.color)
                    Text("Dalamud 国服与 Dalamud Soil 各自管理插件，互不影响。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(app.isBusy || app.isGameRunning)
            }
            Section("版本&维护") {
                HStack {
                    Button { app.updateDalamudNow(.china) } label: {
                        Label(dalamudVersionActionTitle(.china),
                              systemImage: dalamudIsInstalled(.china) ? "arrow.clockwise" : "arrow.down.circle")
                    }
                    Button { app.updateDalamudNow(.soil) } label: {
                        Label(dalamudVersionActionTitle(.soil),
                              systemImage: dalamudIsInstalled(.soil) ? "arrow.clockwise" : "arrow.down.circle")
                    }
                }
                .tint(store.settings.accentTint.color)
                HStack {
                    Button { app.repairDalamudNow(.china) } label: {
                        Label("Dalamud国服完整性检查修复", systemImage: "stethoscope")
                    }
                    .disabled(!dalamudIsInstalled(.china) || app.isBusy || app.isGameRunning)
                    Button { app.repairDalamudNow(.soil) } label: {
                        Label("Dalamud Soil完整性检查修复", systemImage: "stethoscope")
                    }
                    .disabled(!dalamudIsInstalled(.soil) || app.isBusy || app.isGameRunning)
                }
                .tint(store.settings.accentTint.color)
                HStack {
                    Button(role: .destructive) { dalamudPendingRemoval = .china } label: {
                        Label("清除 Dalamud 国服", systemImage: "trash")
                    }
                    .disabled(!dalamudIsInstalled(.china) || app.isBusy || app.isGameRunning)
                    Button(role: .destructive) { dalamudPendingRemoval = .soil } label: {
                        Label("清除 Dalamud Soil", systemImage: "trash")
                    }
                    .disabled(!dalamudIsInstalled(.soil) || app.isBusy || app.isGameRunning)
                }
                .tint(.red)
                Text("清除会删除Dalamud及其相关数据插件")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(app.isBusy || app.isGameRunning)
        }.formStyle(.grouped)
    }

    private var launcherVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
    }

    private var gameVersion: String {
        if case .ready(let version) = app.gameState { return version }
        return "未安装"
    }

    private func dalamudVersionStatus(_ variant: DalamudVariant) -> String {
        let root = store.paths.dalamudRoot(for: variant)
        guard let version = CNDalamudUpdater.activeVersion(in: root) else { return "未安装" }
        let coreReady = CNDalamudUpdater.activeInstallationIsReady(in: root)
        let runtimeReady = CNWindowsRuntimeInstaller.installedVersion(paths: store.paths, variant: variant) != nil
        return "\(version) · \(coreReady && runtimeReady ? "正常" : "需要修复")"
    }

    private func dalamudIsInstalled(_ variant: DalamudVariant) -> Bool {
        CNDalamudUpdater.activeVersion(in: store.paths.dalamudRoot(for: variant)) != nil
    }

    private func dalamudVersionActionTitle(_ variant: DalamudVariant) -> String {
        let action = dalamudIsInstalled(variant) ? "检查并更新" : "下载"
        return "\(action) \(variant.title)"
    }

    private var dalamudPluginDirectoryTitle: String {
        switch store.settings.dalamudVariant {
        case .china: return "国服 Dalamud 插件目录"
        case .soil: return "Dalamud Soil 插件目录"
        case .disabled: return "插件目录"
        }
    }

    private var advanced: some View {
        Form {
            Section("组件版本") {
                LabeledContent("启动器", value: launcherVersion)
                LabeledContent("Dalamud 国服", value: dalamudVersionStatus(.china))
                LabeledContent("Dalamud Soil（土月）", value: dalamudVersionStatus(.soil))
                LabeledContent("FFXIV", value: gameVersion)
            }
            Section("诊断日志") {
                Picker("Wine 诊断级别", selection: $store.settings.wineDebug) {
                    Text("关闭").tag("-all")
                    Text("错误").tag("err+all")
                    Text("详细").tag("+all")
                }
                Text("仅影响 Wine 启动时的诊断输出；正常使用保持“关闭”即可。日志会写入 XIVCN Mac Launcher 的日志目录。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(app.isBusy || app.isGameRunning)
            Section("键盘映射") {
                Toggle("左 Option", isOn: $store.settings.leftOptionIsAlt)
                Toggle("右 Option", isOn: $store.settings.rightOptionIsAlt)
                Toggle("左 Command", isOn: $store.settings.leftCommandIsControl)
                Toggle("右 Command", isOn: $store.settings.rightCommandIsControl)
            }
            .disabled(app.isBusy || app.isGameRunning)
            Section("文件") {
                HStack {
                    Button { NSWorkspace.shared.open(store.paths.logs) } label: { Label("日志", systemImage: "doc.text") }
                    Button { NSWorkspace.shared.open(store.paths.config) } label: { Label("配置", systemImage: "folder") }
                    Button { NSWorkspace.shared.open(store.paths.caches) } label: { Label("缓存", systemImage: "shippingbox") }
                }
                .tint(store.settings.accentTint.color)
            }
            Section("运行环境") {
                Button { confirmsRuntimeReset = true } label: {
                    Label("重置 Wine / DXMT 运行环境", systemImage: "arrow.counterclockwise")
                }
                .tint(.red)
                .disabled(app.isBusy || app.isGameRunning)
                Text("仅在启动异常时使用。会重建 Wine Prefix、重新部署应用内置 DXMT 并同步当前设置，不会删除游戏、账号或启动器设置。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("卸载数据") {
                Button(role: .destructive) { confirmsCleanUninstall = true } label: {
                    Label("移除所有启动器数据…", systemImage: "trash")
                }
                .tint(.red)
                .disabled(app.isBusy || app.isGameRunning)
                Text("应用内完整卸载会删除本项目 Keychain 条目、设置、设备标识、缓存、日志、两套 Dalamud 及其相关数据，并删除启动器管理的游戏；外部游戏不会删除。Finder 中直接删除 App 不会触发 Keychain 清理。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    private var retinaBinding: Binding<Bool> {
        Binding(get: { store.settings.retinaEnabled }, set: { store.settings.macOSScalingEnabled = !$0 })
    }

    private var quickLoginPersistenceBinding: Binding<Bool> {
        Binding(get: { store.settings.quickLoginEnabled }, set: { app.setQuickLoginPersistence($0) })
    }

    @ViewBuilder
    private func appearanceSwatch(_ mode: AppearanceMode) -> some View {
        switch mode {
        case .auto:
            Circle()
                .fill(LinearGradient(colors: [.white, .gray, .black], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(Circle().stroke(.primary.opacity(0.22), lineWidth: 0.5))
                .frame(width: 13, height: 13)
        case .light:
            Circle().fill(.white).overlay(Circle().stroke(.gray, lineWidth: 0.6)).frame(width: 13, height: 13)
        case .dark:
            Circle().fill(.black).overlay(Circle().stroke(.gray, lineWidth: 0.6)).frame(width: 13, height: 13)
        }
    }

    private var dcTravelBinding: Binding<Bool> {
        Binding(get: { store.settings.dcTravelEnabled }, set: { enabled in
            if enabled, !store.settings.dcTravelEnabled {
                confirmsDCTravelEnable = true
            } else if !enabled {
                app.setDCTravelEnabled(false)
            }
        })
    }

    private var gameOwnershipBinding: Binding<GameOwnership> {
        Binding(get: { store.settings.gameOwnership }, set: { app.selectGameInstall($0) })
    }

    private var dalamudVariantBinding: Binding<DalamudVariant> {
        Binding(get: { store.settings.dalamudVariant }, set: { app.selectDalamudVariant($0) })
    }

    private var externalGamePathBinding: Binding<String> {
        Binding(get: { store.settings.externalGamePath }, set: { value in
            store.settings.setExternalGamePath(value, select: false, managedPath: store.paths.managedGame.path)
            if store.settings.gameOwnership == .external { app.scheduleGameStateRefresh() }
        })
    }

    private var areaBinding: Binding<String> {
        Binding(get: { store.settings.cnAreaID }, set: { id in
            if let area = app.availableAreas.first(where: { $0.id == id && $0.status == 1 }) { app.selectArea(area) }
        })
    }

    private var gameStateDescription: String {
        switch app.gameState {
        case .missing: return "未找到"
        case .incomplete(let reason): return "不完整：\(reason)"
        case .ready(let version): return "可用 · \(version)"
        }
    }

    private var gameReady: Bool {
        if case .ready = app.gameState { return true }
        return false
    }

    private func savedAccountDetail(_ saved: CNSavedAccount) -> String {
        var details: [String] = []
        if saved.hasQuickLogin { details.append("快速续登") }
        if saved.hasPassword { details.append("已保存密码") }
        if saved.hasSession { details.append("会话") }
        return details.isEmpty ? "无可用凭据" : details.joined(separator: " · ")
    }

    @ViewBuilder
    private func appearanceChoice(_ mode: AppearanceMode, title: String) -> some View {
        HStack(spacing: 7) {
            switch mode {
            case .auto:
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(LinearGradient(colors: [.white, .gray, .black], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(.secondary.opacity(0.45), lineWidth: 0.5))
                    .frame(width: 18, height: 18)
            case .light:
                Circle().fill(Color.white).overlay(Circle().stroke(.gray.opacity(0.6), lineWidth: 0.5)).frame(width: 18, height: 18)
            case .dark:
                Circle().fill(Color.black).overlay(Circle().stroke(.gray.opacity(0.7), lineWidth: 0.5)).frame(width: 18, height: 18)
            }
            Text(title)
        }
        .tag(mode)
    }
}
