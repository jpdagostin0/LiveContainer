//
//  XPCClient.m
//  AltStore
//
//  Created by s s on 2025/7/20.
//  Copyright © 2025 SideStore. All rights reserved.
//
#include "XPCServer.h"
#include "../LiveContainer/utils.h"
#include "../LiveContainer/LCSharedUtils.h"
@import UIKit;

@interface SideStoreClient(Swift)
- (void)performRefreshForRealWithIdentifier:(NSString*)identifier
                            mangledTypeName:(NSString*)mangledTypeName
                                     server:(id <RefreshServer> _Nonnull)server;

@end

// Forward declaration of SideStore's LCProvisioningBridge (@objc), resolved at
// runtime from the SideStore binary. Declared on NSObject so we can message it
// without a compile-time dependency on the SideStore module.
@interface NSObject (LCProvisioningBridge)
- (void)provisionCertificateWithAppleID:(NSString*)appleID
                               password:(NSString*)password
                                   code:(NSString* _Nullable)code
                               anisette:(NSDictionary<NSString*,NSString*>*)anisette
                             completion:(void (^)(NSData* _Nullable certificate, NSString* _Nullable password, NSString* _Nullable error))completion;
@end

static LiveProcessSideStoreHandler* handler = nil;
void installSideStoreHooks(void);

@implementation SideStoreClient

+ (SideStoreClient*)shared {
    static SideStoreClient* sharedClient = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedClient = [SideStoreClient new];
    });

    return sharedClient;
}

+ (void)load {
    if(!NSUserDefaults.isSideStore) return;
    
    installSideStoreHooks();
    
    if(!NSUserDefaults.isLiveProcess) return;
    
    handler = [PrivClass(LiveProcessSideStoreHandler) shared];
    installSideStoreNotificationHooks();
    handler.connection.exportedInterface = RefreshClientInterface();
    handler.connection.exportedObject = SideStoreClient.shared;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appDidFinishLaunching:)
                                                 name:UIApplicationDidFinishLaunchingNotification
                                               object:nil];
}

// Implement the callback method
+ (void)appDidFinishLaunching:(NSNotification *)notification {
    NSDictionary *launchOptions = notification.userInfo;
    [handler.server finishedLaunching];
}

- (void) relaunchLC {
    [LCSharedUtils launchToGuestAppWithClassicMode:0];
}

- (void)refreshAllAppsWithIdentifier:(NSString*)identifier mangledTypeName:(NSString *)mangledTypeName {
    if(!handler) {
        return;
    }
    [self performRefreshForRealWithIdentifier:identifier mangledTypeName:mangledTypeName server:handler.server];
}

- (void)provisionCertificateWithAppleID:(NSString*)appleID
                               password:(NSString*)password
                                   code:(NSString*)code
                               anisette:(NSDictionary<NSString*,NSString*>*)anisette
                                  reply:(void (^)(NSData* _Nullable, NSString* _Nullable, NSString* _Nullable))reply {
    Class bridgeClass = PrivClass(LCProvisioningBridge);
    if(!bridgeClass) {
        reply(nil, nil, @"This SideStore build does not support LiveContainer certificate provisioning. Rebuild SideStore with LCProvisioningBridge.");
        return;
    }
    id bridge = [bridgeClass performSelector:@selector(shared)];
    if(!bridge) {
        reply(nil, nil, @"LCProvisioningBridge is unavailable.");
        return;
    }
    // The reply block must be invoked exactly once; the bridge calls completion
    // once on success or failure.
    [bridge provisionCertificateWithAppleID:appleID
                                   password:password
                                       code:code
                                   anisette:anisette
                                 completion:^(NSData* certificate, NSString* certPassword, NSString* error) {
        reply(certificate, certPassword, error);
    }];
}

@end
