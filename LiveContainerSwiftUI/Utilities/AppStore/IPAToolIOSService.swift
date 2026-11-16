//
//  IPAToolIOSService.swift
//  LiveContainerSwiftUI
//
//  Embedded Swift adaptation of ipatool-ios. It intentionally uses the same
//  Configurator authentication and volumeStoreDownloadProduct protocol rather
//  than the Go ipatool implementation.
//

import Foundation

@MainActor
final class IPAToolIOSService {
    static let shared = IPAToolIOSService()

    private let keychain = IPAToolIOSKeychain.shared
    private let noRedirectDelegate = IPAToolIOSNoRedirectDelegate()
    private lazy var storeSession = URLSession(configuration: .default,
                                               delegate: noRedirectDelegate,
                                               delegateQueue: nil)
    private let publicSession = URLSession.shared

    private(set) var activeAccount: IPAToolIOSAccount?

    private init() {}

    func search(term: String, limit: Int = 25) async throws -> [IPAToolIOSApp] {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "media", value: "software"),
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "limit", value: String(max(1, min(limit, 200))))
        ]
        guard let url = components.url else {
            throw IPAToolIOSError.invalidResponse
        }

        let (data, response) = try await publicSession.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw IPAToolIOSError.invalidResponse
        }
        return try JSONDecoder().decode(IPAToolIOSSearchResponse.self, from: data).results
    }

    func lookup(bundleIdentifier: String) async throws -> IPAToolIOSApp {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [
            URLQueryItem(name: "media", value: "software"),
            URLQueryItem(name: "bundleId", value: bundleIdentifier),
            URLQueryItem(name: "limit", value: "1")
        ]
        guard let url = components.url else {
            throw IPAToolIOSError.invalidResponse
        }

        let (data, response) = try await publicSession.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw IPAToolIOSError.invalidResponse
        }
        guard let app = try JSONDecoder().decode(IPAToolIOSSearchResponse.self, from: data).results.first else {
            throw IPAToolIOSError.appNotFound
        }
        return app
    }

    func authenticate(email: String,
                      password: String,
                      code: String? = nil,
                      rememberAccount: Bool = true) async throws -> IPAToolIOSAccount {
        let normalizedCode = code?.filter(\.isNumber)
        if let normalizedCode, normalizedCode.count != 6 {
            throw IPAToolIOSError.invalidCredentials
        }

        let account = try await authenticate(email: email,
                                             password: password,
                                             code: normalizedCode,
                                             attempt: 1,
                                             redirectURL: nil)
        activeAccount = account
        if rememberAccount {
            try keychain.save(account: account)
        }
        return account
    }

    func authenticateSavedAccount(code: String? = nil) async throws -> IPAToolIOSAccount {
        guard let saved = try keychain.loadAccount() else {
            throw IPAToolIOSError.notAuthenticated
        }
        return try await authenticate(email: saved.email,
                                      password: saved.password,
                                      code: code,
                                      rememberAccount: true)
    }

    func savedAccount() throws -> IPAToolIOSAccount? {
        try keychain.loadAccount()
    }

    func logout() throws {
        activeAccount = nil
        try keychain.removeAccount()
        HTTPCookieStorage.shared.cookies?.forEach { cookie in
            if cookie.domain.contains("itunes.apple.com") || cookie.domain.contains("apple.com") {
                HTTPCookieStorage.shared.deleteCookie(cookie)
            }
        }
    }

    func download(app: IPAToolIOSApp,
                  to destinationURL: URL,
                  progress: @escaping @Sendable (Double) -> Void) async throws -> IPAToolIOSDownload {
        guard let account = activeAccount else {
            throw IPAToolIOSError.notAuthenticated
        }

        let item = try await storeItem(appIdentifier: app.id,
                                       directoryServicesIdentifier: account.directoryServicesIdentifier,
                                       email: account.email)
        guard let sinf = item.signatures.first(where: { $0.id == 0 }) ?? item.signatures.first else {
            throw IPAToolIOSError.noSignature
        }

        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destinationURL)

        let operation = IPAToolIOSDownloadOperation()
        do {
            try await operation.download(from: item.url, to: destinationURL, progress: progress)
        } catch {
            throw IPAToolIOSError.downloadFailed(error.localizedDescription)
        }

        return IPAToolIOSDownload(encryptedIPAURL: destinationURL,
                                  mainSinf: sinf.data,
                                  metadataPlist: item.metadataPlist)
    }

    private func authenticate(email: String,
                              password: String,
                              code: String?,
                              attempt: Int,
                              redirectURL: URL?) async throws -> IPAToolIOSAccount {
        guard attempt <= 4 else {
            throw IPAToolIOSError.tooManyAttempts
        }

        let guid = try keychain.deviceGUID()
        let endpoint = redirectURL ?? URL(string: "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate")!
        let payload: [String: String] = [
            "appleId": email,
            "attempt": String(attempt),
            "guid": guid,
            "password": password + (code ?? ""),
            "rmp": "0",
            "why": "signIn"
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Configurator/2.0 (Macintosh; OS X 10.12.6; 16G29) AppleWebKit/2603.3.8",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = try PropertyListSerialization.data(fromPropertyList: payload,
                                                              format: .xml,
                                                              options: 0)

        let (data, response) = try await storeSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw IPAToolIOSError.invalidResponse
        }

        if httpResponse.statusCode == 302,
           let location = httpResponse.value(forHTTPHeaderField: "Location"),
           let redirect = URL(string: location, relativeTo: endpoint)?.absoluteURL {
            return try await authenticate(email: email,
                                          password: password,
                                          code: code,
                                          attempt: attempt + 1,
                                          redirectURL: redirect)
        }

        // Apple retired the Configurator MZFinance login: the endpoint now answers
        // a 3xx/HTML page instead of a plist. Detect that here so the user gets a
        // clear explanation instead of a raw "data isn't in the correct format".
        if (300..<400).contains(httpResponse.statusCode) {
            throw IPAToolIOSError.loginEndpointRetired
        }
        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if contentType.contains("text/html") {
            throw IPAToolIOSError.loginEndpointRetired
        }

        let propertyList: [String: Any]
        do {
            propertyList = try storePropertyList(from: data)
        } catch {
            // A non-plist 200 body is the same retirement symptom seen in the wild.
            throw IPAToolIOSError.loginEndpointRetired
        }
        if let accountInfo = propertyList["accountInfo"] as? [String: Any],
           let directoryServicesIdentifier = stringValue(propertyList["dsPersonId"]) {
            let address = accountInfo["address"] as? [String: Any]
            return IPAToolIOSAccount(email: email,
                                     password: password,
                                     firstName: stringValue(address?["firstName"]) ?? "",
                                     lastName: stringValue(address?["lastName"]) ?? "",
                                     directoryServicesIdentifier: directoryServicesIdentifier)
        }

        let mappedError = mapStoreError(propertyList)
        if mappedError == .invalidCredentials && attempt == 1 {
            return try await authenticate(email: email,
                                          password: password,
                                          code: code,
                                          attempt: attempt + 1,
                                          redirectURL: nil)
        }
        throw mappedError
    }

    private func storeItem(appIdentifier: Int64,
                           directoryServicesIdentifier: String,
                           email: String) async throws -> IPAToolIOSStoreItem {
        let guid = try keychain.deviceGUID()
        let endpoint = URL(string: "https://p25-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct?guid=\(guid)")!
        let payload: [String: String] = [
            "creditDisplay": "",
            "guid": guid,
            "salableAdamId": String(appIdentifier)
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Configurator/2.0 (Macintosh; OS X 10.12.6; 16G29) AppleWebKit/2603.3.8",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(directoryServicesIdentifier, forHTTPHeaderField: "X-Dsid")
        request.setValue(directoryServicesIdentifier, forHTTPHeaderField: "iCloud-DSID")
        request.httpBody = try PropertyListSerialization.data(fromPropertyList: payload,
                                                              format: .xml,
                                                              options: 0)

        let (data, response) = try await storeSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<400).contains(httpResponse.statusCode) else {
            throw IPAToolIOSError.invalidResponse
        }

        let propertyList = try storePropertyList(from: data)
        guard let songs = propertyList["songList"] as? [[String: Any]],
              let song = songs.first else {
            throw mapStoreError(propertyList)
        }
        guard let urlString = song["URL"] as? String,
              let url = URL(string: urlString),
              let md5 = song["md5"] as? String,
              let metadata = song["metadata"] as? [String: Any] else {
            throw IPAToolIOSError.invalidItem
        }

        let signatures: [IPAToolIOSSinf] = (song["sinfs"] as? [[String: Any]] ?? []).compactMap { value in
            guard let id = intValue(value["id"]), let data = value["sinf"] as? Data else {
                return nil
            }
            return IPAToolIOSSinf(id: id, data: data)
        }

        var patchedMetadata = metadata
        patchedMetadata["apple-id"] = email
        patchedMetadata["userName"] = email
        let metadataPlist = try PropertyListSerialization.data(fromPropertyList: patchedMetadata,
                                                               format: .xml,
                                                               options: 0)
        return IPAToolIOSStoreItem(url: url,
                                   md5: md5,
                                   signatures: signatures,
                                   metadataPlist: metadataPlist)
    }

    private func storePropertyList(from data: Data) throws -> [String: Any] {
        guard let propertyList = try PropertyListSerialization.propertyList(from: data,
                                                                            options: [],
                                                                            format: nil) as? [String: Any] else {
            throw IPAToolIOSError.invalidResponse
        }
        return propertyList
    }

    private func mapStoreError(_ propertyList: [String: Any]) -> IPAToolIOSError {
        let failureType = intValue(propertyList["failureType"])
        let message = stringValue(propertyList["customerMessage"]) ?? ""

        switch failureType {
        case 1:
            return .twoFactorRequired
        case 5001:
            return .invalidAccount
        case 9610:
            return .invalidLicense
        case -5000:
            return .invalidCredentials
        case -10000:
            return .invalidItem
        case -10001:
            return .lockedAccount
        default:
            break
        }

        if message.contains("verification code is required") || message == "MZFinance.BadLogin.Configurator_message" {
            return .twoFactorRequired
        }
        if message.contains("entered incorrectly") {
            return .invalidCredentials
        }
        if message.localizedCaseInsensitiveContains("locked") {
            return .lockedAccount
        }
        return .invalidResponse
    }

    private func stringValue(_ value: Any?) -> String? {
        if let value = value as? String {
            return value
        }
        if let value = value as? NSNumber {
            return value.stringValue
        }
        return nil
    }

    private func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        if let value = value as? String {
            return Int(value)
        }
        return nil
    }
}

