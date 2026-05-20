//
//  ContentView.swift
//  StikDebug
//
//  Created by Stephen on 3/26/25.
//

import SwiftUI
import UIKit

struct JITEnableConfiguration {
    var bundleID: String? = nil
    var pid : Int? = nil
    var scriptData: Data? = nil
    var scriptName : String? = nil
}

private enum ExternalURLAction: Identifiable {
    case enableJIT(JITEnableConfiguration)
    case killProcess(Int)
    case launchApp(String)

    var id: String {
        switch self {
        case .enableJIT(let config):
            return "enable-\(config.bundleID ?? "")-\(config.pid ?? 0)-\(config.scriptName ?? "")"
        case .killProcess(let pid):
            return "kill-\(pid)"
        case .launchApp(let bundleID):
            return "launch-\(bundleID)"
        }
    }

    var title: String {
        switch self {
        case .enableJIT:
            return "Enable JIT?"
        case .killProcess:
            return "Kill Process?"
        case .launchApp:
            return "Launch App?"
        }
    }

    var message: String {
        switch self {
        case .enableJIT(let config):
            let scriptText = config.scriptData == nil ? "" : " and run a script"
            return "An external link wants to enable JIT\(scriptText) for \(targetDescription(for: config))."
        case .killProcess(let pid):
            return "An external link wants to kill process \(pid)."
        case .launchApp(let bundleID):
            return "An external link wants to launch \(bundleID)."
        }
    }

    var confirmationTitle: String {
        switch self {
        case .enableJIT(let config):
            return config.scriptData == nil ? "Enable JIT" : "Enable and Run Script"
        case .killProcess:
            return "Kill Process"
        case .launchApp:
            return "Launch App"
        }
    }

    var role: ButtonRole? {
        switch self {
        case .enableJIT(let config):
            return config.scriptData == nil ? nil : .destructive
        case .killProcess:
            return .destructive
        case .launchApp:
            return nil
        }
    }

    private func targetDescription(for config: JITEnableConfiguration) -> String {
        if let bundleID = config.bundleID {
            return bundleID
        }
        if let pid = config.pid {
            return "process \(pid)"
        }
        return "the requested app"
    }
}

private final class DebugKeepAliveLease {
    private let stateLock = NSLock()
    private var isActive = false
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    init() {
        activate()
    }

    func invalidate() {
        stateLock.lock()
        guard isActive else {
            stateLock.unlock()
            return
        }
        isActive = false
        stateLock.unlock()

        runOnMain {
            BackgroundAudioManager.shared.requestStop()
            BackgroundLocationManager.shared.requestStop()

            if self.backgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(self.backgroundTaskID)
                self.backgroundTaskID = .invalid
            }
        }
    }

    private func activate() {
        stateLock.lock()
        guard !isActive else {
            stateLock.unlock()
            return
        }
        isActive = true
        stateLock.unlock()

        runOnMain {
            BackgroundAudioManager.shared.requestStart()
            BackgroundLocationManager.shared.requestStart()
            self.backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "StikDebugDebugSession") { [weak self] in
                LogManager.shared.addWarningLog("Debug session background task expired")
                self?.invalidate()
            }
        }
    }

    private func runOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
    }
}

struct HomeView: View {

    @AppStorage("autoQuitAfterEnablingJIT") private var doAutoQuitAfterEnablingJIT = false
    @AppStorage("bundleID") private var bundleID: String = ""
    @State private var isProcessing = false
    @State private var viewDidAppeared = false
    @State private var pendingJITEnableConfiguration : JITEnableConfiguration? = nil
    @State private var isShowingPairingFilePicker = false
    @State private var debugFeedback: DebugFeedback?
    @State private var pendingExternalURLAction: ExternalURLAction?

    @State var scriptViewShow = false
    @State private var isShowingConsole = false
    @AppStorage(UserDefaults.Keys.defaultScriptName) var selectedScript = UserDefaults.Keys.defaultScriptNameValue
    @State var jsModel: RunJSViewModel?
    @ObservedObject private var mounting = MountingProgress.shared

    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private struct DebugFeedback: Identifiable {
        let id = UUID()
        let message: String
        let isError: Bool
        let isWorking: Bool
    }

