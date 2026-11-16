//
//  StoreClient.swift
//  AppStoreCore — ported from WaffleStore (MuffinStoreJailed/Functions/IPATool.swift).
//
//  The working native App Store auth + download stack: a SAP-signed RP/SP
//  login against the bag's /auth/v1/native endpoint using CoreADI anisette,
//  then ent/download with a kbsync from the emulated StoreAgent. Replaces
//  LiveContainer's retired Configurator/MZFinance login.
//
//  Copyright (c) 2021 Majd Alfhaily. MIT (see AppStoreAuth/SAPKit LICENSE.ipatool).
//

import Foundation
import CommonCrypto
import SAPKit

// MARK: - Small helpers

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

enum SHA1 {
    static func hash(_ data: Data) -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA1($0.baseAddress, CC_LONG(data.count), &digest) }
        return Data(digest)
    }
}

struct StoreError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private extension String {
    subscript(_ range: Range<Int>) -> Substring {
        let lo = index(startIndex, offsetBy: range.lowerBound)
        let hi = index(startIndex, offsetBy: range.upperBound)
        return self[lo..<hi]
    }
}

// MARK: - Public facade

public enum AppStoreClientError: Error, Sendable {
    case twoFactorRequired
    case invalidCredentials
    case notAuthenticated
    case licenseRequired
    case message(String)
}

public struct StoreLoginResult: Sendable {
    public let directoryServicesIdentifier: String
    public let storeFront: String
    public let token: String
    public let accountName: String
}

/// Thread-safe wrapper over the stateful `StoreClient` (login state must
/// persist between `logIn` and the download calls on the same instance).
public final class AppStoreClient: @unchecked Sendable {
    private let client: StoreClient

    public init(appleId: String, password: String) {
        client = StoreClient(appleId: appleId, password: password)
    }

    /// Device GUID derived from the Apple ID (six bytes, hex).
    public var guid: String { client.ensureGuid() }

    /// Sign in. Pass the six-digit code on the retry after `twoFactorRequired`.
    public func logIn(code: String?) async throws -> StoreLoginResult {
        try await client.login(code: code)
    }

    /// ent/download song info for a specific external version ("" = latest).
    /// Returns the first songList entry (URL, md5, sinfs, metadata).
    public func downloadInfo(appId: String, appVerId: String) async throws -> [String: Any] {
        try await client.downloadInfo(appId: appId, appVerId: appVerId)
    }

    /// Available external version identifiers, newest Store catalog first.
    public func versionIDs(appId: String) async throws -> [String] {
        let info = try await client.downloadInfo(appId: appId, appVerId: "")
        let metadata = info["metadata"] as? [String: Any] ?? [:]
        let ids = metadata["softwareVersionExternalIdentifiers"] as? [Int] ?? []
        return ids.map(String.init)
    }
}

// MARK: - Wire constants / models

private enum StoreConstants {
    static let userAgent = "Configurator/2.21 (Macintosh; OS X 27.0.1; 26A434) AppleWebKit/0625.2.5.11.6"
    static let nativeAuthHost = "auth.itunes.apple.com"
    static let nativeAuthPaths: Set<String> = ["/auth/v1/native", "/auth/v1/native/", "/auth/v1/native/fast", "/auth/v1/native/fast/"]
    static let legacyAuthPath = "/WebObjects/MZFinance.woa/wa/authenticate"
    static let badLoginMessage = "MZFinance.BadLogin.Configurator_message"
    static let invalidCredentials = "-5000"
    static let maxRedirects = 4
}

private struct StoreBag {
    let endpoint: URL
    let sapSetup: URL
    let sapCertificate: URL
    let sapVersion: UInt32
}

