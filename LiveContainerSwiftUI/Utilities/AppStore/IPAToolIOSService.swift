//
//  IPAToolIOSService.swift
//  LiveContainerSwiftUI
//
//  App Store client. Search/lookup use the public iTunes API; sign-in and
//  download are backed by AppStoreCore (the native SAP-signed RP/SP login +
//  CoreADI anisette + ent/download ported from WaffleStore), replacing the
//  retired Configurator/MZFinance protocol.
//

import Foundation
import AppStoreCore

@MainActor
final class IPAToolIOSService {
    static let shared = IPAToolIOSService()

    private let keychain = IPAToolIOSKeychain.shared
    private let publicSession = URLSession.shared

    private(set) var activeAccount: IPAToolIOSAccount?
    /// The authenticated store client is stateful (login state feeds the
    /// download), so it is kept between authenticate() and download().
    private var client: AppStoreClient?
    private var clientEmail: String?

    private init() {}

    // MARK: - Public catalog (iTunes search API)

    func search(term: String, limit: Int = 25) async throws -> [IPAToolIOSApp] {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "media", value: "software"),
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "limit", value: String(max(1, min(limit, 200))))
        ]
        guard let url = components.url else { throw IPAToolIOSError.invalidResponse }
        let (data, response) = try await publicSession.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
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
        guard let url = components.url else { throw IPAToolIOSError.invalidResponse }
        let (data, response) = try await publicSession.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw IPAToolIOSError.invalidResponse
        }
        guard let app = try JSONDecoder().decode(IPAToolIOSSearchResponse.self, from: data).results.first else {
            throw IPAToolIOSError.appNotFound
        }
        return app
    }

    // MARK: - Authentication (native AppStoreCore)

    func authenticate(email: String,
                      password: String,
                      code: String? = nil,
                      rememberAccount: Bool = true) async throws -> IPAToolIOSAccount {
        let normalizedCode = code?.filter(\.isNumber)
        if let normalizedCode, normalizedCode.count != 6 {
            throw IPAToolIOSError.invalidCredentials
        }

        // Reuse the client across the 2FA retry (same Apple ID); recreate it for
        // a different account or a fresh password.
        let storeClient: AppStoreClient
        if let client, clientEmail == email, normalizedCode != nil {
            storeClient = client
        } else {
            storeClient = AppStoreClient(appleId: email, password: password)
            client = storeClient
            clientEmail = email
        }

        let result: StoreLoginResult
        do {
            result = try await storeClient.logIn(code: normalizedCode)
        } catch {
            throw Self.map(error)
        }

        let parts = result.accountName.split(separator: " ", maxSplits: 1).map(String.init)
        let account = IPAToolIOSAccount(email: email,
                                        password: password,
                                        firstName: parts.first ?? "",
                                        lastName: parts.count > 1 ? parts[1] : "",
                                        directoryServicesIdentifier: result.directoryServicesIdentifier)
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

    /// Machine-anisette snapshot (LCProvisioningBridge keys) from the CoreADI
    /// identity used for login, for the built-in SideStore to provision a
    /// signing certificate against the same machine identity.
    func machineAnisette() async throws -> [String: String] {
        try await AppStoreClient.machineAnisetteSnapshot()
    }

    func logout() throws {
        activeAccount = nil
        client = nil
        clientEmail = nil
        try keychain.removeAccount()
        HTTPCookieStorage.shared.cookies?.forEach { cookie in
            if cookie.domain.contains("itunes.apple.com") || cookie.domain.contains("apple.com") {
                HTTPCookieStorage.shared.deleteCookie(cookie)
            }
        }
    }

    // MARK: - Download (native ent/download + direct fetch)

    func download(app: IPAToolIOSApp,
                  to destinationURL: URL,
                  progress: @escaping @Sendable (Double) -> Void) async throws -> IPAToolIOSDownload {
        guard let storeClient = client, activeAccount != nil else {
            throw IPAToolIOSError.notAuthenticated
        }

        let item = try await storeItem(client: storeClient, appIdentifier: app.id)
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

    /// Maps AppStoreCore's ent/download song info onto the LiveContainer model.
    private func storeItem(client: AppStoreClient, appIdentifier: Int64) async throws -> IPAToolIOSStoreItem {
        let info: [String: Any]
        do {
            info = try await client.downloadInfo(appId: String(appIdentifier), appVerId: "")
        } catch {
            throw Self.map(error)
        }
        guard let urlString = info["URL"] as? String, let url = URL(string: urlString) else {
            throw IPAToolIOSError.invalidItem
        }
        let signatures: [IPAToolIOSSinf] = (info["sinfs"] as? [[String: Any]] ?? []).compactMap { value in
            guard let id = Self.intValue(value["id"]), let data = value["sinf"] as? Data else { return nil }
            return IPAToolIOSSinf(id: id, data: data)
        }
        let metadata = info["metadata"] as? [String: Any] ?? [:]
        let metadataPlist = try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
        return IPAToolIOSStoreItem(url: url,
                                   md5: info["md5"] as? String ?? "",
                                   signatures: signatures,
                                   metadataPlist: metadataPlist)
    }

    // MARK: - Error mapping

    private static func map(_ error: Error) -> IPAToolIOSError {
        if let e = error as? IPAToolIOSError { return e }
        if let e = error as? AppStoreClientError {
            switch e {
            case .twoFactorRequired: return .twoFactorRequired
            case .invalidCredentials: return .invalidCredentials
            case .notAuthenticated: return .notAuthenticated
            case .licenseRequired: return .invalidLicense
            case let .message(message): return .serverMessage(message)
            }
        }
        if let message = error as? String { return .serverMessage(message) }
        return .serverMessage((error as NSError).localizedDescription)
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
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
        guard totalBytesExpectedToWrite > 0 else { return }
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
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        progressHandler = nil
        destinationURL = nil
        session?.finishTasksAndInvalidate()
        session = nil
        switch result {
        case .success: continuation.resume()
        case let .failure(error): continuation.resume(throwing: error)
        }
    }
}
