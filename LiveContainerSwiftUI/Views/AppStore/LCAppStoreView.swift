//
//  LCAppStoreView.swift
//  LiveContainerSwiftUI
//
//  On-device App Store search, ipatool-ios download, FairPlayed decryption, and
//  LiveContainer installation handoff.
//

import SwiftUI

@MainActor
final class LCAppStoreViewModel: ObservableObject {
    @Published var query = ""
    @Published var results: [IPAToolIOSApp] = []
    @Published var account: IPAToolIOSAccount?
    @Published var email = ""
    @Published var password = ""
    @Published var verificationCode = ""
    @Published var isSearching = false
    @Published var isSigningIn = false
    @Published var isBusy = false
    @Published var needsTwoFactor = false
    @Published var statusText = ""
    @Published var progress = 0.0
    @Published var errorMessage: String?
    @Published var signerReport: String?
    @Published var installedApps: [LCInstalledApp] = []
    @Published var isScanningInstalledApps = false
    @Published var bundleProbeIdentifier = ""
    @Published var isProbingBundleContainer = false

    private let service = IPAToolIOSService.shared
    private let installedImportService = LCInstalledAppImportService.shared

    init() {
        if let saved = try? service.savedAccount() {
            email = saved.email
        }
    }

    func search() async {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, !isSearching else {
            return
        }

        isSearching = true
        defer { isSearching = false }
        do {
            results = try await service.search(term: term)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signIn() async -> Bool {
        guard !email.isEmpty, !password.isEmpty else {
            errorMessage = "lc.appStore.login.required".loc
            return false
        }

        isSigningIn = true
        defer { isSigningIn = false }
        do {
            let code = verificationCode.isEmpty ? nil : verificationCode
            account = try await service.authenticate(email: email,
                                                     password: password,
                                                     code: code)
            needsTwoFactor = false
            verificationCode = ""
            password = ""
            return true
        } catch IPAToolIOSError.twoFactorRequired {
            needsTwoFactor = true
            verificationCode = ""
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func signOut() {
        do {
            try service.logout()
            account = nil
            password = ""
            verificationCode = ""
            needsTwoFactor = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func testNativeSigning() async {
        statusText = "lc.appStore.signer.testing".loc
        let result = await Task.detached(priority: .userInitiated) {
            LCAppStoreSigner.runProbe()
        }.value

        var lines: [String] = [result.summary]
        lines.append("")
        lines.append("AppleMediaServices: \(result.frameworkLoaded ? "loaded" : "not loadable")")
        lines.append("Classes present: \(result.presentClasses.count)/"
            + "\(result.presentClasses.count + result.missingClasses.count)")
        if !result.missingClasses.isEmpty {
            lines.append("Missing: \(result.missingClasses.joined(separator: ", "))")
        }
        lines.append("Machine-identity proof: \(result.anisetteProofProduced ? "produced" : "unavailable")")
        lines.append("Request encoder: \(result.requestEncoderAvailable ? "available" : "unavailable")")
        // FairPlay IOKit probe result
        if let svcName = result.fairPlayIOKitServiceName {
            let openStatus = result.fairPlayIOKitOpenResult == 0
                ? "open succeeded"
                : String(format: "open failed (0x%x)", UInt32(bitPattern: result.fairPlayIOKitOpenResult))
            lines.append("FairPlay IOKit (\(svcName)): \(openStatus)")
        } else {
            lines.append("FairPlay IOKit: no candidate service found")
        }
        if !result.diagnostics.isEmpty {
            lines.append("")
            lines.append(contentsOf: result.diagnostics)
        }
        statusText = ""
        signerReport = lines.joined(separator: "\n")
    }

    func probeBundleContainer() async {
        let identifier = bundleProbeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty, !isProbingBundleContainer else {
            return
        }

        isProbingBundleContainer = true
        statusText = "Probing bundle container…"
        let groupIdentifier = LCSharedUtils.appGroupID() ?? ""
        let report = await Task.detached(priority: .userInitiated) {
            worse_query_probe_bundle(identifier, groupIdentifier)
                ?? "The bundle-container probe returned no report."
        }.value
        statusText = ""
        isProbingBundleContainer = false
        signerReport = report
    }

    var installedImportSupported: Bool {
        installedImportService.isSupported
    }

    func scanInstalledApps() {
        guard !isScanningInstalledApps, !isBusy else {
            return
        }
        isScanningInstalledApps = true
        defer { isScanningInstalledApps = false }
        do {
            installedApps = try installedImportService.scan()
            if installedApps.isEmpty {
                errorMessage = "No readable installed app bundles were found."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importInstalledApp(_ app: LCInstalledApp) async {
        guard !isBusy else {
            return
        }

        isBusy = true
        progress = 0
        statusText = "Reading installed app…"

        let fileManager = FileManager.default
        let workRoot = LCPath.docPath
            .appendingPathComponent("InstalledAppImports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let safeBundleID = app.bundleIdentifier.replacingOccurrences(of: "/", with: "_")
        let outputURL = workRoot.appendingPathComponent("\(safeBundleID)-decrypted.ipa")

        do {
            try installedImportService.ensureAccess()
            try fileManager.createDirectory(at: workRoot, withIntermediateDirectories: true)
            statusText = "lc.appStore.status.decrypting".loc

            let decryptedURL = try await Task.detached(priority: .userInitiated) { [weak self] in
                try LCFairPlayPipeline.decryptInstalledApp(at: app.bundleURL,
                                                           outputURL: outputURL) { phase, completed, total in
                    let fraction = total > 0 ? Double(completed) / Double(total) : 0
                    Task { @MainActor in
                        self?.statusText = Self.localizedFairPlayPhase(phase)
                        self?.progress = min(0.95, fraction * 0.95)
                    }
                }
            }.value

            installedImportService.releaseAccess()
            progress = 1
            statusText = "lc.appStore.status.installing".loc
            withAnimation {
                DataManager.shared.model.selectedTab = .apps
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
            NotificationCenter.default.post(name: NSNotification.InstallAppNotification,
                                            object: ["url": decryptedURL])

            Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: 15 * 60 * 1_000_000_000)
                try? FileManager.default.removeItem(at: workRoot)
            }
        } catch {
            installedImportService.releaseAccess()
            let nsError = error as NSError
            let diagnostics = nsError.userInfo[LCFairPlayDiagnosticsKey] as? [String]
            if let diagnostics, !diagnostics.isEmpty {
                errorMessage = ([error.localizedDescription] + diagnostics).joined(separator: "\n")
            } else {
                errorMessage = error.localizedDescription
            }
            try? fileManager.removeItem(at: workRoot)
        }

        isBusy = false
    }

    func downloadDecryptAndInstall(_ app: IPAToolIOSApp) async {
        guard account != nil else {
            errorMessage = "lc.appStore.login.first".loc
            return
        }
        guard !isBusy else {
            return
        }

        isBusy = true
        progress = 0
        statusText = "lc.appStore.status.preparing".loc

        let fileManager = FileManager.default
        let workRoot = LCPath.docPath
            .appendingPathComponent("AppStoreDownloads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let safeBundleID = app.bundleIdentifier.replacingOccurrences(of: "/", with: "_")
        let encryptedURL = workRoot.appendingPathComponent("\(safeBundleID)-encrypted.ipa")
        let decryptedURL = workRoot.appendingPathComponent("\(safeBundleID)-decrypted.ipa")

        do {
            try fileManager.createDirectory(at: workRoot, withIntermediateDirectories: true)
            statusText = "lc.appStore.status.downloading".loc
            let download = try await service.download(app: app, to: encryptedURL) { [weak self] value in
                Task { @MainActor in
                    self?.progress = value * 0.55
                }
            }

            statusText = "lc.appStore.status.decrypting".loc
            let stagingRoots = [LCPath.lcGroupBundlePath, LCPath.bundlePath]
            let mainSinf = download.mainSinf
            let metadataPlist = download.metadataPlist

            let outputURL = try await Task.detached(priority: .userInitiated) { [weak self] in
                try LCFairPlayPipeline.decryptIPA(at: download.encryptedIPAURL,
                                                  stagingRoots: stagingRoots,
                                                  outputURL: decryptedURL,
                                                  mainSinf: mainSinf,
                                                  metadataPlist: metadataPlist) { phase, completed, total in
                    let fraction = total > 0 ? Double(completed) / Double(total) : 0
                    Task { @MainActor in
                        self?.statusText = Self.localizedFairPlayPhase(phase)
                        self?.progress = 0.55 + min(0.4, fraction * 0.4)
                    }
                }
            }.value

            try? fileManager.removeItem(at: encryptedURL)
            progress = 1
            statusText = "lc.appStore.status.installing".loc

            withAnimation {
                DataManager.shared.model.selectedTab = .apps
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
            NotificationCenter.default.post(name: NSNotification.InstallAppNotification,
                                            object: ["url": outputURL])

            // The existing installer consumes the local file asynchronously.
            // Keep it long enough for extraction, then remove the work directory.
            Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: 15 * 60 * 1_000_000_000)
                try? FileManager.default.removeItem(at: workRoot)
            }
        } catch {
            let nsError = error as NSError
            let diagnostics = nsError.userInfo[LCFairPlayDiagnosticsKey] as? [String]
            if let diagnostics, !diagnostics.isEmpty {
                errorMessage = ([error.localizedDescription] + diagnostics).joined(separator: "\n")
            } else {
                errorMessage = error.localizedDescription
            }
            try? fileManager.removeItem(at: workRoot)
        }

        isBusy = false
    }

    nonisolated private static func localizedFairPlayPhase(_ phase: String) -> String {
        switch phase {
        case "extracting":
            return "lc.appStore.status.extracting".loc
        case "decrypting":
            return "lc.appStore.status.decrypting".loc
        case "verifying":
            return "lc.appStore.status.verifying".loc
        case "archiving":
            return "lc.appStore.status.archiving".loc
        default:
            return "lc.appStore.status.decrypting".loc
        }
    }
}

struct LCAppStoreView: View {
    @StateObject private var viewModel = LCAppStoreViewModel()
    @State private var showLogin = false

    var body: some View {
        NavigationView {
            List {
                accountSection

                if viewModel.isBusy {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(viewModel.statusText)
                            ProgressView(value: viewModel.progress)
                        }
                        .padding(.vertical, 4)
                    }
                }


                Section {
                    if viewModel.isSearching {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    } else if viewModel.results.isEmpty {
                        Text("lc.appStore.search.empty".loc)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.results) { app in
                            appRow(app)
                        }
                    }
                } header: {
                    Text("lc.appStore.search.results".loc)
                }
            }
            .navigationTitle("lc.appStore.title".loc)
            .searchable(text: $viewModel.query,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "lc.appStore.search.prompt".loc)
            .onSubmit(of: .search) {
                Task { await viewModel.search() }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await viewModel.search() }
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .disabled(viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isSearching)
                }
            }
        }
        .sheet(isPresented: $showLogin) {
            LCAppStoreLoginView(viewModel: viewModel, isPresented: $showLogin)
        }
        .alert("lc.common.error".loc,
               isPresented: Binding(get: { viewModel.errorMessage != nil },
                                    set: { if !$0 { viewModel.errorMessage = nil } })) {
            Button("lc.common.ok".loc) {
                viewModel.errorMessage = nil
            }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .sheet(isPresented: Binding(get: { viewModel.signerReport != nil },
                                    set: { if !$0 { viewModel.signerReport = nil } })) {
            NavigationView {
                ScrollView {
                    Text(viewModel.signerReport ?? "")
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle("lc.appStore.signer.test".loc)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("lc.common.ok".loc) { viewModel.signerReport = nil }
                    }
                }
            }
        }
    }

    private var accountSection: some View {
        Section {
            if let account = viewModel.account {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(account.displayName)
                            .font(.headline)
                        Text(account.email)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("lc.appStore.logout".loc, role: .destructive) {
                        viewModel.signOut()
                    }
                }
            } else {
                Button {
                    showLogin = true
                } label: {
                    Label("lc.appStore.login".loc, systemImage: "person.crop.circle.badge.checkmark")
                }
            }
        } footer: {
            Text("lc.appStore.account.notice".loc)
        }
    }

    private func appRow(_ app: IPAToolIOSApp) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: app.artworkURL) { image in
                image.resizable()
            } placeholder: {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.secondary.opacity(0.2))
                    .overlay(Image(systemName: "app"))
            }
            .frame(width: 54, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 11))

            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(app.developerName ?? app.bundleIdentifier)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(app.version)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            Button("lc.appStore.download".loc) {
                Task { await viewModel.downloadDecryptAndInstall(app) }
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isBusy)
        }
        .padding(.vertical, 3)
    }
}

private struct LCAppStoreLoginView: View {
    @ObservedObject var viewModel: LCAppStoreViewModel
    @Binding var isPresented: Bool

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("lc.appStore.email".loc, text: $viewModel.email)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("lc.appStore.password".loc, text: $viewModel.password)
                        .textContentType(.password)
                    if viewModel.needsTwoFactor {
                        TextField("lc.appStore.code".loc, text: $viewModel.verificationCode)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                    }
                } footer: {
                    Text("lc.appStore.login.notice".loc)
                }
            }
            .navigationTitle("lc.appStore.login".loc)
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(viewModel.isSigningIn)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("lc.common.cancel".loc) {
                        isPresented = false
                    }
                    .disabled(viewModel.isSigningIn)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("lc.appStore.login".loc) {
                        Task {
                            if await viewModel.signIn() {
                                isPresented = false
                            }
                        }
                    }
                    .disabled(viewModel.isSigningIn)
                }
            }
            .overlay {
                if viewModel.isSigningIn {
                    ProgressView()
                }
            }
        }
    }
}
