//
//  LCAppStoreSigner.m
//  LiveContainerSwiftUI
//

#import "LCAppStoreSigner.h"
#import <dlfcn.h>
#import <IOKit/IOKitLib.h>

@implementation LCAppStoreSignerProbeResult
@end

// AppleMediaServices classes the native login/download path relies on. These are
// the same symbols the Go ipatool emulator drives inside Unicorn; here we look
// for the real ones in-process. Names mirror internal/store/emulator/*.go.
static NSArray<NSString *> *LCAMSExpectedClasses(void) {
    return @[
        @"AMSAnisette",            // Store AMD / anisette machine proof
        @"AMSURLRequest",          // signed Store request object
        @"AMSURLRequestEncoder",   // builds + signs authenticate/download requests
        @"AMSBagNetworkDataSource",// fetches the Store bag (endpoints + SAP config)
        @"AMSVerifyCredentialsTask",// authenticate request builder
    ];
}

// Only the two Store AMD proof headers are identity-sensitive; we report their
// presence + length, never their contents.
static NSArray<NSString *> *LCAMSProofHeaderNames(void) {
    return @[ @"X-Apple-AMD", @"X-Apple-AMD-M" ];
}

static void LCAMSLog(NSMutableArray<NSString *> *diagnostics, NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (line) {
        [diagnostics addObject:line];
    }
}

// Invoke +[AMSAnisette _headersForRequest:account:type:] by reflection so the
// probe compiles and degrades without AppleMediaServices headers, and never
// crashes if the selector is absent or throws. Returns the proof dictionary or
// nil. type 2 == the Configurator Store AMD proof (not AuthKit's I-MD proof).
static NSDictionary *LCAMSCopyStoreAMDHeaders(Class anisetteClass,
                                              NSMutableArray<NSString *> *diagnostics) {
    SEL selector = NSSelectorFromString(@"_headersForRequest:account:type:");
    if (![anisetteClass respondsToSelector:selector]) {
        LCAMSLog(diagnostics, @"AMSAnisette does not expose _headersForRequest:account:type: on this OS.");
        return nil;
    }

    NSMethodSignature *signature = [anisetteClass methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments != 5 ||
        strcmp(signature.methodReturnType, @encode(id)) != 0) {
        LCAMSLog(diagnostics, @"AMSAnisette proof selector has an unexpected signature; skipping.");
        return nil;
    }

    @try {
        NSURLRequest *request = [NSURLRequest requestWithURL:
            [NSURL URLWithString:@"https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate"]];
        id account = nil;
        NSInteger type = 2;

        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
        invocation.target = anisetteClass;
        invocation.selector = selector;
        [invocation setArgument:&request atIndex:2];
        [invocation setArgument:&account atIndex:3];
        [invocation setArgument:&type atIndex:4];
        [invocation invoke];

        void *rawResult = NULL;
        [invocation getReturnValue:&rawResult];
        id result = (__bridge id)rawResult;
        if ([result isKindOfClass:NSDictionary.class]) {
            return result;
        }
        LCAMSLog(diagnostics, @"AMSAnisette returned no proof dictionary (got %@).",
                 result ? NSStringFromClass([result class]) : @"nil");
        return nil;
    } @catch (NSException *exception) {
        // A raised exception here is the common "not entitled / no identity" outcome.
        LCAMSLog(diagnostics, @"AMSAnisette proof generation was refused: %@ (%@).",
                 exception.name, exception.reason ?: @"no reason");
        return nil;
    }
}

// FairPlay IOKit service names to probe, in priority order.
// adid communicates with FairPlay via IOKit (IOConnectCallStructMethod), not XPC.
// These names come from iOS security research and the FairPlayIOKit kext used by
// the Go ipatool emulator.
static NSArray<NSString *> *LCFairPlayServiceNames(void) {
    return @[
        @"IOMobileAppleHardwareDecryption",  // classic iOS FairPlay IOKit service
        @"FairPlayIOKit",                    // kext class name in Go ipatool assets
        @"AppleFairPlay",                    // alternative seen in some builds
    ];
}

@implementation LCAppStoreSigner