    var body: some View {
        InstalledAppsListView(onSelectApp: { selectedBundle, selectedName in
            bundleID = selectedBundle
            HapticFeedbackHelper.trigger()
            startJITInBackground(bundleID: selectedBundle, displayName: selectedName)
        }, showDoneButton: false, onImportPairingFile: { isShowingPairingFilePicker = true })
        .overlay(alignment: .bottom) {
            if let debugFeedback {
                debugFeedbackView(debugFeedback)
                    .padding(.bottom, 40)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onAppear {
            startTunnelInBackground()
            MountingProgress.shared.checkforMounted()
            viewDidAppeared = true
            if let config = pendingJITEnableConfiguration {
                startJITInBackground(bundleID: config.bundleID, pid: config.pid, scriptData: config.scriptData, scriptName: config.scriptName, triggeredByURLScheme: true)
                pendingJITEnableConfiguration = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .intentJSScriptReady)) { notification in
            guard let model = notification.userInfo?["model"] as? RunJSViewModel else { return }
            jsModel = model
            if let name = notification.userInfo?["scriptName"] as? String {
                selectedScript = name
            }
            scriptViewShow = true
        }
        .onReceive(timer) { _ in
            if mounting.mountingThread == nil && !mounting.coolisMounted {
                MountingProgress.shared.checkforMounted()
            }
        }
        .onOpenURL { url in
            handleExternalURL(url)
        }
        .confirmationDialog(
            pendingExternalURLAction?.title ?? "External Request",
            isPresented: Binding(
                get: { pendingExternalURLAction != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingExternalURLAction = nil
                    }
                }
            ),
            titleVisibility: .visible,
            presenting: pendingExternalURLAction
        ) { action in
            Button(action.confirmationTitle, role: action.role) {
                performExternalURLAction(action)
                pendingExternalURLAction = nil
            }
            Button("Cancel", role: .cancel) {
                pendingExternalURLAction = nil
            }
        } message: { action in
            Text(action.message)
        }
        .fileImporter(isPresented: $isShowingPairingFilePicker, allowedContentTypes: PairingFileStore.supportedContentTypes) { result in
            switch result {
            case .success(let url):
                let fileManager = FileManager.default
                do {
                    try PairingFileStore.importFromPicker(url, fileManager: fileManager)
                    pubTunnelConnected = false
                    startTunnelInBackground()
                    NotificationCenter.default.post(name: .pairingFileImported, object: nil)
                    // Dismiss any existing connection error alert
                    if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                       let root = scene.windows.first?.rootViewController {
                        var top = root
                        while let presented = top.presentedViewController { top = presented }
                        if top is UIAlertController { top.dismiss(animated: true) }
                    }
                } catch {
                    print("Error copying pairing file: \(error)")
                }
            case .failure(let error):
                print("Failed to import pairing file: \(error)")
            }
        }
        .sheet(isPresented: $isShowingConsole) {
            NavigationStack {
                ConsoleLogsView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") {
                                isShowingConsole = false
                            }
                        }
                    }
            }
        }
        .sheet(isPresented: $scriptViewShow) {
            NavigationStack {
                if let jsModel {
                    RunJSView(model: jsModel)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { scriptViewShow = false }
                            }
                        }
                        .navigationTitle(selectedScript)
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
    }

    private func queryValue(_ names: [String], in components: URLComponents?) -> String? {
        guard let queryItems = components?.queryItems else { return nil }
        for name in names {
            if let rawValue = queryItems.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.value {
                let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    return value
                }
            }
        }
        return nil
    }

    private func handleExternalURL(_ url: URL) {
        guard let host = url.host()?.lowercased() else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

        switch host {
        case "enable-jit":
            var config = JITEnableConfiguration()
            if let pidStr = queryValue(["pid"], in: components), let pid = Int(pidStr) {
                config.pid = pid
            }
            if let bundleId = queryValue(["bundle-id", "bundleID", "bundle_id", "bundleId"], in: components) {
                config.bundleID = bundleId
            }
            if let scriptBase64URL = queryValue(["script-data", "scriptData", "script_data"], in: components)?.removingPercentEncoding {
                let base64 = base64URLToBase64(scriptBase64URL)
                if let scriptData = Data(base64Encoded: base64) {
                    config.scriptData = scriptData
                }
            }
            if let scriptName = queryValue(["script-name", "scriptName", "script_name"], in: components) {
                config.scriptName = scriptName
            }
            if config.scriptData == nil, let bundleID = config.bundleID,
               let scriptInfo = ScriptStore.preferredScript(for: bundleID) {
                config.scriptData = scriptInfo.data
                config.scriptName = scriptInfo.name
            }
            pendingExternalURLAction = .enableJIT(config)
        case "kill-process":
            if let pidStr = queryValue(["pid"], in: components), let pid = Int(pidStr) {
                pendingExternalURLAction = .killProcess(pid)
            }
        case "launch-app":
            if let bundleId = queryValue(["bundle-id", "bundleID", "bundle_id", "bundleId"], in: components) {
                pendingExternalURLAction = .launchApp(bundleId)
            }
        default:
            break
        }
    }

    private func performExternalURLAction(_ action: ExternalURLAction) {
        switch action {
        case .enableJIT(let config):
            if viewDidAppeared {
                startJITInBackground(
                    bundleID: config.bundleID,
                    pid: config.pid,
                    scriptData: config.scriptData,
                    scriptName: config.scriptName,
                    triggeredByURLScheme: true
                )
            } else {
                pendingJITEnableConfiguration = config
            }
        case .killProcess(let pid):
            pubTunnelConnected = false
            startTunnelInBackground(showErrorUI: false)
            DispatchQueue.global(qos: .userInitiated).async {
                sleep(1)
                do {
                    try JITEnableContext.shared.killProcess(withPID: Int32(pid))
                    DispatchQueue.main.async {
                        LogManager.shared.addInfoLog("Killed process \(pid) via URL scheme")
                    }
                } catch {
                    DispatchQueue.main.async {
                        LogManager.shared.addErrorLog("Failed to kill process \(pid): \(error.localizedDescription)")
                    }
                }
            }
        case .launchApp(let bundleID):
            HapticFeedbackHelper.trigger()
            DispatchQueue.global(qos: .userInitiated).async {
                let _ = JITEnableContext.shared.launchAppWithoutDebug(bundleID, logger: nil)
            }
        }
    }

    private func debugFeedbackView(_ feedback: DebugFeedback) -> some View {
        HStack(spacing: 10) {
            if feedback.isWorking {
                ProgressView()
                    .controlSize(.small)
            }

            Text(feedback.message)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Capsule().fill(.ultraThinMaterial))
        .foregroundStyle(feedback.isError ? .red : .primary)
        .shadow(radius: 4)
        .padding(.horizontal, 20)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(feedback.message)
    }

    private func getJsCallback(_ script: Data, name: String? = nil) -> DebugAppCallback {
        return { pid, debugProxyHandle, remoteServerHandle, semaphore in
            let model = RunJSViewModel(pid: Int(pid),
                                       debugProxy: debugProxyHandle,
                                       remoteServer: remoteServerHandle,
                                       semaphore: semaphore)

            DispatchQueue.main.async {
                jsModel = model
                scriptViewShow = true
            }

            do {
                try model.runScript(data: script, name: name)
            } catch {
                semaphore.signal()
                DispatchQueue.main.async {
                    showAlert(title: "Error Occurred While Executing Script.".localized, message: error.localizedDescription, showOk: true)
                }
            }
        }
    }

    private func startJITInBackground(bundleID: String? = nil, pid: Int? = nil, scriptData: Data? = nil, scriptName: String? = nil, triggeredByURLScheme: Bool = false, displayName: String? = nil) {
        isProcessing = true
        let targetName = displayName ?? bundleID ?? pid.map { String(format: "process %d".localized, $0) } ?? "app".localized
        let startingMessage = String(format: "Starting JIT for %@".localized, targetName)
        LogManager.shared.addInfoLog("Starting Debug for \(bundleID ?? String(pid ?? 0))")
        withAnimation {
            debugFeedback = DebugFeedback(message: startingMessage, isError: false, isWorking: true)
        }
        AccessibilityAnnouncer.announce(startingMessage)

        if triggeredByURLScheme {
            pubTunnelConnected = false
            startTunnelInBackground(showErrorUI: false)
        }

        DispatchQueue.global(qos: .background).async {
            let keepAliveLease = DebugKeepAliveLease()
            defer { keepAliveLease.invalidate() }

            if triggeredByURLScheme {
                sleep(1)
            }

            let finishProcessing: (Bool, String?) -> Void = { success, detail in
                DispatchQueue.main.async {
                    isProcessing = false
                    let message = success
                        ? String(format: "JIT request completed for %@".localized, targetName)
                        : String(format: "JIT failed for %@".localized, targetName)
                    let feedback = DebugFeedback(message: message, isError: !success, isWorking: false)
                    withAnimation {
                        debugFeedback = feedback
                    }
                    AccessibilityAnnouncer.announce(message)

                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        if debugFeedback?.id == feedback.id {
                            withAnimation {
                                debugFeedback = nil
                            }
                        }
                    }

                    if !success {
                        let failureMessage = detail ?? "StikDebug could not launch or attach to the selected app. Check that the VPN is enabled, the pairing file is current, and the app is still installed.".localized
                        showAlert(title: "Failed to Enable JIT".localized, message: failureMessage, showOk: true)
                    }
                }
            }

            var scriptData = scriptData
            var scriptName = scriptName
            if scriptData == nil,
               let bundleID,
               let preferred = ScriptStore.preferredScript(for: bundleID) {
                scriptName = preferred.name
                scriptData = preferred.data
            }

            var callback: DebugAppCallback? = nil
            if ProcessInfo.processInfo.hasTXM, let sd = scriptData {
                callback = getJsCallback(sd, name: scriptName ?? bundleID ?? "Script")
            }

            var lastDebugMessage: String?
            let logger: LogFunc = { message in
                if let message {
                    lastDebugMessage = message
                    LogManager.shared.addInfoLog(message)
                }
            }
            var success: Bool
            if let pid {
                success = JITEnableContext.shared.debugApp(withPID: Int32(pid), logger: logger, jsCallback: callback)
            } else if let bundleID {
                success = JITEnableContext.shared.debugApp(withBundleID: bundleID, logger: logger, jsCallback: callback)
            } else {
                lastDebugMessage = "Either bundle ID or PID should be specified.".localized
                success = false
            }

            if success {
                DispatchQueue.main.async {
                    LogManager.shared.addInfoLog("Debug process completed for \(bundleID ?? String(pid ?? 0))")

                    if doAutoQuitAfterEnablingJIT {
                        exit(0)
                    }
                }
            }
            finishProcessing(success, success ? nil : lastDebugMessage)
        }
    }

    private func base64URLToBase64(_ base64url: String) -> String {
        var base64 = base64url.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let pad = 4 - (base64.count % 4)
        if pad < 4 { base64 += String(repeating: "=", count: pad) }
        return base64
    }
}

