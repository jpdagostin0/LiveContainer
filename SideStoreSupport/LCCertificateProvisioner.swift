//
//  LCCertificateProvisioner.swift
//  SideStoreSupport
//
//  Bridges LiveContainer's App Store sign-in to the built-in SideStore's
//  headless certificate provisioning (RefreshHandler.startProvision), exposed
//  as an @objc class so LiveContainerSwiftUI can reach it at runtime via
//  NSClassFromString without a hard link to this optional framework.
//

import Foundation

@objc(LCCertificateProvisioner)
public final class LCCertificateProvisioner: NSObject, LCCertificateProvisioning {

    @objc public override init() {
        super.init()
    }

    @objc public func provisionCertificate(
        withEmail email: String,
        password: String,
        code: String?,
        anisette: [String: String],
        verificationCodeProvider: @escaping (String?, @escaping (String?) -> Void) -> Void,
        completion: @escaping (Data?, String?, String?) -> Void
    ) {
        Task {
            do {
                let (certificate, certPassword) = try await RefreshHandler.shared.startProvision(
                    appleID: email,
                    password: password,
                    code: code,
                    anisette: anisette,
                    verificationCodeProvider: verificationCodeProvider
                )
                completion(certificate, certPassword, nil)
            } catch {
                completion(nil, nil, (error as NSError).localizedDescription)
            }
        }
    }
}
