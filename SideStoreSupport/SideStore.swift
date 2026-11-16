//
//  SideStore.swift
//  SideStoreSupport
//
//  Created by s s on 2025/7/20.
//

import AppIntents
import Foundation
import UserNotifications

@available(iOS 17.0, *)
func performIntentRefresh(identifier: String, mangledTypeName: String, intentProgress: Progress) async throws {
    intentProgress.totalUnitCount = 100
    if UserDefaults.isSideStore() {
        try await SideStoreIntentCaller.shared.callRefreshIntent(mangledTypeName: mangledTypeName)
    } else {
        RefreshHandler.shared.progress = intentProgress
        try await RefreshHandler.shared.startRefresh(identifier: identifier, mangledName: mangledTypeName)
    }
}

@available(iOS 17.0, *)
public struct RefreshAllAppsWidgetIntent: AppIntent, ProgressReportingIntent {
    public static var title: LocalizedStringResource { "Refresh Apps via Widget" }
    public static var isDiscoverable: Bool { false }  // Don't show in Shortcuts or Spotlight.

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await performIntentRefresh(identifier: "RefreshAllAppsWidgetIntent", mangledTypeName: "9SideStore26RefreshAllAppsWidgetIntentV", intentProgress: progress)
        return .result()
    }
}

@available(iOS 17.0, *)
public struct RefreshAllAppsIntent: AppIntent, CustomIntentMigratedAppIntent, PredictableIntent, ProgressReportingIntent, ForegroundContinuableIntent {
    public static let intentClassName = "RefreshAllIntent"

    public static var title: LocalizedStringResource = "Refresh All Apps"
    public static var description = IntentDescription("Refreshes your sideloaded apps to prevent them from expiring.")

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Refresh All Apps")
    }

    public static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction {
            DisplayRepresentation(
                title: "Refresh All Apps",
                subtitle: ""
            )
        }
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        try await performIntentRefresh(identifier: "RefreshAllIntent", mangledTypeName: "9SideStore20RefreshAllAppsIntentV", intentProgress: progress)
        return .result(dialog: "All apps have been refreshed.")
    }

}


class RefreshHandler: NSObject, RefreshServer {
    var c: UnsafeContinuation<(), any Error>? = nil
    var provisionC: CheckedContinuation<(Data, String), any Error>? = nil
    var launchContinuation: UnsafeContinuation<(), any Error>? = nil
    var progress: Progress? = nil
    var listener: NSXPCListener? = nil
    var sideStorePid: Int32 = 0
    var client: RefreshClient? = nil
    var ext: NSExtension? = nil

    static var shared = RefreshHandler()

    func startRefresh(identifier: String, mangledName: String) async throws {
        if sideStorePid <= 0 || getpgid(sideStorePid) <= 0, let c {
            c.resume(throwing: NSError(domain: "SideStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Built-in SideStore quit unexpectedly"]))
            self.c = nil
        }

