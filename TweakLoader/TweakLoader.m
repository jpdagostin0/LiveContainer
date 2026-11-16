#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <string.h>
#include <objc/runtime.h>
#import "../LiveContainer/utils.h"

// ZSigner lives in LiveContainer's bundled ZSign.dylib; declared here so we can
// team-sign an unsigned/mis-signed tweak at load time without a compile-time dependency.
@interface NSObject (ZSigner)
+ (BOOL)signMachOAtPath:(NSString *)path bundleId:(NSString *)bundleId cert:(NSData *)key pass:(NSString *)pass error:(NSString **)errorOut;
@end

static NSString *lcBundlePath(void) {
    return NSUserDefaults.isLiveProcess
        ? NSUserDefaults.lcMainBundle.bundlePath.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent
        : NSUserDefaults.lcMainBundle.bundlePath;
}

// Resolve ZSigner, loading ZSign.dylib from the LiveContainer bundle if needed.
static Class zsignerClass(void) {
    Class cls = objc_lookUpClass("ZSigner");
    if (cls) return cls;
    NSString *zsignPath = [lcBundlePath() stringByAppendingPathComponent:@"Frameworks/ZSign.dylib"];
    dlopen(zsignPath.fileSystemRepresentation, RTLD_LAZY | RTLD_GLOBAL);
    return objc_lookUpClass("ZSigner");
}

// Sign a tweak Mach-O in place with the imported team certificate (the same one
// LiveContainer and guest apps are signed with), so library validation accepts it.
static BOOL teamSignTweak(NSString *machoPath, NSString **errorOut) {
    NSUserDefaults *nud = NSUserDefaults.lcSharedDefaults ?: NSUserDefaults.lcUserDefaults;
    NSData *cert = [nud objectForKey:@"LCCertificateData"];
    NSString *pass = [nud objectForKey:@"LCCertificatePassword"];
    if (![cert isKindOfClass:NSData.class] || ![pass isKindOfClass:NSString.class]) {
        *errorOut = @"no team certificate imported (import one in Settings to sign tweaks)";
        return NO;
    }
    Class zsigner = zsignerClass();
    if (!zsigner) {
        *errorOut = @"ZSign.dylib unavailable";
        return NO;
    }
    // Strip/fix arm64e slices first, same as the pre-launch signTweaks path.
    NSString *(*fixupARM64e)(const char *) = dlsym(RTLD_DEFAULT, "LCPatchMachOFixupARM64eSlice");
    if (fixupARM64e) fixupARM64e(machoPath.fileSystemRepresentation);
    return [zsigner signMachOAtPath:machoPath
                           bundleId:NSUserDefaults.lcMainBundle.bundleIdentifier ?: machoPath.lastPathComponent
                               cert:cert
                               pass:pass
                              error:errorOut];
}

static NSString *loadTweakAtURL(NSURL *url) {
    NSString *tweakPath = url.path;
    NSString *tweak = tweakPath.lastPathComponent;
    if (![tweakPath hasSuffix:@".dylib"] && ![tweakPath hasSuffix:@".framework"]) {
        return nil;
    }
    if ([tweakPath hasSuffix:@".framework"]) {
        NSURL* infoPlistURL = [url URLByAppendingPathComponent:@"Info.plist"];
        NSDictionary* infoDict = [NSDictionary dictionaryWithContentsOfURL:infoPlistURL];
        NSString* binary = infoDict[@"CFBundleExecutable"];
        if(!binary || ![binary isKindOfClass:NSString.class]) {
            return [NSString stringWithFormat:@"Unable to load %@: Unable to read Info.Plist", tweak];
        }
        tweakPath = [[url URLByAppendingPathComponent:binary] path];
    }
    
    void *handle = dlopen(tweakPath.UTF8String, RTLD_LAZY | RTLD_GLOBAL);
    if (handle) {
        NSLog(@"Loaded tweak %@", tweak);
        return nil;
    }
    // Snapshot the dlerror string immediately: it points to a static buffer that
    // the next dl* call (incl. loading ZSign below) clears/overwrites.
    const char *errorC = dlerror();
    NSString *dlErr = errorC ? @(errorC) : nil;

    // Tweaks must carry a signature from LiveContainer's team certificate to pass
    // library validation; sign it with that cert and retry.
    if (dlErr && ([dlErr.lowercaseString containsString:@"signature"] || [dlErr.lowercaseString containsString:@"not valid"]
                  || [dlErr.lowercaseString containsString:@"code sign"] || [dlErr.lowercaseString containsString:@"team"])) {
        NSLog(@"Tweak %@ failed to load (%@); re-signing with team certificate", tweak, dlErr);
        NSString *signErr = nil;
        if (teamSignTweak(tweakPath, &signErr)) {
            handle = dlopen(tweakPath.UTF8String, RTLD_LAZY | RTLD_GLOBAL);
            const char *retryC = dlerror();
            if (handle) {
                NSLog(@"Loaded tweak %@ after team-certificate signing", tweak);
                return nil;
            }
            if (retryC) dlErr = @(retryC);  // surface the retry's error instead
        } else {
            NSLog(@"Team-certificate signing of %@ failed: %@", tweak, signErr);
            dlErr = [NSString stringWithFormat:@"%@\n(signing %@ with team certificate failed: %@)", dlErr, tweak, signErr];
        }
    }

    if (dlErr) {
        NSLog(@"Error: %@", dlErr);
        return dlErr;
    } else {
        NSLog(@"Error: dlopen(%@): Unknown error because dlerror() returns NULL", tweak);
        return [NSString stringWithFormat:@"dlopen(%@): unknown error, handle is NULL", tweakPath];
    }
}

