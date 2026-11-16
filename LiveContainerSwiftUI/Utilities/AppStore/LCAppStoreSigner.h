//
//  LCAppStoreSigner.h
//  LiveContainerSwiftUI
//
//  On-device probe for Apple's native request-signing path (AppleMediaServices).
//
//  ipatool-ios used Apple's old Configurator/MZFinance login, which Apple has
//  retired: that endpoint now answers 301/HTML instead of a plist, surfacing in
//  the UI as "the data isn't in the correct format". The modern bag points login
//  at auth.itunes.apple.com/auth/v1/native, which requires an AMD/anisette
//  machine proof and a SAP X-Apple-ActionSignature. The Go ipatool produces those
//  by emulating macOS StoreServices in Unicorn; on a real device the same proofs
//  come from the system AppleMediaServices + CoreADI frameworks.
//
//  This probe checks, WITHOUT any Apple-private entitlement, whether those native
//  frameworks are reachable from inside LiveContainer and will emit a Store AMD
//  anisette proof. It never returns or logs the proof bytes — only their presence
//  and length — because they are device-identity secrets.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LCAppStoreSignerProbeResult : NSObject
/// AppleMediaServices.framework was found and dlopen'd.
@property(nonatomic) BOOL frameworkLoaded;
/// Expected Objective-C classes that are present / absent in this process.
@property(nonatomic, copy) NSArray<NSString *> *presentClasses;
@property(nonatomic, copy) NSArray<NSString *> *missingClasses;
/// +[AMSAnisette _headersForRequest:account:type:] returned a usable Store AMD proof.
@property(nonatomic) BOOL anisetteProofProduced;
/// Header name -> byte length only (never the value) for any proof headers seen.
@property(nonatomic, copy) NSDictionary<NSString *, NSNumber *> *anisetteHeaderLengths;
/// AMSURLRequestEncoder could be instantiated (request-building capability present).
@property(nonatomic) BOOL requestEncoderAvailable;
/// Overall verdict: is native signing viable here?
@property(nonatomic) BOOL nativeSigningViable;
/// FairPlay IOKit probe: name of the first service that could be matched (nil = none found).
@property(nonatomic, copy, nullable) NSString *fairPlayIOKitServiceName;
/// kern_return_t from IOServiceOpen on the matched FairPlay service (0 = KERN_SUCCESS).
@property(nonatomic) int fairPlayIOKitOpenResult;
/// One-line human summary and ordered diagnostic lines (safe to show to the user).
@property(nonatomic, copy) NSString *summary;
@property(nonatomic, copy) NSArray<NSString *> *diagnostics;
@end

@interface LCAppStoreSigner : NSObject

/// Runs the probe synchronously. Call off the main thread; it may perform an XPC
/// round-trip to the on-device identity daemon. Never throws.
+ (LCAppStoreSignerProbeResult *)runProbe NS_SWIFT_NAME(runProbe());

@end

NS_ASSUME_NONNULL_END
