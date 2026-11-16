//
//  LCUtilsExtensions.swift
//  LiveContainer
//
//  Created by s s on 2026/3/20.
//

import LocalAuthentication

extension LCUtils {
    public static let appGroupUserDefault = UserDefaults.init(suiteName: LCSharedUtils.appGroupID()) ?? UserDefaults.standard

    public static func signTweaks(tweakFolderUrl: URL, force: Bool = false, recursive: Bool = true, progressHandler: ((Progress) -> Void)? = nil) async throws {
        guard LCSharedUtils.certificatePassword() != nil else {
            return
        }
        let fm = FileManager.default
        // a disabled folder is renamed to .disabled; skip it, it gets signed again once re-enabled
        if !fm.fileExists(atPath: tweakFolderUrl.path) {
            let disabledUrl = tweakFolderUrl.deletingLastPathComponent().appendingPathComponent(tweakFolderUrl.lastPathComponent + ".disabled")
            if fm.fileExists(atPath: disabledUrl.path) {
                return
            }
        }
        var isFolder: ObjCBool = false
        if fm.fileExists(atPath: tweakFolderUrl.path, isDirectory: &isFolder) && !isFolder.boolValue {
            return
        }

        // check if re-sign is needed
        // if signature is invalid, we need to re-sign. dylib and framework's main binary are supported.
        // TweakLoader loads an app's tweak folder recursively, so subfolders must be signed too;
        // the global tweak root is only loaded top-level (its subfolders are per-app folders).
        var filesToSign: [URL] = []

        func collect(_ folderUrl: URL, recurse: Bool) throws {
            let fileURLs = try fm.contentsOfDirectory(at: folderUrl, includingPropertiesForKeys: nil)
            for fileURL in fileURLs {
                var fileURL = fileURL
                let attributes = try fm.attributesOfItem(atPath: fileURL.path)
                let fileType = attributes[.type] as? FileAttributeType
                if fileType != FileAttributeType.typeDirectory && fileType != FileAttributeType.typeRegular {
                    continue
                }
                let name = fileURL.lastPathComponent
                let baseName = name.hasSuffix(".disabled") ? String(name.dropLast(".disabled".count)) : name
                if fileType == FileAttributeType.typeDirectory {
                    if !baseName.hasSuffix(".framework") {
                        if recurse && !name.hasSuffix(".disabled") {
                            try collect(fileURL, recurse: true)
                        }
                        continue
                    }
                    guard let frameworkBundle = Bundle(url: fileURL), let executableURL = frameworkBundle.executableURL else {
                        continue
                    }
                    fileURL = executableURL
                } else if fileType == FileAttributeType.typeRegular && !baseName.hasSuffix(".dylib") {
                    continue
                }

                if !force, checkCodeSignature((fileURL.path as NSString).utf8String) {
                    continue
                }

                filesToSign.append(fileURL)
            }
        }
        try collect(tweakFolderUrl, recurse: recursive)

        if filesToSign.isEmpty {
            return
        }

        for fileURL in filesToSign {
            LCPatchMachOFixupARM64eSlice((fileURL.path as NSString).fileSystemRepresentation)
        }

        try await withUnsafeThrowingContinuation({ c in
            let progress = signFilesWithZSign(with: filesToSign) { success, error in
                if success {
                    c.resume()
                    return
                }

                guard let error else {
                    c.resume()
                    return
                }
                c.resume(throwing: error)
            }
            if let progress {
                progressHandler?(progress)
            }
        })
    }

    /// Name of the folder inside a guest app bundle that holds its embedded, team-signed tweaks.
    public static let embeddedTweaksFolderName = "LCTweaks"

