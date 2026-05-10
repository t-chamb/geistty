import SwiftUI
import GhosttyKit
import os

private let logger = Logger(subsystem: "com.geistty", category: "AppLifecycle")

/// Wrapper view that creates per-window AppState for multi-window support
struct WindowContentView: View {
    // Each window gets its own AppState instance
    @StateObject private var appState = AppState()
    
    // Track scene phase for File Provider sync
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some View {
        ContentView()
            .environmentObject(appState)
            .onChange(of: scenePhase) { oldPhase, newPhase in
                handleScenePhaseChange(from: oldPhase, to: newPhase)
            }
    }
    
    /// Handle scene phase changes
    /// App lifecycle handling for potential future features
    private func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
        switch newPhase {
        case .active:
            if oldPhase == .background || oldPhase == .inactive {
                logger.info("📱 App became active")
            }
            
        case .background:
            logger.debug("📱 App entering background")
            
        case .inactive:
            break
            
        @unknown default:
            break
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var profileManager = ConnectionProfileManager.shared
    @State private var showConnectionSheet = false
    @State private var showConnectionList = false
    @State private var showSettings = false
    @State private var showSSHKeyManager = false
    @State private var connectionInfo = ConnectionInfo()
    @State private var connectedSession: SSHSession?
    
    /// Theme background color for consistent styling
    private var themeBackground: Color {
        Color(ThemeManager.shared.selectedTheme.background)
    }
    
    var body: some View {
        // When connected, show ONLY the terminal - no NavigationStack, no chrome
        // This ensures the DisconnectedView is completely removed from hierarchy
        Group {
            if appState.connectionStatus == .connected || appState.connectionStatus == .connecting {
                TerminalContainerView()
                    .background(themeBackground)
            } else {
                // Non-connected states use NavigationStack with welcome/error UI
                NavigationStack {
                    Group {
                        switch appState.connectionStatus {
                        case .disconnected:
                            DisconnectedView(
                                showConnectionSheet: $showConnectionSheet,
                                showConnectionList: $showConnectionList,
                                backgroundColor: themeBackground,
                                lastProfile: profileManager.recents.first,
                                savedCount: profileManager.profiles.count,
                                onReconnectLast: reconnectLast
                            )
                        case .connecting, .connected:
                            // Both handled by outer `if` — required for exhaustiveness
                            EmptyView()
                        case .error(let message):
                            ErrorView(
                                message: message,
                                showConnectionSheet: $showConnectionSheet,
                                backgroundColor: themeBackground,
                                onReconnect: reconnect
                            )
                        }
                    }
                    .navigationTitle("Geistty")
                    .toolbar {
                        // Settings on the trailing edge — matches iOS convention
                        // (top-left is reserved for back/cancel). The disconnected
                        // home has its own large-button CTAs, so the previous
                        // top-right `+` Menu was redundant and has been removed.
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                showSettings = true
                            } label: {
                                Image(systemName: "gearshape")
                            }
                            .accessibilityIdentifier("SettingsButton")
                        }
                    }
                }
                .background(themeBackground)
                .sheet(isPresented: $showConnectionSheet) {
                    ConnectionSheet(connectionInfo: $connectionInfo, onConnect: connect)
                }
                .sheet(isPresented: $showConnectionList) {
                    ConnectionListView { session in
                        // Session already connected via ConnectionListView
                        connectedSession = session
                        appState.sshSession = session
                        appState.connectionStatus = .connected
                        showConnectionList = false
                    }
                }
            }
        }
        // The terminal-fullscreen ↔ NavigationStack handoff produces a
        // visible chrome flash if animated. Only kill animations on that
        // specific transition; leave other state changes (sheet
        // present/dismiss, error → reconnect) free to animate normally.
        .animation(nil, value: appState.connectionStatus)
        // Handle navigation notifications from menu bar.
        // H13 fix: Guard on scenePhase == .active to prevent inactive/background
        // scenes from processing keyboard shortcut notifications on multi-window iPad.
        .onReceive(NotificationCenter.default.publisher(for: .showNewConnection)) { _ in
            guard scenePhase == .active else { return }
            // Only disconnect if there's an active session to disconnect
            if appState.connectionStatus != .disconnected {
                disconnectAndReset()
            }
            showConnectionList = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showQuickConnect)) { _ in
            guard scenePhase == .active else { return }
            // Only disconnect if there's an active session to disconnect
            if appState.connectionStatus != .disconnected {
                disconnectAndReset()
            }
            showConnectionSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showConnectionProfiles)) { _ in
            guard scenePhase == .active else { return }
            // Only disconnect if there's an active session to disconnect
            if appState.connectionStatus != .disconnected {
                disconnectAndReset()
            }
            showConnectionList = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .terminalDisconnect)) { _ in
            guard scenePhase == .active else { return }
            // Disconnect active session and go back to disconnected state
            disconnectAndReset()
        }
        .onReceive(NotificationCenter.default.publisher(for: .terminalReconnect)) { _ in
            guard scenePhase == .active else { return }
            reconnect()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showSettings)) { _ in
            guard scenePhase == .active else { return }
            showSettings = true
        }
        // Shortcuts.app + Siri integration. The OpenConnectionIntent
        // (defined in GeisttyApp.swift) posts this with userInfo["profileId"]
        // set to the picked profile's UUID. We resolve to the live profile
        // and reuse the home-screen reconnect path so the SSH layer goes
        // through the same code that powers the Reconnect button.
        .onReceive(NotificationCenter.default.publisher(for: .openSpecificProfile)) { note in
            guard scenePhase == .active else { return }
            guard let id = note.userInfo?["profileId"] as? UUID,
                  let profile = profileManager.profiles.first(where: { $0.id == id })
            else { return }
            // If something else is connected, tear it down first so the
            // shortcut always lands the user on the requested profile.
            if appState.connectionStatus != .disconnected {
                disconnectAndReset()
            }
            reconnectLast(profile)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showSSHKeyManager)) { _ in
            guard scenePhase == .active else { return }
            showSSHKeyManager = true
        }
        .sheet(isPresented: $showSSHKeyManager) {
            NavigationStack {
                SSHKeyListView()
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }
    
    private func connect() {
        // Store connection info in app state so TerminalContainerView can use it
        appState.setConnectionParams(
            host: connectionInfo.host,
            port: connectionInfo.port,
            username: connectionInfo.username,
            password: connectionInfo.password
        )
        
        // Transition to .connecting — TerminalContainerView mounts immediately
        // and initiates the SSH handshake. It transitions to .connected on success
        // or .error on failure via setupConnection().
        appState.connectionStatus = .connecting
        showConnectionSheet = false
    }
    
    /// Disconnect the active SSH session and reset to disconnected state (C3 fix).
    /// Prevents leaking active SSH connections when navigating away.
    private func disconnectAndReset() {
        appState.sshSession?.disconnect()
        appState.clearConnectionParams()
        appState.connectionStatus = .disconnected
    }
    
    /// Shared reconnect logic — used by both the notification handler and ErrorView
    /// button. Checks canReconnect, transitions to .connecting, awaits reconnect,
    /// and sets final state based on session outcome. See #27.
    private func reconnect() {
        guard let session = appState.sshSession, session.canReconnect else {
            appState.connectionStatus = .error("No session available for reconnect")
            return
        }
        appState.connectionStatus = .connecting
        Task {
            await session.attemptReconnect()
            // If reconnect failed and we're still in .connecting, transition
            // to error. Surface the underlying SSH error rather than a generic
            // "Reconnect failed" so users can distinguish auth, host-down,
            // network failure, etc.
            if session.state == .disconnected && appState.connectionStatus == .connecting {
                let detail = session.lastError?.localizedDescription
                    ?? "Network unreachable or host did not respond"
                appState.connectionStatus = .error("Reconnect failed: \(detail)")
            }
        }
    }

    /// One-tap reconnect to the most recent saved profile from the home screen.
    /// Reuses the connecting/error pipeline by populating connection params and
    /// flipping `connectionStatus = .connecting`; TerminalContainerView mounts
    /// and runs the SSH handshake. Password resolution falls to the keychain
    /// path that powers ConnectionListView's row tap.
    private func reconnectLast(_ profile: ConnectionProfile) {
        let resolvedPassword = (try? KeychainManager.shared.getPassword(
            for: profile.host,
            username: profile.username
        )) ?? ""
        appState.setConnectionParams(
            host: profile.host,
            port: profile.port,
            username: profile.username,
            password: resolvedPassword
        )
        appState.currentUseMosh = profile.useMosh
        appState.connectionStatus = .connecting
        ConnectionProfileManager.shared.markConnected(profile)
    }
}

