//
//  WorseQueryService.swift
//  LiveContainerSwiftUI
//
//  Optional access diagnostic built from forcequit's GPLv3 worse_query PoC.
//  This grants LiveContainer access; it does not grant fairplayd access and is
//  therefore intentionally not part of the normal decryption path.
//

import Foundation

final class WorseQueryAccess {
    private var handle: Int64

    fileprivate init(handle: Int64) {
        self.handle = handle
    }

    func releaseAccess() {
        guard handle >= 0 else {
            return
        }
        worse_query_release(handle)
        handle = -1
    }

    deinit {
        releaseAccess()
    }
}

@MainActor
final class WorseQueryService {
    static let shared = WorseQueryService()

    private init() {}

    var isSupported: Bool {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        if version.majorVersion == 26 {
            return version.minorVersion <= 7
        }
        return version.majorVersion == 27 && version.minorVersion <= 2
    }

    func acquireAccess(to path: String, createDirectory: Bool = false) throws -> WorseQueryAccess {
        guard isSupported else {
            throw WorseQueryError.unsupportedOS
        }
        guard let group = LCSharedUtils.appGroupID(), !group.isEmpty, group != "Unknown" else {
            throw WorseQueryError.noAppGroup
        }

        let version = ProcessInfo.processInfo.operatingSystemVersion
        let handle = worse_query(path, group, version.majorVersion == 26, createDirectory)
        guard handle >= 0 else {
            throw WorseQueryError.failure(code: handle)
        }
        return WorseQueryAccess(handle: handle)
    }
}

enum WorseQueryError: LocalizedError {
    case unsupportedOS
    case noAppGroup
    case failure(code: Int64)

    var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            return "worse_query is not available on this iOS version."
        case .noAppGroup:
            return "LiveContainer could not resolve an app group for worse_query."
        case .failure(let code):
            switch code {
            case -1:
                return "The selected app group is unavailable."
            case -2:
                return "The required containermanager symbols are unavailable."
            case -3:
                return "The containermanager query could not be created."
            case -4:
                return "The temporary app-group cache link could not be created."
            case -5:
                return "containermanagerd rejected the query."
            case -6:
                return "The kernel did not issue a sandbox extension."
            case -255:
                return "The requested path does not exist."
            default:
                return "worse_query failed with code \(code)."
            }
        }
    }
}
