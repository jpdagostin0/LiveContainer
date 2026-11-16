//
//  IPAToolIOSModels.swift
//  LiveContainerSwiftUI
//
//  Models adapted from ipatool-ios by Majd Alfhaily.
//

import Foundation

struct IPAToolIOSApp: Codable, Hashable, Identifiable, Sendable {
    let id: Int64
    let bundleIdentifier: String
    let version: String
    let name: String
    let artworkURL: URL?
    let developerName: String?
    let appDescription: String?

    enum CodingKeys: String, CodingKey {
        case id = "trackId"
        case bundleIdentifier = "bundleId"
        case version
        case name = "trackName"
        case artworkURL = "artworkUrl100"
        case developerName = "artistName"
        case appDescription = "description"
    }
}

struct IPAToolIOSSearchResponse: Decodable, Sendable {
    let resultCount: Int
    let results: [IPAToolIOSApp]
}

struct IPAToolIOSAccount: Codable, Hashable, Sendable {
    let email: String
    let password: String
    let firstName: String
    let lastName: String
    let directoryServicesIdentifier: String

    var displayName: String {
        let name = "\(firstName) \(lastName)".trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? email : name
    }
}

struct IPAToolIOSSinf: Sendable {
    let id: Int
    let data: Data
}

struct IPAToolIOSStoreItem: Sendable {
    let url: URL
    let md5: String
    let signatures: [IPAToolIOSSinf]
    let metadataPlist: Data
}

struct IPAToolIOSDownload: Sendable {
    let encryptedIPAURL: URL
    let mainSinf: Data
    let metadataPlist: Data
}

enum IPAToolIOSError: LocalizedError, Equatable {
    case twoFactorRequired
    case notAuthenticated
    case invalidCredentials
    case invalidAccount
    case invalidLicense
    case invalidItem
    case lockedAccount
    case tooManyAttempts
    case invalidResponse
    case loginEndpointRetired
    case appNotFound
    case noSignature
    case downloadFailed(String)
    case serverMessage(String)
    case keychain(Int32)

    var errorDescription: String? {
        switch self {
        case .twoFactorRequired:
            return "A six-digit Apple ID verification code is required."
        case .notAuthenticated:
            return "Sign in to the App Store before downloading an app."
        case .invalidCredentials:
            return "The Apple ID or password is incorrect."
        case .invalidAccount:
            return "This Apple ID has not been configured for the App Store."
        case .invalidLicense:
            return "This Apple ID does not own a license for this app. Acquire it in the App Store first."
        case .invalidItem:
            return "The App Store returned an invalid app package response."
        case .lockedAccount:
            return "This Apple ID is locked for security reasons."
        case .tooManyAttempts:
            return "The App Store redirected the sign-in request too many times."
        case .invalidResponse:
            return "The App Store returned an unsupported response."
        case .loginEndpointRetired:
            return "Apple has retired the Configurator sign-in method this build uses, so "
                + "App Store login no longer works here. The current App Store requires a "
                + "device-signed request (AppleMediaServices). Use the App Store tab's "
                + "\"Test native signing\" to check whether this device can provide it."
        case .appNotFound:
            return "The app could not be found in the App Store."
        case .noSignature:
            return "The App Store response did not contain a FairPlay SINF."
        case .downloadFailed(let message):
            return "The IPA download failed: \(message)"
        case .serverMessage(let message):
            return message
        case .keychain(let status):
            return "Keychain operation failed with status \(status)."
        }
    }
}