// MARK: - Sub Views

struct DisconnectedView: View {
    @Binding var showConnectionSheet: Bool
    @Binding var showConnectionList: Bool
    let backgroundColor: Color
    /// Most recent saved profile, used to power the one-tap "Reconnect" CTA.
    let lastProfile: ConnectionProfile?
    /// Total saved profile count — surfaced as a badge so users can see at a
    /// glance whether the saved list is populated without entering it.
    let savedCount: Int
    let onReconnectLast: (ConnectionProfile) -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "terminal")
                .font(.system(size: 80))
                .foregroundStyle(.secondary)

            Text("No Active Connection")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("DisconnectedTitle")

            VStack(spacing: 12) {
                // Highest-leverage action: reconnect to the last-used host.
                // Only shown when we have a recent profile to reconnect to.
                if let last = lastProfile {
                    Button {
                        onReconnectLast(last)
                    } label: {
                        Label {
                            VStack(spacing: 2) {
                                Text("Reconnect")
                                    .font(.body.weight(.semibold))
                                Text(connectionLabel(for: last))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .frame(maxWidth: 220)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("DisconnectedReconnectLastButton")
                }

                // Quick Connect is the primary CTA when there's no recent
                // profile to reconnect to; demoted to secondary when one
                // exists (Reconnect outranks it).
                Group {
                    if lastProfile == nil {
                        Button {
                            showConnectionSheet = true
                        } label: {
                            Label("Quick Connect", systemImage: "bolt.fill")
                                .frame(maxWidth: 200)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button {
                            showConnectionSheet = true
                        } label: {
                            Label("Quick Connect", systemImage: "bolt.fill")
                                .frame(maxWidth: 200)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .accessibilityIdentifier("DisconnectedQuickConnectButton")

                Button {
                    showConnectionList = true
                } label: {
                    HStack(spacing: 6) {
                        Label("Saved Connections", systemImage: "list.bullet")
                        if savedCount > 0 {
                            Text("\(savedCount)")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.2), in: Capsule())
                                .accessibilityLabel("\(savedCount) saved")
                        }
                    }
                    .frame(maxWidth: 200)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("DisconnectedSavedConnectionsButton")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundColor)
    }

    private func connectionLabel(for profile: ConnectionProfile) -> String {
        if profile.port == 22 {
            return "\(profile.username)@\(profile.host)"
        }
        return "\(profile.username)@\(profile.host):\(profile.port)"
    }
}

struct ConnectingView: View {
    let backgroundColor: Color
    
    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
                .accessibilityIdentifier("ConnectingSpinner")
            
            Text("Connecting...")
                .font(.headline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("ConnectingLabel")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundColor)
    }
}

struct ErrorView: View {
    let message: String
    @Binding var showConnectionSheet: Bool
    let backgroundColor: Color
    /// Shared reconnect action provided by ContentView. See #27.
    let onReconnect: () -> Void
    @EnvironmentObject var appState: AppState
    
    /// Formatted connection info for display
    private var connectionDescription: String? {
        guard let host = appState.currentHost,
              let username = appState.currentUsername else {
            return nil
        }
        let port = appState.currentPort ?? 22
        if port == 22 {
            return "\(username)@\(host)"
        } else {
            return "\(username)@\(host):\(port)"
        }
    }
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 60))
                .foregroundStyle(.orange)
            
            Text("Disconnected")
                .font(.title2)
                .accessibilityIdentifier("ErrorTitle")
            
            // Show which connection was lost
            if let conn = connectionDescription {
                Text(conn)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("ErrorConnectionDescription")
            }
            
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .accessibilityIdentifier("ErrorMessage")
            
            VStack(spacing: 12) {
                // Reconnect button — delegates to shared reconnect() via closure. See #27.
                if let session = appState.sshSession, session.canReconnect {
                    Button {
                        onReconnect()
                    } label: {
                        Label("Reconnect", systemImage: "arrow.clockwise")
                            .frame(maxWidth: 200)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("ReconnectButton")
                }
                
                Button {
                    appState.clearConnectionParams()
                    appState.connectionStatus = .disconnected
                } label: {
                    Label("Back to Connections", systemImage: "list.bullet")
                        .frame(maxWidth: 200)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("BackToConnectionsButton")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundColor)
    }
}

// MARK: - Connection Sheet

struct ConnectionInfo {
    // Defaults are intentionally empty in all builds. The DEBUG-only
    // "Use test.rebex.net" button in ConnectionSheet populates the test
    // credentials on tap when needed; pre-filling fields obscured the
    // empty-state and surfaced demo creds in dev screenshots / TestFlight.
    var host: String = ""
    var username: String = ""
    var password: String = ""
    var port: Int = 22
}

/// Reusable Host/Port/Username/Password form fields with field-level pre-flight
/// validation. Used by both ConnectionSheet (lightweight one-shot) and
/// ConnectionListView.QuickConnectView (one-shot + save-to-profiles).
/// The two wrappers diverge in their action surface (just collect-and-dispatch
/// vs. connect-and-save), but the field UI is identical and lives here.
struct ConnectionFormFields: View {
    @Binding var host: String
    @Binding var port: String
    @Binding var username: String
    @Binding var password: String
    /// Prefix for accessibility identifiers so the two wrappers can be
    /// distinguished in UI tests (e.g. "Sheet" → "SheetHostField").
    let idPrefix: String

    var body: some View {
        Section("Server") {
            TextField("Host", text: $host)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .accessibilityIdentifier("\(idPrefix)HostField")

            HStack {
                Text("Port")
                Spacer()
                TextField("22", text: $port)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .accessibilityIdentifier("\(idPrefix)PortField")
            }
        }

        Section("Authentication") {
            TextField("Username", text: $username)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("\(idPrefix)UsernameField")

            SecureField("Password", text: $password)
                .textContentType(.password)
                .accessibilityIdentifier("\(idPrefix)PasswordField")
        }

        // Pre-flight feedback — surfaces obvious typos (spaces, scheme prefix)
        // before the user wastes a round-trip to the SSH layer.
        if let warning = ConnectionFormFields.hostWarning(host) {
            Section {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .accessibilityIdentifier("\(idPrefix)HostWarning")
            }
        }
    }

    /// Cheap structural sanity check on a hostname/IP. Catches obvious user
    /// errors (URL scheme, embedded spaces, slash-paths) without trying to
    /// validate DNS. Returns nil for any plausibly-valid host.
    static func hostWarning(_ host: String) -> String? {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil } // Connect button handles emptiness
        if trimmed != host { return "Host has leading/trailing whitespace" }
        if host.contains(" ") { return "Host can't contain spaces" }
        if host.contains("://") { return "Host should not include 'ssh://' or any scheme" }
        if host.contains("/") { return "Host should not include a path" }
        if host.hasPrefix("@") || host.contains("@") { return "Use the Username field instead of user@host" }
        return nil
    }

    /// Combined validity check — host is non-empty + structurally sane,
    /// username non-empty, port in [1, 65535].
    static func isValid(host: String, port: String, username: String) -> Bool {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty, !username.isEmpty else { return false }
        guard let p = Int(port), (1...65535).contains(p) else { return false }
        return hostWarning(h) == nil
    }
}

struct ConnectionSheet: View {
    @Binding var connectionInfo: ConnectionInfo
    let onConnect: () -> Void
    @Environment(\.dismiss) private var dismiss

    /// Local string binding for port so the field surface matches the
    /// shared ConnectionFormFields. Synced back to connectionInfo.port on
    /// change for downstream consumers that read the int.
    @State private var portText: String = "22"

    var body: some View {
        NavigationStack {
            Form {
                ConnectionFormFields(
                    host: $connectionInfo.host,
                    port: $portText,
                    username: $connectionInfo.username,
                    password: $connectionInfo.password,
                    idPrefix: "Sheet"
                )

                Section {
                    Button("Connect") {
                        connectionInfo.port = Int(portText) ?? 22
                        onConnect()
                    }
                    .disabled(!ConnectionFormFields.isValid(
                        host: connectionInfo.host,
                        port: portText,
                        username: connectionInfo.username
                    ))
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("SheetConnectButton")
                }

                #if DEBUG
                Section("Test Servers") {
                    Button("Use test.rebex.net") {
                        connectionInfo.host = "test.rebex.net"
                        portText = "22"
                        connectionInfo.port = 22
                        connectionInfo.username = "demo"
                        connectionInfo.password = "password"
                    }
                    .foregroundColor(.blue)
                }
                #endif
            }
            .navigationTitle("New Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .accessibilityIdentifier("SheetCancelButton")
                }
            }
            .onAppear { portText = String(connectionInfo.port) }
        }
    }
}

#Preview {
    WindowContentView()
        .environmentObject(Ghostty.App())
}
