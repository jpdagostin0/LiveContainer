//
//  XPCServer.h
//  LiveContainer
//
//  Created by s s on 2025/7/20.
//

#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>

NS_ASSUME_NONNULL_BEGIN

__attribute__((swift_attr("@Sendable")))
@protocol RefreshServer
- (void)updateProgress:(double)value;
- (void)finish:(NSString* _Nullable)error;
- (void)onConnection:(NSXPCConnection*)connection;
- (void)finishedLaunching;
- (void)addNotificationRequest:(UNNotificationRequest*)request;
- (void)removePendingNotificationRequestsWithIdentifiers:(NSArray<NSString*>*)identifiers;
@end

@protocol RefreshClient
- (void)refreshAllAppsWithIdentifier:(NSString*)identifier mangledTypeName:(NSString*)mangledTypeName;
// Headless certificate provisioning: runs SideStore's sign-in + cert pipeline
// in the guest using the supplied credentials and machine-anisette snapshot
// (keys per LCProvisioningBridge), replying with the signing certificate.
- (void)provisionCertificateWithAppleID:(NSString*)appleID
                               password:(NSString*)password
                                   code:(NSString* _Nullable)code
                               anisette:(NSDictionary<NSString*, NSString*>*)anisette
                                  reply:(void (^)(NSData* _Nullable certificate, NSString* _Nullable password, NSString* _Nullable error))reply;
@end

@interface LiveProcessSideStoreHandler : NSObject
@property(class, readonly, strong) LiveProcessSideStoreHandler* shared;
@property(nullable) NSXPCConnection* connection;
@property(nullable) NSObject<RefreshServer>* server;

@end

NSXPCListener* _Nullable startAnonymousListener(NSObject<RefreshServer>* reporter);
NSData* _Nullable bookmarkForURL(NSURL* url);
// RefreshClient interface with the provisioning anisette-dictionary argument
// classes whitelisted for NSXPC. Used for both the guest's exportedInterface
// and the host's remoteObjectInterface.
NSXPCInterface* RefreshClientInterface(void);

void installSideStoreHooks(void);
void installSideStoreNotificationHooks(void);

@interface SideStoreClient : NSObject <RefreshClient>
@property(class, readonly) SideStoreClient* shared;
- (void)relaunchLC;
@end

NS_ASSUME_NONNULL_END