static void loadTweaksRecursively(NSURL *folderURL, NSMutableArray *errors) {
    NSArray<NSURL *> *items = [NSFileManager.defaultManager contentsOfDirectoryAtURL:folderURL includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:0 error:nil];
    for (NSURL *fileURL in items) {
        NSString *name = fileURL.lastPathComponent;
        if ([name hasSuffix:@".disabled"]) {
            NSLog(@"Skipping disabled tweak %@", name);
            continue;
        }
        NSNumber *isDirectory = nil;
        [fileURL getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
        // a .framework is a directory but loads as a single tweak
        if (isDirectory.boolValue && ![name hasSuffix:@".framework"]) {
            loadTweaksRecursively(fileURL, errors);
        } else {
            NSString *error = loadTweakAtURL(fileURL);
            if (error) {
                [errors addObject:error];
            }
        }
    }
}

static void showDlerrAlert(NSString *error) {
    UIWindow *window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Failed to load tweaks" message:error preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction* okAction = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        window.windowScene = nil;
    }];
    [alert addAction:okAction];
    UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"Copy" style:UIAlertActionStyleCancel handler:^(UIAlertAction * action) {
        UIPasteboard.generalPasteboard.string = error;
        window.windowScene = nil;
    }];
    [alert addAction:cancelAction];
    window.rootViewController = [UIViewController new];
    window.windowLevel = 1000;
    window.windowScene = (id)UIApplication.sharedApplication.connectedScenes.anyObject;
    [window makeKeyAndVisible];
    [window.rootViewController presentViewController:alert animated:YES completion:nil];
    objc_setAssociatedObject(alert, @"window", window, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

 __attribute__((constructor))
static void TweakLoaderConstructor() {
    const char *tweakFolderC = getenv("LC_GLOBAL_TWEAKS_FOLDER");
    NSString *globalTweakFolder = @(tweakFolderC);
    unsetenv("LC_GLOBAL_TWEAKS_FOLDER");
    const char *embeddedFolderC = getenv("LC_EMBEDDED_TWEAKS_FOLDER");
    NSString *embeddedTweakFolder = embeddedFolderC ? @(embeddedFolderC) : nil;
    unsetenv("LC_EMBEDDED_TWEAKS_FOLDER");
    BOOL isDir = NO;
    BOOL useEmbedded = embeddedTweakFolder && [NSFileManager.defaultManager fileExistsAtPath:embeddedTweakFolder isDirectory:&isDir] && isDir;
    
    if([NSUserDefaults.guestAppInfo[@"dontInjectTweakLoader"] boolValue]) {
        // don't load any tweak since tweakloader is loaded after all initializers
        NSLog(@"Skip loading tweaks");
        return;
    }
    
    NSMutableArray *errors = [NSMutableArray new];
    
    NSArray<NSURL *> *globalTweaks = [NSFileManager.defaultManager contentsOfDirectoryAtURL:[NSURL fileURLWithPath:globalTweakFolder]
    includingPropertiesForKeys:@[] options:0 error:nil];
    NSString *tweakFolderName = NSUserDefaults.guestAppInfo[@"LCTweakFolder"];
    
    if(!useEmbedded && [globalTweaks count] <= 1 && tweakFolderName.length == 0) {
        // nothing to load
        return;
    }

    // Load CydiaSubstrate
    const char *lcMainBundlePath;
    if(NSUserDefaults.isLiveProcess) {
        lcMainBundlePath = NSUserDefaults.lcMainBundle.bundlePath.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent.fileSystemRepresentation;
    } else {
        lcMainBundlePath = NSUserDefaults.lcMainBundle.bundlePath.fileSystemRepresentation;
    }
    char substratePath[PATH_MAX];
    snprintf(substratePath, sizeof(substratePath), "%s/Frameworks/CydiaSubstrate.framework/CydiaSubstrate", lcMainBundlePath);
    dlopen(substratePath, RTLD_LAZY | RTLD_GLOBAL);
    const char *substrateError = dlerror();
    if (substrateError) {
        [errors addObject:@(substrateError)];
    }

    if (useEmbedded) {
        // Team-signed copies embedded in the guest bundle by LCUtils.embedTweaks:
        // global tweaks first, then the app's tweak folder (same order as below).
        NSLog(@"Loading embedded tweaks from %@", embeddedTweakFolder);
        loadTweaksRecursively([NSURL fileURLWithPath:[embeddedTweakFolder stringByAppendingPathComponent:@"global"]], errors);
        loadTweaksRecursively([NSURL fileURLWithPath:[embeddedTweakFolder stringByAppendingPathComponent:@"app"]], errors);
    } else {
        // Load global tweaks
        NSLog(@"Loading tweaks from the global folder");

        for (NSURL *fileURL in globalTweaks) {
            NSString *name = fileURL.lastPathComponent;
            if ([name isEqualToString:@"TweakLoader.dylib"]) {
                // skip loading myself
                continue;
            }
            if ([name hasSuffix:@".disabled"]) {
                NSLog(@"Skipping disabled global tweak %@", name);
                continue;
            }
            NSString *error = loadTweakAtURL(fileURL);
            if (error) {
                [errors addObject:error];
            }
        }

        // Load selected tweak folder, recursively
        if (tweakFolderName.length > 0) {
            NSLog(@"Loading tweaks from the selected folder");
            NSString *tweakFolder = [globalTweakFolder stringByAppendingPathComponent:tweakFolderName];
            loadTweaksRecursively([NSURL fileURLWithPath:tweakFolder], errors);
        }

    }

    if (errors.count > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *error = [errors componentsJoinedByString:@"\n"];
            showDlerrAlert(error);
        });
    }
}