private struct StoreResponse {
    var status: Int
    var headers: [String: String]
    var plist: [String: Any]
    var url: URL

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var machineAction: (action: String, data: String)? {
        guard let action = header("X-Apple-AMD-Action")?.trimmingCharacters(in: .whitespaces), !action.isEmpty else { return nil }
        return (action, header("X-Apple-AMD-Data")?.trimmingCharacters(in: .whitespaces) ?? "")
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// MARK: - StoreClient

final class StoreClient: @unchecked Sendable {
    private let session: URLSession
    private let appleId: String
    private let basePassword: String
    private var password: String
    private var guid: String?
    private var accountName: String?
    private var authHeaders: [String: String]?
    private var authCookies: [HTTPCookie]?
    private var clearCookiesBeforeLogin = false
    private var loginTrace: [String] = []
    private var pod: String?

    init(appleId: String, password: String) {
        session = URLSession(configuration: .default, delegate: NoRedirectDelegate(), delegateQueue: nil)
        self.appleId = appleId
        self.basePassword = password
        self.password = password
    }

    func ensureGuid() -> String {
        if guid == nil { guid = generateGuid(appleId: appleId) }
        return guid!
    }

    private func generateGuid(appleId: String) -> String {
        let DEFAULT_GUID = "000C2941396B"
        let GUID_DEFAULT_PREFIX = 2
        let GUID_SEED = "CAFEBABE"
        let GUID_POS = 10
        let h = SHA1.hash((GUID_SEED + appleId + GUID_SEED).data(using: .utf8)!).hexString
        let defaultPart = DEFAULT_GUID.prefix(GUID_DEFAULT_PREFIX)
        let hashPart = h[GUID_POS..<GUID_POS + (DEFAULT_GUID.count - GUID_DEFAULT_PREFIX)]
        return (defaultPart + hashPart).uppercased()
    }

    // MARK: Bag

    private func getBag() async throws -> StoreBag {
        let guid = ensureGuid()
        var request = URLRequest(url: URL(string: "https://init.itunes.apple.com/bag.xml?ix=6&guid=\(guid)")!)
        request.httpMethod = "GET"
        request.setValue("application/xml", forHTTPHeaderField: "Accept")
        request.setValue(StoreConstants.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let xmlString = String(data: data, encoding: .utf8),
              let plistStart = xmlString.range(of: "<plist"),
              let plistEnd = xmlString.range(of: "</plist>"),
              let cleanData = String(xmlString[plistStart.lowerBound..<plistEnd.upperBound]).data(using: .utf8),
              let plist = try PropertyListSerialization.propertyList(from: cleanData, options: [], format: nil) as? [String: Any] else {
            throw StoreError("Apple's Store bag is unavailable")
        }
        let values = plist["urlBag"] as? [String: Any] ?? plist
        guard let advertised = values["authenticateAccount"] as? String,
              let endpoint = Self.normalizeAuthEndpoint(advertised),
              let setupString = values["sign-sap-setup"] as? String,
              let certificateString = values["sign-sap-setup-cert"] as? String,
              let setup = URL(string: setupString), let certificate = URL(string: certificateString),
              let versionString = values["sign-sap-version"] as? String,
              let version = UInt32(versionString) else {
            throw StoreError("Apple's Store bag is missing a supported authentication or SAP endpoint")
        }
        return StoreBag(endpoint: endpoint, sapSetup: setup, sapCertificate: certificate, sapVersion: version)
    }

    private static func normalizeAuthEndpoint(_ endpoint: String) -> URL? {
        guard var components = URLComponents(string: endpoint), components.scheme == "https",
              let host = components.host?.lowercased() else { return nil }
        if host == StoreConstants.nativeAuthHost {
            return StoreConstants.nativeAuthPaths.contains(components.path) ? components.url : nil
        }
        if host == "buy.itunes.apple.com" || host.hasSuffix("-buy.itunes.apple.com") {
            components.path = StoreConstants.legacyAuthPath + "/"
            return components.url
        }
        return nil
    }

    private static func resolveRedirect(from base: URL, location: String) -> URL? {
        guard let target = URL(string: location.trimmingCharacters(in: .whitespaces), relativeTo: base)?.absoluteURL,
              let host = target.host?.lowercased(), target.scheme == "https" else { return nil }
        if host == StoreConstants.nativeAuthHost {
            return StoreConstants.nativeAuthPaths.contains(target.path) ? target : nil
        }
        if host == "buy.itunes.apple.com" || host.hasSuffix("-buy.itunes.apple.com") {
            let path = target.path
            return path == StoreConstants.legacyAuthPath || path == StoreConstants.legacyAuthPath + "/" ? target : nil
        }
        return nil
    }

    // MARK: Login

    private func loginBody(attempt: Int) throws -> Data {
        let body: [String: Any] = [
            "appleId": appleId,
            "attempt": String(attempt),
            "guid": guid!,
            "password": password.replacingOccurrences(of: " ", with: ""),
            "rmp": "0",
            "why": "signIn",
            "createSession": true,
            "credentialSource": 0,
            "deviceOffersCheck": true,
            "isSilentAuthentication": false,
            "passwordSettings": ["free": "always", "paid": "always"]
        ]
        return try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
    }

    private func send(_ request: URLRequest) async throws -> StoreResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw StoreError("invalid response") }
        var headers = [String: String]()
        for (key, value) in http.allHeaderFields {
            headers[String(describing: key)] = String(describing: value)
        }
        let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]) ?? [:]
        return StoreResponse(status: http.statusCode, headers: headers, plist: plist, url: request.url!)
    }

    private func sendLogin(endpoint: URL, headers: [String: String], signer: StoreSAPSigner) async throws -> StoreResponse {
        var url = endpoint
        var attempt = 1
        var redirects = 0
        while true {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("en", forHTTPHeaderField: "Accept-Language")
            request.setValue("me.majd.ipatool", forHTTPHeaderField: "X-Apple-Client-Application")
            request.setValue("0", forHTTPHeaderField: "X-Apple-Tz")
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            request.setValue("application/x-apple-plist", forHTTPHeaderField: "Content-Type")
            request.setValue(StoreConstants.userAgent, forHTTPHeaderField: "User-Agent")
            let body = try loginBody(attempt: attempt)
            request.httpBody = body
            request.setValue(try signer.sign(body), forHTTPHeaderField: "X-Apple-ActionSignature")

            var response = try await send(request)
            for retry in 1..<3 {
                let s = response.status
                guard response.machineAction == nil, [204, 403, 404, 429].contains(s) || s / 100 == 5 else { break }
                let delay = min(10 << (retry - 1), 30)
                try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                request.setValue(try signer.sign(body), forHTTPHeaderField: "X-Apple-ActionSignature")
                response = try await send(request)
            }
            if response.machineAction != nil { return response }
            if (300..<400).contains(response.status) {
                guard redirects < StoreConstants.maxRedirects,
                      let location = response.header("Location"),
                      let next = Self.resolveRedirect(from: url, location: location) else {
                    throw StoreError("unsupported authentication redirect (HTTP \(response.status))")
                }
                redirects += 1
                url = next
                continue
            }
            if attempt == 1, response.plist["failureType"] as? String == StoreConstants.invalidCredentials {
                attempt += 1
                continue
            }
            return response
        }
    }

    private func performLogin() async throws -> StoreResponse {
        _ = ensureGuid()
        if clearCookiesBeforeLogin, let storage = session.configuration.httpCookieStorage, let cookies = storage.cookies {
            cookies.filter { $0.domain.hasSuffix("apple.com") }.forEach(storage.deleteCookie)
        }
        let bag = try await getBag()
        let endpoint = bag.endpoint
        let signer = try await StoreSAPSigner.create(setupURL: bag.sapSetup, certificateURL: bag.sapCertificate,
                                                      version: bag.sapVersion, guid: guid!)
        defer { signer.close() }
        let anisette = StoreAnisette.shared
        loginTrace = []
        return try await StoreAuthenticationFlow.run(
            cachedProof: { await anisette.cachedStoreProof() },
            identity: {
                await anisette.startFreshIdentity()
                return try await anisette.identityHeaders()
            },
            provision: { challenge, identity in
                try await anisette.provisionStore(challenge: challenge, identity: identity)
            },
            storeProof: { try await anisette.storeProof() },
            send: { headers in
                let kind = headers["X-Apple-AMD"] == nil ? "noproof" : (headers["X-Mme-Device-Id"] == nil ? "store" : "machine")
                let response = try await self.sendLogin(endpoint: endpoint, headers: headers, signer: signer)
                self.loginTrace.append("\(self.loginTrace.count + 1)[\(kind)]=\(response.status)\(response.machineAction.map { " " + $0.action } ?? "")")
                return response
            },
            action: { $0.machineAction }
        )
    }

    private static func directoryServicesID(from response: StoreResponse) -> String? {
        if let queue = response.plist["download-queue-info"] as? [String: Any], let dsid = queue["dsid"] {
            return "\(dsid)"
        }
        if let dsid = response.plist["dsPersonId"] as? String, !dsid.isEmpty { return dsid }
        if let dsid = response.header("X-Dsid")?.trimmingCharacters(in: .whitespaces), !dsid.isEmpty { return dsid }
        if let cookies = response.header("Set-Cookie"),
           let match = cookies.range(of: #"mz_at(?:0|_ssl)-([0-9]+)="#, options: .regularExpression) {
            return cookies[match].components(separatedBy: "-").last?.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        }
        return nil
    }

    func login(code: String?) async throws -> StoreLoginResult {
        clearCookiesBeforeLogin = (code == nil)
        password = basePassword + (code ?? "")

        let response = try await performLogin()
        if let action = response.machineAction {
            throw AppStoreClientError.message("Apple requested an unsupported machine action (\(action.action)) [\(loginTrace.joined(separator: ", "))]")
        }
        let resp = response.plist
        let customerMessage = resp["customerMessage"] as? String ?? ""
        let failureType = resp["failureType"] as? String ?? ""
        let passwordToken = resp["passwordToken"] as? String ?? ""

        if failureType.isEmpty && customerMessage.contains("Configurator_message") {
            throw AppStoreClientError.twoFactorRequired
        }
        if !failureType.isEmpty || response.status != 200 || passwordToken.isEmpty {
            if failureType == StoreConstants.invalidCredentials || customerMessage.localizedCaseInsensitiveContains("incorrect") {
                throw AppStoreClientError.invalidCredentials
            }
            let diagnostic = customerMessage.isEmpty
                ? "HTTP \(response.status), failure type \(failureType.isEmpty ? "none" : failureType) [\(loginTrace.joined(separator: ", "))]"
                : customerMessage
            throw AppStoreClientError.message(diagnostic)
        }
        guard let dsid = Self.directoryServicesID(from: response) else {
            throw AppStoreClientError.message("Apple returned no directory services identifier")
        }
        guard let storeFront = response.header("X-Set-Apple-Store-Front") ?? response.header("X-Apple-Request-Store-Front") else {
            throw AppStoreClientError.message("Apple returned no storefront")
        }

        pod = response.header("pod")
        authHeaders = [
            "X-Dsid": dsid,
            "iCloud-Dsid": dsid,
            "X-Apple-Store-Front": storeFront,
            "X-Token": passwordToken
        ]
        authCookies = session.configuration.httpCookieStorage?.cookies
        if let accountInfo = resp["accountInfo"] as? [String: Any],
           let address = accountInfo["address"] as? [String: Any] {
            let first = address["firstName"] as? String ?? ""
            let last = address["lastName"] as? String ?? ""
            accountName = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
        }
        return StoreLoginResult(directoryServicesIdentifier: dsid, storeFront: storeFront,
                                token: passwordToken, accountName: accountName ?? "")
    }

    // MARK: ent/download

    private static let entDownloadURL = URL(string: "https://downloaddispatch.itunes.apple.com/WebObjects/DownloadDispatch.woa/wa/ent/download")!
    private static let lookupUserAgent = "Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6"

    private func kbsync(dsid: UInt64, guid: String, fresh: Bool) async throws -> String {
        let key = "kbsync-\(dsid)-\(guid)"
        if !fresh, let cached = UserDefaults.standard.string(forKey: key) { return cached }
        let blob = try await StoreKBSync.generate(guid: guid, dsid: dsid)
        UserDefaults.standard.set(blob, forKey: key)
        return blob
    }

    private func latestExternalVersionID(appId: String, storeFront: String) async throws -> String {
        var components = URLComponents(string: "https://uclient-api.itunes.apple.com/WebObjects/MZStorePlatform.woa/wa/lookup")!
        components.queryItems = [
            URLQueryItem(name: "version", value: "2"), URLQueryItem(name: "id", value: appId),
            URLQueryItem(name: "p", value: "mdm-lockup"), URLQueryItem(name: "caller", value: "MDM"),
            URLQueryItem(name: "platform", value: "enterprisestore"), URLQueryItem(name: "l", value: "en"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(Self.lookupUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(storeFront, forHTTPHeaderField: "X-Apple-Store-Front")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [String: Any],
              let item = results[appId] as? [String: Any],
              let offer = (item["offers"] as? [[String: Any]])?.first else {
            throw StoreError("App \(appId) not found in the enterprise catalog")
        }
        if let version = offer["version"] as? [String: Any], let id = version["externalId"] {
            return "\(id)"
        }
        if let params = offer["buyParams"] as? String,
           let value = URLComponents(string: "?" + params)?.queryItems?.first(where: { $0.name == "appExtVrsId" })?.value {
            return value
        }
        throw StoreError("No external version id for app \(appId)")
    }

    private func entDownload(appId: String, appVerId: String) async throws -> StoreResponse {
        guard let guid, let auth = authHeaders, let dsidString = auth["X-Dsid"], let dsid = UInt64(dsidString),
              let token = auth["X-Token"], let storeFront = auth["X-Apple-Store-Front"] else {
            throw AppStoreClientError.notAuthenticated
        }
        let version = appVerId.isEmpty ? try await latestExternalVersionID(appId: appId, storeFront: storeFront) : appVerId
        let hardware = stride(from: 0, to: guid.count, by: 2).compactMap { offset -> UInt8? in
            let start = guid.index(guid.startIndex, offsetBy: offset)
            return UInt8(guid[start..<guid.index(start, offsetBy: 2)], radix: 16)
        }
        guard hardware.count == 6 else { throw StoreError("ent/download requires a six-byte device GUID") }
        let serial = Data([0x54, 0xc8, 0xb0, 0xa9, 0x88] + hardware[2...]).base64EncodedString()

        if let cookies = authCookies {
            session.configuration.httpCookieStorage?.setCookies(cookies, for: Self.entDownloadURL, mainDocumentURL: nil)
        }

        for attempt in 0..<2 {
            let blob = try await kbsync(dsid: dsid, guid: guid, fresh: attempt > 0)
            var proof = await StoreAnisette.shared.cachedStoreProof()
            if proof == nil {
                let login = try await performLogin()
                guard login.machineAction == nil, login.status == 200 else {
                    throw StoreError("Store re-login failed (HTTP \(login.status))")
                }
                proof = await StoreAnisette.shared.cachedStoreProof()
            }
            guard let proof else { throw StoreError("No Store AMD proof after re-login") }

            let body: [String: Any] = [
                "creditDisplay": "", "guid": guid, "kbsync": blob, "salableAdamId": appId,
                "serialNumber": serial, "externalVersionId": version,
            ]
            var request = URLRequest(url: Self.entDownloadURL)
            request.httpMethod = "POST"
            request.httpBody = try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.setValue(StoreConstants.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(storeFront, forHTTPHeaderField: "X-Apple-Store-Front")
            request.setValue(token, forHTTPHeaderField: "X-Token")
            request.setValue(dsidString, forHTTPHeaderField: "X-Dsid")
            request.setValue("me.majd.ipatool", forHTTPHeaderField: "X-Apple-Client-Application")
            request.setValue("0", forHTTPHeaderField: "X-Apple-Tz")
            for (key, value) in proof { request.setValue(value, forHTTPHeaderField: key) }

            let response = try await send(request)
            let items = response.plist["songList"] as? [[String: Any]] ?? []
            if response.status == 200, !items.isEmpty { return response }
            if attempt == 0 { continue }
            return response
        }
        throw StoreError("ent/download failed")
    }

    /// Returns the first songList entry, with `apple-id`/`userName` patched into
    /// its metadata (as ipatool does), or throws an informative error.
    func downloadInfo(appId: String, appVerId: String) async throws -> [String: Any] {
        let response = try await entDownload(appId: appId, appVerId: appVerId)
        let songList = response.plist["songList"] as? [[String: Any]] ?? []
        guard var info = songList.first else {
            let failure = response.plist["failureType"] as? String ?? ""
            let message = response.plist["customerMessage"] as? String ?? ""
            if failure == "9610" || message.localizedCaseInsensitiveContains("not been purchased")
                || message.localizedCaseInsensitiveContains("license") {
                throw AppStoreClientError.licenseRequired
            }
            throw AppStoreClientError.message(message.isEmpty ? "The App Store returned no downloadable item (HTTP \(response.status))." : message)
        }
        var metadata = info["metadata"] as? [String: Any] ?? [:]
        metadata["apple-id"] = appleId
        metadata["userName"] = appleId
        info["metadata"] = metadata
        return info
    }
}