        if c != nil {
            throw NSError(domain: "SideStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Another refresh task is in progress."])
        }

        try await ensureSideStoreLaunched()
        self.client?.refreshAllApps(withIdentifier: identifier, mangledTypeName: mangledName)

        try await withUnsafeThrowingContinuation { c in
            self.c = c
        }

    }

    /// Ensures the built-in SideStore LiveProcess is running and the XPC client
    /// is connected, launching it if necessary. Shared by refresh and headless
    /// certificate provisioning.
    func ensureSideStoreLaunched() async throws {
        if listener == nil {
            guard let listener = startAnonymousListener(self) else {
                throw NSError(domain: "SideStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to start SideStore XPC listener."])
            }
            self.listener = listener
        }
        guard let listener = self.listener else {
            throw NSError(domain: "SideStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "SideStore XPC listener unavailable."])
        }

        // launch SideStore if it's not running
        if (sideStorePid <= 0 || getpgid(sideStorePid) <= 0) && launchContinuation == nil {
            let lcHome = String(cString: getenv("LC_HOME_PATH"))
            let sideStoreHomeURL = URL(fileURLWithPath: lcHome).appendingPathComponent("Documents/SideStore")
            // The home container may not exist yet (e.g. provisioning right after
            // first sign-in, before SideStore has ever launched). Create it so the
            // security-scoped bookmark can be formed instead of force-unwrapping nil.
            try? FileManager.default.createDirectory(at: sideStoreHomeURL, withIntermediateDirectories: true)
            guard let bookmarkData = bookmarkForURL(sideStoreHomeURL) else {
                throw NSError(domain: "SideStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Couldn't access the built-in SideStore container. Make sure LiveContainer was installed with the built-in SideStore."])
            }

            // start LiveProcess
            let extensionItem = NSExtensionItem()
            extensionItem.userInfo = [
                "selected": "builtinSideStore",
                "bookmarks": [bookmarkData],
                "endpoint": listener.endpoint,
            ]

            guard let liveProcessURL = UserDefaults.lcMainBundle().builtInPlugInsURL?.appendingPathComponent("LiveProcess.appex"),
                let liveProcessBundle = Bundle(url: liveProcessURL)
            else {
                NSLog("Unable to locate LiveProcess bundle")
                throw NSError(domain: "SideStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to locate LiveProcess bundle. To use the Refresh All Apps shortcut, reinstall LiveContainer+SideStore with LiveProcess installed. If you use SideStore, choose \"Keep App Extensions (Use Main Profile)\". If you use PlumeImpactor, choose \"Only Register Main Bundle\". For other sideloaders, select keep all extensions, i.e. DO NOT Remove any extension."])
            }

            var ext: NSExtension?
            do {
                ext = try NSExtension(identifier: liveProcessBundle.bundleIdentifier)
            } catch {
                NSLog("Failed to start extension \(error)")
                throw NSError(domain: "SideStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to start extension \(error). To use the Refresh All Apps shortcut, reinstall LiveContainer+SideStore with LiveProcess installed. If you use SideStore, choose \"Keep App Extensions (Use Main Profile)\". If you use Impactor, choose \"Only Register Main Bundle\". For other sideloaders, select keep all extensions, i.e. DO NOT Remove any extension."])
            }
            guard let ext else {
                throw NSError(domain: "SideStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to start SideStore extension."])
            }
            self.ext = ext

            ext.setRequestInterruptionBlock { uuid in
                let quitError = NSError(domain: "SideStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Built-in SideStore quit unexpectedly"])
                self.c?.resume(throwing: quitError)
                self.c = nil
                self.provisionC?.resume(throwing: quitError)
                self.provisionC = nil
                self.sideStorePid = 0
                self.launchContinuation = nil
            }

            let uuid = await ext.beginRequest(withInputItems: [extensionItem])
            sideStorePid = ext.pid(forRequestIdentifier: uuid)

            try await withUnsafeThrowingContinuation { c in
                self.launchContinuation = c
                DispatchQueue.main.asyncAfter(deadline: .now() + 300) {
                    if let c = self.launchContinuation {
                        c.resume(throwing: NSError(domain: "SideStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Built-in SideStore failed to start in reasonable time"]))
                        self.launchContinuation = nil
                        ext._kill(9)
                    }
                }
            }
        }
    }

    /// Runs SideStore's sign-in + certificate provisioning headlessly in the
    /// built-in SideStore, feeding it the given credentials and the machine
    /// anisette snapshot produced by LiveContainer's App Store login stack.
    /// Returns the signing certificate (PKCS#12) and its password.
    func startProvision(appleID: String, password: String, code: String?, anisette: [String: String]) async throws -> (Data, String) {
        if provisionC != nil {
            throw NSError(domain: "SideStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Another certificate provisioning task is in progress."])
        }
        try await ensureSideStoreLaunched()
        guard let client = self.client else {
            throw NSError(domain: "SideStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "SideStore client is unavailable."])
        }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, String), any Error>) in
            self.provisionC = cont
            client.provisionCertificate(withAppleID: appleID, password: password, code: code, anisette: anisette) { certificate, certPassword, error in
                guard let cont = self.provisionC else { return }
                self.provisionC = nil
                if let error {
                    cont.resume(throwing: NSError(domain: "SideStore", code: 1, userInfo: [NSLocalizedDescriptionKey: error]))
                } else if let certificate {
                    cont.resume(returning: (certificate, certPassword ?? ""))
                } else {
                    cont.resume(throwing: NSError(domain: "SideStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "SideStore returned no certificate."]))
                }
            }
        }
    }

    func updateProgress(_ value: Double) {
        progress?.completedUnitCount = Int64(value * 100)
    }

    func finish(_ error: String?) {
        if let error {
            c?.resume(throwing: NSError(domain: "SideStore", code: 1, userInfo: [NSLocalizedDescriptionKey: error]))
            c = nil
        } else {
            c?.resume()
            c = nil
        }
    }

    func onConnection(_ connection: NSXPCConnection) {
        connection.remoteObjectInterface = RefreshClientInterface()
        client = connection.remoteObjectProxy as? RefreshClient
    }

    func finishedLaunching() {
        launchContinuation?.resume()
        launchContinuation = nil
    }

    func add(_ request: UNNotificationRequest) {
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("Failed to add SideStore notification: \(error)")
            }
        }
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }

}