private final class IPAToolIOSNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private final class IPAToolIOSDownloadOperation: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var session: URLSession?
    private var destinationURL: URL?
    private var progressHandler: (@Sendable (Double) -> Void)?
    private var continuation: CheckedContinuation<Void, Error>?

    func download(from sourceURL: URL,
                  to destinationURL: URL,
                  progress: @escaping @Sendable (Double) -> Void) async throws {
        self.destinationURL = destinationURL
        progressHandler = progress

        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: delegateQueue)
        self.session = session

        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            session.downloadTask(with: sourceURL).resume()
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else {
            return
        }
        progressHandler?(min(1, max(0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))))
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let destinationURL else {
            finish(.failure(IPAToolIOSError.downloadFailed("missing destination")))
            return
        }
        if let response = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(response.statusCode) {
            finish(.failure(IPAToolIOSError.downloadFailed("HTTP \(response.statusCode)")))
            return
        }

        do {
            try? FileManager.default.removeItem(at: destinationURL)
            try FileManager.default.moveItem(at: location, to: destinationURL)
            progressHandler?(1)
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let continuation else {
            return
        }
        self.continuation = nil
        progressHandler = nil
        destinationURL = nil
        session?.finishTasksAndInvalidate()
        session = nil

        switch result {
        case .success:
            continuation.resume()
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }
}