#Preview {
    HomeView()
}

public extension ProcessInfo {
    var hasTXM: Bool {
        if isTXMOverridden {
            return true
        }
        return ProcessInfo.hasTXMSupport(
            operatingSystemVersion: operatingSystemVersion,
            localTXMDetector: ProcessInfo.detectLocalTXM
        )
    }

    var isTXMOverridden: Bool {
        UserDefaults.standard.bool(forKey: UserDefaults.Keys.txmOverride)
    }

    static func hasTXMSupport(
        operatingSystemVersion: OperatingSystemVersion,
        localTXMDetector: () -> Bool
    ) -> Bool {
        guard operatingSystemVersion.majorVersion >= 26 else {
            return false
        }
        return localTXMDetector()
    }

    private static func detectLocalTXM() -> Bool {
        if let boot = FileManager.default.filePath(atPath: "/System/Volumes/Preboot", withLength: 36),
           let file = FileManager.default.filePath(atPath: "\(boot)/boot", withLength: 96) {
            return access("\(file)/usr/standalone/firmware/FUD/Ap,TrustedExecutionMonitor.img4", F_OK) == 0
        } else {
            return (FileManager.default.filePath(atPath: "/private/preboot", withLength: 96).map {
                access("\($0)/usr/standalone/firmware/FUD/Ap,TrustedExecutionMonitor.img4", F_OK) == 0
            }) ?? false
        }
    }
}
