//
//  LCInstalledAppImportService.swift
//  LiveContainerSwiftUI
//
//  Enumerates installed App Store bundles through worse_query and keeps the
//  consumed sandbox extension alive while an app is copied/decrypted.
//

import Foundation

struct LCInstalledApp: Identifiable, Hashable {
    let bundleURL: URL
    let bundleIdentifier: String
    let displayName: String
    let version: String

    var id: String { bundleURL.path }
}

@MainActor
final class LCInstalledAppImportService {
    static let shared = LCInstalledAppImportService()

    static let installedBundleRoot = URL(
        fileURLWithPath: "/private/var/containers/Bundle/Application",
        isDirectory: true
    )

    private var access: WorseQueryAccess?

    private init() {}

    var isSupported: Bool {
        WorseQueryService.shared.isSupported
    }

    func acquireAccess() throws {
        access?.releaseAccess()
        access = try WorseQueryService.shared.acquireAccess(
            to: Self.installedBundleRoot.path
        )
    }

    func scan() throws -> [LCInstalledApp] {
        try acquireAccess()

        let fileManager = FileManager.default
        let containerURLs = try fileManager.contentsOfDirectory(
            at: Self.installedBundleRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var apps: [LCInstalledApp] = []
        for containerURL in containerURLs {
            let bundleURLs = try? fileManager.contentsOfDirectory(
                at: containerURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            for bundleURL in bundleURLs ?? [] where bundleURL.pathExtension.lowercased() == "app" {
                let infoURL = bundleURL.appendingPathComponent("Info.plist")
                guard let info = NSDictionary(contentsOf: infoURL) as? [String: Any],
                    let bundleIdentifier = info["CFBundleIdentifier"] as? String,
                    !bundleIdentifier.isEmpty
                else {
                    continue
                }

                let displayName =
                    (info["CFBundleDisplayName"] as? String)
                    ?? (info["CFBundleName"] as? String)
                    ?? bundleURL.deletingPathExtension().lastPathComponent
                let version =
                    (info["CFBundleShortVersionString"] as? String)
                    ?? (info["CFBundleVersion"] as? String)
                    ?? ""

                apps.append(
                    LCInstalledApp(
                        bundleURL: bundleURL,
                        bundleIdentifier: bundleIdentifier,
                        displayName: displayName,
                        version: version))
            }
        }

        return apps.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    func ensureAccess() throws {
        if access == nil {
            try acquireAccess()
        }
    }

    func releaseAccess() {
        access?.releaseAccess()
        access = nil
    }
}
