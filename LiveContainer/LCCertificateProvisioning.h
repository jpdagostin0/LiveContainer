//
//  LCCertificateProvisioning.h
//  LiveContainer
//
//  Decouples LiveContainer's App Store sign-in (LiveContainerSwiftUI) from the
//  optional SideStoreSupport framework. SideStoreSupport provides an
//  @objc(LCCertificateProvisioner) class conforming to this protocol; the UI
//  resolves it at runtime with NSClassFromString so the build still links when
//  SideStore support is disabled (INCLUDE_SIDESTORE=0).
//

#ifndef LCCertificateProvisioning_h
#define LCCertificateProvisioning_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol LCCertificateProvisioning <NSObject>

/// Runs SideStore's sign-in + certificate provisioning headlessly in the
/// built-in SideStore, feeding it the given credentials and a machine-anisette
/// snapshot (keys per LCProvisioningBridge) produced by LiveContainer's App
/// Store login stack. The completion returns the signing certificate (PKCS#12)
/// and its password on success, or an error message on failure.
///
/// SideStore's developer-portal (GSA) login is separate from the App Store
/// login and sends its own 2FA code, so the App Store code can't be reused.
/// When it needs one, `verificationCodeProvider` is called (on any queue) with
/// an optional error message from a previous failed attempt; call `reply` once
/// with the code, or nil to cancel.
- (void)provisionCertificateWithEmail:(NSString *)email
                             password:(NSString *)password
                                 code:(nullable NSString *)code
                             anisette:(NSDictionary<NSString *, NSString *> *)anisette
             verificationCodeProvider:(void (^)(NSString * _Nullable message,
                                                void (^reply)(NSString * _Nullable code)))verificationCodeProvider
                           completion:(void (^)(NSData * _Nullable certificate,
                                                NSString * _Nullable password,
                                                NSString * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END

#endif /* LCCertificateProvisioning_h */
