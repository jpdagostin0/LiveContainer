// Mac CoreADI identity and provisioning via AnisetteKit's MacAnisetteKit.
// Ported from WaffleStore into LiveContainer's AppStoreCore module.
import Foundation
import MacAnisetteKit

enum StoreAnisetteError: LocalizedError {
    case missingMachineAnisette, missingStoreProof
    var errorDescription: String? {
        switch self {
        case .missingMachineAnisette: "Mac CoreADI did not return the machine anisette (X-Apple-I-MD / X-Apple-I-MD-M)."
        case .missingStoreProof: "Store provisioning finished but CoreADI has no Store AMD proof."
        }
    }
}

final class StoreAnisette: @unchecked Sendable {
    static let shared = StoreAnisette()
    private let modern = ModernAnisetteClient(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MacAnisette-v2", isDirectory: true))
    private let lock = NSLock()
    private var preparation: Task<Void, Error>?

    private func waitForPreparation() async throws {
        let task: Task<Void, Error> = lock.withLock {
            if let preparation { return preparation }
            let task = Task { _ = try await modern.getHeaders() }
            preparation = task
            return task
        }
        do {
            try await task.value
        } catch {
            lock.withLock { preparation = nil }
            throw error
        }
    }

    func prepare() async {
        do {
            try await waitForPreparation()
            print("[MacADI] Ready")
        } catch {
            print("[MacADI] Startup failed: \(error.localizedDescription)")
        }
    }

    func identityHeaders() async throws -> [String: String] {
        try await modern.getHeaders()
    }

    func startFreshIdentity() async {
        lock.withLock { preparation = nil }
        await modern.resetIdentity()
    }

    static func storeHeaders(from identity: [String: String], endpoint: URL) throws -> [String: String] {
        var headers = identity.filter {
            !["x-apple-i-md", "x-apple-i-md-m"].contains($0.key.lowercased())
        }
        guard let otp = identity.first(where: { $0.key.lowercased() == "x-apple-i-md" })?.value,
              let mid = identity.first(where: { $0.key.lowercased() == "x-apple-i-md-m" })?.value,
              !otp.isEmpty, !mid.isEmpty else {
            throw StoreAnisetteError.missingMachineAnisette
        }
        headers["X-Apple-AMD"] = otp
        headers["X-Apple-AMD-M"] = mid
        return headers
    }

    static let storeProvisioningURL = URL(string: "https://auth.itunes.apple.com/auth/v1/otp/1.5/finish")!
    static let storeProvisioningUserAgent = "Configurator/2.21 (Macintosh; OS X 27.0.1; 26A434) AppleWebKit/0625.2.5.11.6"

    func cachedStoreProof() async -> [String: String]? {
        do {
            return try await modern.storeProof()
        } catch {
            print("[MacADI] No cached Store proof: \(error.localizedDescription)")
            return nil
        }
    }

    func provisionStore(challenge: String, identity: [String: String]) async throws {
        try await modern.provisionStore(challenge: challenge, identity: identity,
                                        endpoint: Self.storeProvisioningURL,
                                        userAgent: Self.storeProvisioningUserAgent)
    }

    func storeProof() async throws -> [String: String] {
        guard let proof = try await modern.storeProof() else { throw StoreAnisetteError.missingStoreProof }
        return proof
    }

    func storeAMDProof(for endpoint: URL) async throws -> [String: String] {
        if let proof = await cachedStoreProof() { return proof }
        let identity = try await identityHeaders()
        return try Self.storeHeaders(from: identity, endpoint: endpoint)
    }
}