+ (LCAppStoreSignerProbeResult *)runProbe {
    LCAppStoreSignerProbeResult *result = [LCAppStoreSignerProbeResult new];
    NSMutableArray<NSString *> *diagnostics = [NSMutableArray array];

    // 1. Load AppleMediaServices. It is a private framework, so link at runtime.
    const char *amsPath =
        "/System/Library/PrivateFrameworks/AppleMediaServices.framework/AppleMediaServices";
    void *handle = dlopen(amsPath, RTLD_LAZY);
    result.frameworkLoaded = handle != NULL;
    if (handle) {
        LCAMSLog(diagnostics, @"Loaded AppleMediaServices.");
    } else {
        const char *err = dlerror();
        LCAMSLog(diagnostics, @"Could not load AppleMediaServices: %s", err ? err : "unknown error");
    }

    // 2. Census the classes the native signing path needs.
    NSMutableArray<NSString *> *present = [NSMutableArray array];
    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    for (NSString *name in LCAMSExpectedClasses()) {
        if (NSClassFromString(name)) {
            [present addObject:name];
        } else {
            [missing addObject:name];
        }
    }
    result.presentClasses = present;
    result.missingClasses = missing;
    LCAMSLog(diagnostics, @"AMS classes present: %lu/%lu.",
             (unsigned long)present.count,
             (unsigned long)LCAMSExpectedClasses().count);

    // 3. The decisive capability: can we obtain a Store AMD anisette proof?
    //    This exercises CoreADI machine identity, which is what requires privilege.
    Class anisetteClass = NSClassFromString(@"AMSAnisette");
    NSMutableDictionary<NSString *, NSNumber *> *headerLengths = [NSMutableDictionary dictionary];
    if (anisetteClass) {
        NSDictionary *headers = LCAMSCopyStoreAMDHeaders(anisetteClass, diagnostics);
        BOOL complete = headers != nil;
        for (NSString *name in LCAMSProofHeaderNames()) {
            id value = headers[name];
            if ([value isKindOfClass:NSString.class] && [(NSString *)value length] > 0) {
                headerLengths[name] = @([(NSString *)value lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
            } else {
                complete = NO;
            }
        }
        result.anisetteProofProduced = complete;
        if (complete) {
            LCAMSLog(diagnostics, @"Obtained a complete Store AMD proof (%@).",
                     [LCAMSProofHeaderNames() componentsJoinedByString:@" + "]);
        } else {
            LCAMSLog(diagnostics, @"Store AMD proof is missing or incomplete on this device.");
        }
    } else {
        LCAMSLog(diagnostics, @"AMSAnisette is unavailable; cannot test native signing.");
    }
    result.anisetteHeaderLengths = headerLengths;

    // 4. Lightweight check that the request-building class can be instantiated.
    Class encoderClass = NSClassFromString(@"AMSURLRequestEncoder");
    result.requestEncoderAvailable = NO;
    if (encoderClass) {
        @try {
            id encoder = [encoderClass alloc];
            result.requestEncoderAvailable = encoder != nil;
        } @catch (NSException *exception) {
            LCAMSLog(diagnostics, @"AMSURLRequestEncoder could not be allocated: %@.", exception.name);
        }
    }

    // 5. FairPlay IOKit probe.
    //    adid communicates with FairPlay via IOKit (IOConnectCallStructMethod),
    //    not XPC. Check whether this process can open the FairPlay user client
    //    without a special entitlement.
    result.fairPlayIOKitOpenResult = -1; // sentinel: no matching service found
    for (NSString *name in LCFairPlayServiceNames()) {
        io_service_t service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching(name.UTF8String));
        if (service == IO_OBJECT_NULL) {
            LCAMSLog(diagnostics, @"FairPlay IOKit: no match for \"%@\".", name);
            continue;
        }
        LCAMSLog(diagnostics, @"FairPlay IOKit: matched service \"%@\" (entry 0x%x).", name, service);
        result.fairPlayIOKitServiceName = name;
        io_connect_t connection = IO_OBJECT_NULL;
        kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &connection);
        result.fairPlayIOKitOpenResult = (int)kr;
        if (kr == KERN_SUCCESS) {
            LCAMSLog(diagnostics, @"FairPlay IOKit: IOServiceOpen succeeded (connection 0x%x) — "
                     "IOKit path is available without a system entitlement.", connection);
            IOServiceClose(connection);
        } else {
            LCAMSLog(diagnostics, @"FairPlay IOKit: IOServiceOpen returned 0x%x.", (unsigned)kr);
        }
        IOObjectRelease(service);
        break; // stop at the first matched name
    }
    if (result.fairPlayIOKitServiceName == nil) {
        LCAMSLog(diagnostics, @"FairPlay IOKit: no candidate service found on this device.");
    }

    // Verdict. Native signing is viable only if the AMD proof is actually produced;
    // class presence alone does not prove the identity daemon will serve us.
    result.nativeSigningViable = result.anisetteProofProduced;
    if (result.nativeSigningViable) {
        result.summary = @"Native App Store signing is available on this device.";
    } else if (!result.frameworkLoaded) {
        result.summary = @"AppleMediaServices is not loadable in this process.";
    } else if (result.missingClasses.count == LCAMSExpectedClasses().count) {
        result.summary = @"AppleMediaServices loaded but exposes none of the expected classes.";
    } else {
        result.summary = @"AppleMediaServices is present but would not sign a Store request here "
                          "(no machine-identity proof). Native login is not viable without a system entitlement.";
    }

    result.diagnostics = diagnostics;
    // Intentionally leave `handle` open: unloading a system framework mid-process
    // is unsafe, and these frameworks persist for the app's lifetime anyway.
    return result;
}

@end