    /// Copies the global tweaks (top level) and the app's tweak folder (recursive) into
    /// `<bundle>/LCTweaks/{global,app}` and signs every copied Mach-O with the team certificate.
    /// The copies sit next to the guest executable, which already passes library validation,
    /// so TweakLoader can dlopen them in JIT-less mode (incl. LiveProcess). Skips work when
    /// nothing changed since the last embed (manifest of source path/size/mtime).
    public static func embedTweaks(intoBundle bundleUrl: URL, globalTweakFolder: URL, appTweakFolder: URL?, force: Bool = false, progressHandler: ((Progress) -> Void)? = nil) async throws {
        let fm = FileManager.default
        let destRoot = bundleUrl.appendingPathComponent(embeddedTweaksFolderName)
        let manifestUrl = destRoot.appendingPathComponent(".lcmanifest")

        // (source, path relative to destRoot)
        var entries: [(src: URL, rel: String)] = []

        func tweakKind(_ url: URL) -> (isTweak: Bool, isDir: Bool) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return (false, false) }
            let name = url.lastPathComponent
            if name.hasSuffix(".disabled") || name.hasPrefix(".") { return (false, isDir.boolValue) }
            if isDir.boolValue { return (name.hasSuffix(".framework"), true) }
            return (name.hasSuffix(".dylib") && name != "TweakLoader.dylib", false)
        }

        func collect(_ folder: URL, relPrefix: String, recurse: Bool) {
            guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
            for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let kind = tweakKind(item)
                let rel = relPrefix + "/" + item.lastPathComponent
                if kind.isTweak {
                    entries.append((item, rel))
                } else if kind.isDir && recurse && !item.lastPathComponent.hasSuffix(".disabled") {
                    collect(item, relPrefix: rel, recurse: true)
                }
            }
        }

        collect(globalTweakFolder, relPrefix: "global", recurse: false)
        if let appTweakFolder {
            collect(appTweakFolder, relPrefix: "app", recurse: true)
        }

        func machOPath(_ url: URL) -> URL? {
            if url.pathExtension == "framework" {
                return Bundle(url: url)?.executableURL
            }
            return url
        }

        // Fingerprint sources so unchanged tweaks aren't re-copied/re-signed on every launch.
        var manifestLines: [String] = [LCSharedUtils.certificatePassword() != nil ? "signed" : "unsigned"]
        for entry in entries {
            let target = machOPath(entry.src) ?? entry.src
            let attrs = try? fm.attributesOfItem(atPath: target.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            manifestLines.append("\(entry.rel)|\(size)|\(mtime)")
        }
        let manifest = manifestLines.joined(separator: "\n")

        if entries.isEmpty {
            try? fm.removeItem(at: destRoot)
            return
        }
        if !force, fm.fileExists(atPath: destRoot.path),
            let old = try? String(contentsOf: manifestUrl, encoding: .utf8), old == manifest
        {
            return
        }

        try? fm.removeItem(at: destRoot)
        try fm.createDirectory(at: destRoot, withIntermediateDirectories: true)

        // Copies get fresh inodes, so the kernel never sees a stale cached signature for them.
        var filesToSign: [URL] = []
        for entry in entries {
            let dst = destRoot.appendingPathComponent(entry.rel)
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: entry.src, to: dst)
            if let macho = machOPath(dst) {
                LCPatchMachOFixupARM64eSlice((macho.path as NSString).fileSystemRepresentation)
                filesToSign.append(macho)
            }
        }

        if LCSharedUtils.certificatePassword() != nil && !filesToSign.isEmpty {
            try await withUnsafeThrowingContinuation({ (c: UnsafeContinuation<Void, Error>) in
                let progress = signFilesWithZSign(with: filesToSign) { success, error in
                    if success {
                        c.resume()
                    } else if let error {
                        c.resume(throwing: error)
                    } else {
                        c.resume()
                    }
                }
                if let progress {
                    progressHandler?(progress)
                }
            })
            // Fail loudly here instead of at dlopen time inside the guest.
            for file in filesToSign where !checkCodeSignature((file.path as NSString).utf8String) {
                try? fm.removeItem(at: manifestUrl)
                throw "Tweak \(file.lastPathComponent) is still not accepted by iOS after signing with the team certificate. Make sure the imported certificate is the one LiveContainer itself is signed with."
            }
        }

        try manifest.write(to: manifestUrl, atomically: true, encoding: .utf8)
    }

    private static func authenticateUser(completion: @escaping (Bool, Error?) -> Void) {
        // Create a context for authentication
        let context = LAContext()
        var error: NSError?

        // Check if the device supports biometric authentication
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            // Determine the reason for the authentication request
            let reason = "lc.utils.requireAuthentication".loc

            // Evaluate the authentication policy
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, evaluationError in
                DispatchQueue.main.async {
                    if success {
                        // Authentication successful
                        completion(true, nil)
                    } else {
                        if let evaluationError = evaluationError as? LAError, evaluationError.code == LAError.userCancel || evaluationError.code == LAError.appCancel {
                            completion(false, nil)
                        } else {
                            // Authentication failed
                            completion(false, evaluationError)
                        }

                    }
                }
            }
        } else {
            // Biometric authentication is not available
            DispatchQueue.main.async {
                if let evaluationError = error as? LAError, evaluationError.code == LAError.passcodeNotSet {
                    // No passcode set, we also define this as successful Authentication
                    completion(true, nil)
                } else {
                    completion(false, error)
                }

            }
        }
    }

    public static func authenticateUser() async throws -> Bool {
        if DataManager.shared.model.isHiddenAppUnlocked {
            return true
        }

        var success = false
        var error: Error? = nil
        await withUnsafeContinuation { c in
            LCUtils.authenticateUser { success1, error1 in
                success = success1
                error = error1
                c.resume()
            }
        }
        if let error = error {
            throw error
        }
        if !success {
            return false
        }
        DispatchQueue.main.async {
            DataManager.shared.model.isHiddenAppUnlocked = true
        }
        return true
    }

    public static func getStoreName() -> String {
        switch LCUtils.store() {
        case .AltStore:
            return "AltStore"
        case .SideStore:
            return "SideStore"
        case .ADP:
            return "ADP"
        default:
            return "Unknown Store"
        }
    }

    public static func removeAppKeychain(dataUUID label: String) {
        [kSecClassGenericPassword, kSecClassInternetPassword, kSecClassCertificate, kSecClassKey, kSecClassIdentity].forEach {
            let status = SecItemDelete(
                [
                    kSecClass as String: $0,
                    "alis": label,
                ] as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                //Error while removing class $0
                NSLog("[LC] Failed to find keychain items: \(status)")
            }
        }
    }

    public static func forEachInstalledLC(isFree: Bool, block: (String, inout Bool) -> Void) {
        for scheme in LCSharedUtils.lcUrlSchemes() {
            if scheme == UserDefaults.lcAppUrlScheme() {
                continue
            }

            // Check if the app is installed
            guard let url = URL(string: "\(scheme)://"),
                UIApplication.shared.canOpenURL(url)
            else {
                continue
            }

            // Check shared utility logic
            if isFree && LCSharedUtils.isLCScheme(inUse: scheme) {
                continue
            }

            var shouldBreak = false
            block(scheme, &shouldBreak)

            if shouldBreak {
                break
            }
        }
    }

    public static func askForJIT(withScript script: String? = nil, appName: String? = nil, classicMode: UInt = 0, onServerMessage: ((String) -> Void)? = nil) async -> Bool {
        // if LiveContainer is installed by TrollStore
        let tsPath = "\(Bundle.main.bundlePath)/../_TrollStore"
        if access((tsPath as NSString).utf8String, 0) == 0 {
            LCSharedUtils.launchToGuestApp(withClassicMode: classicMode)
            return true
        }

        guard let groupUserDefaults = UserDefaults(suiteName: LCSharedUtils.appGroupID()),
            let jitEnabler = JITEnablerType(rawValue: groupUserDefaults.integer(forKey: "LCJITEnablerType"))
        else {
            return false
        }

        if jitEnabler == .SideJITServer {
            guard
                let sideJITServerAddress = groupUserDefaults.string(forKey: "LCSideJITServerAddress"),
                let deviceUDID = groupUserDefaults.string(forKey: "LCDeviceUDID"),
                !sideJITServerAddress.isEmpty && !deviceUDID.isEmpty
            else {
                return false
            }

            onServerMessage?("Please make sure the VPN is connected if the server is not in your local network.")

            do {
                let launchJITUrlStr = "\(sideJITServerAddress)/\(deviceUDID)/\(Bundle.main.bundleIdentifier ?? "")"
                guard let launchJITUrl = URL(string: launchJITUrlStr) else { return false }
                let session = URLSession.shared

                onServerMessage?("Contacting SideJITServer at \(sideJITServerAddress)...")
                let request = URLRequest(url: launchJITUrl)
                let (data, _) = try await session.data(for: request)
                onServerMessage?(String(decoding: data, as: UTF8.self))

            } catch {
                onServerMessage?("Failed to contact SideJITServer: \(error)")
            }

            return false
        } else if jitEnabler == .JITStreamerEBLegacy {
            var JITStresmerEBAddress = groupUserDefaults.string(forKey: "LCSideJITServerAddress") ?? ""
            if JITStresmerEBAddress.isEmpty {
                JITStresmerEBAddress = "http://[fd00::]:9172"
            }

            onServerMessage?("Please make sure the VPN is connected if the server is not in your local network.")

            do {

                onServerMessage?("Contacting JitStreamer-EB server at \(JITStresmerEBAddress)...")

                let session = URLSession.shared
                let decoder = JSONDecoder()

                let mountStatusUrlStr = "\(JITStresmerEBAddress)/mount"
                guard let mountStatusUrl = URL(string: mountStatusUrlStr) else { return false }
                let mountRequest = URLRequest(url: mountStatusUrl)

                // check mount status
                onServerMessage?("Checking mount status...")
                let (mountData, _) = try await session.data(for: mountRequest)
                let mountResponseObj = try decoder.decode(JITStreamerEBMountResponse.self, from: mountData)
                guard mountResponseObj.ok else {
                    onServerMessage?(mountResponseObj.error ?? "Mounting failed with unknown error.")
                    return false
                }
                if mountResponseObj.mounting {
                    onServerMessage?("Your device is currently mounting the developer disk image. Leave your device on and connected. Once this finishes, you can run JitStreamer again.")
                    onServerMessage?("Check \(JITStresmerEBAddress)/mount_status for mounting status.")
                    if let mountStatusUrl = URL(string: "\(JITStresmerEBAddress)/mount_status") {
                        await UIApplication.shared.open(mountStatusUrl)
                    }
                    return false
                }

                // open safari to use /launch_app api
                if let mountStatusUrl = URL(string: "\(JITStresmerEBAddress)/launch_app/\(Bundle.main.bundleIdentifier!)") {
                    onServerMessage?("JIT acquisition will continue in the default browser.")
                    await UIApplication.shared.open(mountStatusUrl)
                }
                return false


            } catch {
                onServerMessage?("Failed to contact JitStreamer-EB server: \(error)")
            }
        } else if jitEnabler == .StosDebug || jitEnabler == .StosDebugLC {
            guard let appName else {
                onServerMessage?("Unable to get App Name, Please try again.")
                return false
            }
            var launchURLStr = "stosdebug://enableJIT?bundleId=\(Bundle.main.bundleIdentifier!)&appName=\(appName)"

            if let script = script, !script.isEmpty {
                launchURLStr += "&script=\(script)"
            }

            if jitEnabler == .StosDebugLC {
                let encodedStr = Data(launchURLStr.utf8).base64EncodedString()


                var appToLaunch: LCAppModel? = nil
                // find an app that can respond to stikjit://
                appLoop: for app in DataManager.shared.model.apps {
                    if let schemes = app.appInfo.urlSchemes() {
                        for scheme in schemes {
                            if let scheme = scheme as? String, scheme == "stosdebug" {
                                appToLaunch = app
                                break appLoop
                            }
                        }
                    }
                }
                guard let appToLaunch else {
                    onServerMessage?("StosDebug is not installed in LiveContainer.")
                    return false
                }

                if !appToLaunch.uiIsShared {
                    onServerMessage?("StosDebug is installed in LiveContainer, but is not a shared app. Convert it to a shared app to continue.")
                    return false
                }
                // check if stosdebug is already running
                var freeScheme = LCSharedUtils.getContainerUsingLCScheme(withFolderName: appToLaunch.uiDefaultDataFolder)

                if freeScheme == nil {
                    // if not, try to find a free lc
                    forEachInstalledLC(isFree: true) { scheme, shouldBreak in
                        freeScheme = scheme
                        shouldBreak = true
                    }
                }
                guard let freeScheme else {
                    onServerMessage?("No free LiveContainer is available. Please either: \n(1)close one, \n(2)install a new one, \n(3)choose another method to enable JIT.")
                    return false
                }

                let launchURL = URL(string: "\(freeScheme)://open-url?url=\(encodedStr)")!
                LCUtils.appGroupUserDefault.set(freeScheme, forKey: "LCLaunchExtensionScheme")
                LCUtils.appGroupUserDefault.set(appToLaunch.appInfo.relativeBundlePath, forKey: "LCLaunchExtensionBundleID")
                LCUtils.appGroupUserDefault.set(Date.now, forKey: "LCLaunchExtensionLaunchDate")
                onServerMessage?("JIT acquisition will continue in another LiveContainer.")

                await UIApplication.shared.open(launchURL)
            } else {
                onServerMessage?("JIT acquisition will continue in StosDebug.")

                await UIApplication.shared.open(URL(string: launchURLStr)!)
            }

        } else if jitEnabler == .StikJIT || jitEnabler == .StikJITLC {
            var launchURLStr = "stikjit://enable-jit?bundle-id=\(Bundle.main.bundleIdentifier!)"

            if let script = script, !script.isEmpty {
                launchURLStr += "&script-data=\(script)"
            }
            let launchURL: URL
            if jitEnabler == .StikJITLC {
                let encodedStr = Data(launchURLStr.utf8).base64EncodedString()


                var appToLaunch: LCAppModel? = nil
                // find an app that can respond to stikjit://
                appLoop: for app in DataManager.shared.model.apps {
                    if let schemes = app.appInfo.urlSchemes() {
                        for scheme in schemes {
                            if let scheme = scheme as? String, scheme == "stikjit" {
                                appToLaunch = app
                                break appLoop
                            }
                        }
                    }
                }
                guard let appToLaunch else {
                    onServerMessage?("StikDebug is not installed in LiveContainer.")
                    return false
                }

                if !appToLaunch.uiIsShared {
                    onServerMessage?("StikDebug is installed in LiveContainer, but is not a shared app. Convert it to a shared app to continue.")
                    return false
                }
                // check if stikdebug is already running
                var freeScheme = LCSharedUtils.getContainerUsingLCScheme(withFolderName: appToLaunch.uiDefaultDataFolder)

                if freeScheme == nil {
                    // if not, try to find a free lc
                    forEachInstalledLC(isFree: true) { scheme, shouldBreak in
                        freeScheme = scheme
                        shouldBreak = true
                    }
                }
                guard let freeScheme else {
                    onServerMessage?("No free LiveContainer is available. Please either: \n(1)close one, \n(2)install a new one, \n(3)choose another method to enable JIT.")
                    return false
                }

                launchURL = URL(string: "\(freeScheme)://open-url?url=\(encodedStr)")!
                LCUtils.appGroupUserDefault.set(freeScheme, forKey: "LCLaunchExtensionScheme")
                LCUtils.appGroupUserDefault.set(appToLaunch.appInfo.relativeBundlePath, forKey: "LCLaunchExtensionBundleID")
                LCUtils.appGroupUserDefault.set(Date.now, forKey: "LCLaunchExtensionLaunchDate")
                onServerMessage?("JIT acquisition will continue in another LiveContainer.")

            } else {
                launchURL = URL(string: launchURLStr)!
                onServerMessage?("JIT acquisition will continue in StikDebug.")
            }
            await UIApplication.shared.open(launchURL)
        } else if jitEnabler == .SideStore {
            onServerMessage?("JIT acquisition will continue in SideStore.")
            let launchURL = URL(string: "sidestore://enable-jit?bundle-id=\(Bundle.main.bundleIdentifier!)")!
            await UIApplication.shared.open(launchURL)
        }
        return false
    }

    static func moveFilesAtomicallyAfterPreflight(_ moves: [(URL, URL)]) throws {
        let fileManager = FileManager.default

        var seenSources = Set<URL>()
        var seenDestinations = Set<URL>()

        let normalizedMoves = moves.map { source, destination in
            (
                source.standardizedFileURL,
                destination.standardizedFileURL
            )
        }

        // MARK: - Preflight

        for (source, destination) in normalizedMoves {
            guard !source.path.isEmpty else {
                throw BatchMoveError.emptySource(source)
            }

            guard source != destination else {
                throw BatchMoveError.sourceEqualsDestination(source)
            }

            guard seenSources.insert(source).inserted else {
                throw BatchMoveError.duplicateSource(source)
            }

            guard fileManager.isWritableFile(atPath: source.deletingLastPathComponent().path) else {
                throw BatchMoveError.sourceParentIsNotWritable(source.deletingLastPathComponent())
            }

            guard seenDestinations.insert(destination).inserted else {
                throw BatchMoveError.duplicateDestination(destination)
            }

            var isDirectory: ObjCBool = false

            guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
                throw BatchMoveError.sourceDoesNotExist(source)
            }

            do {
                _ = try source.checkResourceIsReachable()
            } catch {
                throw BatchMoveError.sourceIsNotReachable(source, underlying: error)
            }

            guard !fileManager.fileExists(atPath: destination.path) else {
                throw BatchMoveError.destinationAlreadyExists(destination)
            }

            let parent = destination.deletingLastPathComponent()

            var parentIsDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory) else {
                throw BatchMoveError.destinationParentDoesNotExist(parent)
            }

            guard parentIsDirectory.boolValue else {
                throw BatchMoveError.destinationParentIsNotDirectory(parent)
            }

            guard fileManager.isWritableFile(atPath: parent.path) else {
                throw BatchMoveError.destinationParentIsNotWritable(parent)
            }

            if isDirectory.boolValue {
                let sourcePath = source.path.hasSuffix("/") ? source.path : source.path + "/"
                let destinationPath = destination.path.hasSuffix("/") ? destination.path : destination.path + "/"

                if destinationPath.hasPrefix(sourcePath) {
                    throw BatchMoveError.moveWouldPlaceDirectoryInsideItself(
                        source: source,
                        destination: destination
                    )
                }
            }
        }

        // MARK: - Execute only after all preflight checks pass

        for (source, destination) in normalizedMoves {
            do {
                try fileManager.moveItem(at: source, to: destination)
            } catch {
                throw BatchMoveError.moveFailed(
                    source: source,
                    destination: destination,
                    underlying: error
                )
            }
        }
    }

    static func openSideStore(delegate: LCAppModelDelegate? = nil, urlStr: String? = nil) {
        let sideStoreApp = LCAppModel(appInfo: BuiltInSideStoreAppInfo.shared, delegate: delegate)

        Task {
            do {
                try await sideStoreApp.runApp(bundleIdOverride: "builtinSideStore", urlStr: urlStr)
            } catch {
                NSLog("[LC] Failed to open built-in SideStore: \(error)")
            }
        }
    }
}
