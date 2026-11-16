# LiveContainer — Linux build (no Xcode) using the Darwin SDK installed by xtool.
#
#   make            build build/LiveContainer.ipa
#   make app        build build/Payload/LiveContainer.app only
#   make clean
#
# Requirements: swiftly Swift toolchain (swiftc/clang), `xtool setup` done
# (Darwin SDK in ~/.swiftpm/swift-sdks/darwin.artifactbundle), python3, zip.
# ldid is downloaded into build/tools if it's not on PATH.
#
# This mirrors the Xcode project's targets (LiveContainer.xcodeproj). Things
# that need macOS-only Xcode tools are handled as follows:
#   - Assets.xcassets (actool)          -> not compiled; named colors fall back
#                                          to the code's defaults, no app icon
#   - Localizable.xcstrings             -> build-support/lcbuild.py xcstrings
#   - ViewApp.intentdefinition          -> build-support/ViewAppIntent.swift
#   - LaunchScreen storyboard           -> UILaunchScreen dict in Info.plist
#   - AppIntents metadata (LaunchAppExtension) -> not generated

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
DARWIN_SDK_BUNDLE ?= $(HOME)/.swiftpm/swift-sdks/darwin.artifactbundle
SDK      ?= $(firstword $(wildcard $(DARWIN_SDK_BUNDLE)/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS[0-9]*.sdk))
SWIFT_RESOURCE_DIR ?= $(DARWIN_SDK_BUNDLE)/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift
PLATFORM_LIB_DIR   ?= $(DARWIN_SDK_BUNDLE)/Developer/Platforms/iPhoneOS.platform/Developer/usr/lib
LD64     ?= $(DARWIN_SDK_BUNDLE)/toolset/bin/orig/ld64.lld
# compiler-rt builtins (__isPlatformVersionAtLeast for @available, ...)
CLANG_RT ?= $(firstword $(wildcard $(DARWIN_SDK_BUNDLE)/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang/*/lib/darwin/libclang_rt.ios.a))

MAKEFLAGS += -r
.DEFAULT_GOAL := all
# swiftly's toolchain (also provides a clang that can target Darwin)
SWIFTLY_BIN ?= $(HOME)/.local/share/swiftly/bin
export PATH := $(PATH):$(SWIFTLY_BIN)
ifeq ($(origin CC),default)
CC       := clang
endif
ifeq ($(origin CXX),default)
CXX      := clang++
endif
SWIFTC   ?= swiftc
PYTHON   ?= python3
ZIP      ?= zip

TEAM_ID          ?= AAAAA11111
BUNDLE_ID        ?= com.kdt.livecontainer
MARKETING_VERSION ?= $(shell $(PYTHON) -c "import plistlib;print(plistlib.load(open('LiveContainer/Info.plist','rb'))['CFBundleShortVersionString'])")
CONFIGURATION    ?= Release
# The plain LiveContainer.ipa from CI ships without SideStoreSupport.framework
INCLUDE_SIDESTORE ?= 0

GIT_BRANCH := $(shell git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)
GIT_COMMIT := $(shell git log -1 --format=%h 2>/dev/null || echo unknown)

BUILD    := build
OBJ      := $(BUILD)/obj
PRODUCTS := $(BUILD)/products
APP      := $(BUILD)/Payload/LiveContainer.app
IPA      := $(BUILD)/LiveContainer.ipa
MODCACHE := $(abspath $(BUILD)/ModuleCache)

# ---------------------------------------------------------------------------
# Tools / flags
# ---------------------------------------------------------------------------
ARCH := arm64
comma := ,
triple = $(ARCH)-apple-ios$(1)

# Xcode's header map makes every project header reachable by bare name.
HEADER_DIRS := $(sort $(dir $(shell find LiveContainer LiveContainerSwiftUI MultitaskSupport TweakLoader \
                 ZSign TestJITLess LiveProcess SideStoreSupport LaunchAppExtension ShareExtension \
                 litehook/src litehook/external/include -name '*.h' -o -name '*.hpp')))
IQUOTE := $(addprefix -iquote ,$(patsubst %/,%,$(HEADER_DIRS)))

OPT        ?= -Os
WARNFLAGS  ?= -w
COMMON_CFLAGS = -isysroot $(SDK) $(OPT) -g0 $(WARNFLAGS) -fmodules -fmodules-cache-path=$(MODCACHE) \
                -fobjc-arc -fobjc-weak -fno-common -DNS_BLOCK_ASSERTIONS=1 \
                -I$(OBJ)/include $(IQUOTE) -MMD -MP
CFLAGS_C   = -std=gnu17
CFLAGS_CXX = -std=gnu++20 -stdlib=libc++

SWIFT_WARN ?= -suppress-warnings
SWIFT_COMMON = -sdk $(SDK) -resource-dir $(SWIFT_RESOURCE_DIR) -I $(PLATFORM_LIB_DIR) -L $(PLATFORM_LIB_DIR) \
               -module-cache-path $(MODCACHE) -O -wmo -num-threads 0 $(SWIFT_WARN) \
               -Xcc -fmodules-cache-path=$(MODCACHE) $(addprefix -Xcc ,$(IQUOTE)) -Xcc -I$(OBJ)/include \
               -Xcc -DNS_BLOCK_ASSERTIONS=1

LDFLAGS_COMMON = -isysroot $(SDK) -fuse-ld=lld --ld-path=$(LD64) -Wl,-dead_strip \
                 -Wl,-headerpad_max_install_names $(CLANG_RT)
SWIFT_LDFLAGS  = -sdk $(SDK) -resource-dir $(SWIFT_RESOURCE_DIR) -L $(PLATFORM_LIB_DIR) \
                 -use-ld=lld -ld-path=$(LD64) -Xlinker -dead_strip -Xlinker -headerpad_max_install_names \
                 -Xlinker $(CLANG_RT)
# lld warns on every link that iOS is "unsupported"; xtool uses it the same way
LD_FILTER = 2>&1 | grep -v "does not support linking for platform iOS" >&2; test $${PIPESTATUS[0]} -eq 0
SHELL := /bin/bash

# ldid (signing + entitlements)
LDID ?= $(shell command -v ldid 2>/dev/null || echo $(BUILD)/tools/ldid)
LDID_URL := https://github.com/ProcursusTeam/ldid/releases/download/v2.1.5-procursus7/ldid_linux_$(shell uname -m)

LCBUILD := $(PYTHON) build-support/lcbuild.py

# ---------------------------------------------------------------------------
# Generic per-target object rules
#   $(1) = target name, sources in $(1)_SRCS, flags in $(1)_CFLAGS,
#   deployment target in $(1)_MIN, extra order-only deps in $(1)_DEPS
# ---------------------------------------------------------------------------
define objects
$(1)_OBJS := $$(patsubst %,$(OBJ)/$(1)/%.o,$$($(1)_SRCS))
$$(filter %.c.o,$$($(1)_OBJS)): $(OBJ)/$(1)/%.c.o: %.c | $$($(1)_DEPS)
	@mkdir -p $$(@D); echo "  CC    [$(1)] $$<"
	@$(CC) -target $$(call triple,$$($(1)_MIN)) $$(COMMON_CFLAGS) $$(CFLAGS_C) $$($(1)_CFLAGS) -c $$< -o $$@
$$(filter %.m.o,$$($(1)_OBJS)): $(OBJ)/$(1)/%.m.o: %.m | $$($(1)_DEPS)
	@mkdir -p $$(@D); echo "  OBJC  [$(1)] $$<"
	@$(CC) -target $$(call triple,$$($(1)_MIN)) $$(COMMON_CFLAGS) $$(CFLAGS_C) $$($(1)_CFLAGS) -x objective-c -c $$< -o $$@
$$(filter %.cpp.o,$$($(1)_OBJS)): $(OBJ)/$(1)/%.cpp.o: %.cpp | $$($(1)_DEPS)
	@mkdir -p $$(@D); echo "  CXX   [$(1)] $$<"
	@$(CXX) -target $$(call triple,$$($(1)_MIN)) $$(COMMON_CFLAGS) $$(CFLAGS_CXX) $$($(1)_CFLAGS) -c $$< -o $$@
$$(filter %.mm.o,$$($(1)_OBJS)): $(OBJ)/$(1)/%.mm.o: %.mm | $$($(1)_DEPS)
	@mkdir -p $$(@D); echo "  OBJCXX[$(1)] $$<"
	@$(CXX) -target $$(call triple,$$($(1)_MIN)) $$(COMMON_CFLAGS) $$(CFLAGS_CXX) $$($(1)_CFLAGS) -x objective-c++ -c $$< -o $$@
-include $$($(1)_OBJS:.o=.d)
endef

# Whole-module Swift compile: one object + module + ObjC compat header.
#   $(1) = target, $(1)_SWIFT = sources, $(1)_MODULE = module name,
#   $(1)_SWIFTFLAGS = extra flags (bridging header, language mode, ...)
define swiftmodule
$(1)_SWIFT_OBJ := $(OBJ)/$(1)/swift/$$($(1)_MODULE).o
$(1)_SWIFT_HDR := $(OBJ)/include/$$($(1)_MODULE)-Swift.h
$$($(1)_SWIFT_OBJ) $$($(1)_SWIFT_HDR) &: $$($(1)_SWIFT) $$($(1)_SWIFT_EXTRA_DEPS)
	@mkdir -p $$(dir $$($(1)_SWIFT_OBJ)) $(OBJ)/include; echo "  SWIFT [$(1)] $$($(1)_MODULE) ($$(words $$($(1)_SWIFT)) files)"
	@$(SWIFTC) -target $$(call triple,$$($(1)_MIN)) $$(SWIFT_COMMON) -module-name $$($(1)_MODULE) \
	    -parse-as-library $$($(1)_SWIFTFLAGS) -c $$($(1)_SWIFT) -o $$($(1)_SWIFT_OBJ) \
	    -emit-objc-header-path $$($(1)_SWIFT_HDR) \
	    -emit-module-path $(OBJ)/$(1)/swift/$$($(1)_MODULE).swiftmodule
endef

# Generated framework / extension Info.plist (GENERATE_INFOPLIST_FILE=YES)
fw_plist = --default CFBundleDevelopmentRegion=en --default CFBundleExecutable=$(1) \
           --default CFBundleIdentifier=$(2) --default CFBundleInfoDictionaryVersion=6.0 \
           --default CFBundleName=$(1) --default CFBundlePackageType=$(3) \
           --default CFBundleShortVersionString=$(4) --default CFBundleVersion=$(5) \
           --set MinimumOSVersion=$(6) --set 'CFBundleSupportedPlatforms=["iPhoneOS"]' \
           --set 'UIDeviceFamily=[1,2]' --set DTPlatformName=iphoneos

# ---------------------------------------------------------------------------
# LiveContainerShared.framework  (target LiveContainerShared)
# ---------------------------------------------------------------------------
Shared_MIN    := 15.0
Shared_SRCS   := LiveContainer/dyld_bypass_validation.m LiveContainer/Localization.m \
                 LiveContainer/LCMachOUtils.m LiveContainer/LCSharedUtils.m \
                 LiveContainer/LCBootstrap.m LiveContainer/utils.m \
                 $(wildcard LiveContainer/Tweaks/*.m LiveContainer/Tweaks/*.c) \
                 litehook/src/litehook.c
Shared_CFLAGS := -fcommon -DFISHHOOK_EXPORT=1
$(eval $(call objects,Shared))
SHARED_FW := $(PRODUCTS)/LiveContainerShared.framework

$(SHARED_FW)/LiveContainerShared: $(Shared_OBJS)
	@mkdir -p $(@D); echo "  LINK  LiveContainerShared.framework"
	@$(CC) -target $(call triple,$(Shared_MIN)) $(LDFLAGS_COMMON) -dynamiclib $^ -o $@ \
	    -install_name @rpath/LiveContainerShared.framework/LiveContainerShared \
	    -Wl,-rpath,@executable_path/Frameworks -Wl,-rpath,@loader_path/Frameworks \
	    -framework Foundation -framework UIKit -framework Security $(LD_FILTER)
$(SHARED_FW)/Info.plist:
	@$(LCBUILD) plist -o $@ $(call fw_plist,LiveContainerShared,$(BUNDLE_ID).LiveContainerShared,FMWK,1.0,1,$(Shared_MIN))

# ---------------------------------------------------------------------------
# LiveContainerSwiftUI.framework  (target LiveContainerSwiftUI)
# ---------------------------------------------------------------------------
UI_MIN    := 15.0
UI_MODULE := LiveContainerSwiftUI
MULTITASK := AppSceneViewController.m DecoratedAppSceneViewController.m LCStatusBarManager.m \
             PiPManager.m ResizeHandleView.m UIKitHooks.m VirtualWindowsHostView.m
UI_SWIFT  := $(shell find LiveContainerSwiftUI -name '*.swift') \
             $(addprefix MultitaskSupport/,MultitaskAppWindow.swift MultitaskDockView.swift MultitaskManager.swift) \
             build-support/ViewAppIntent.swift
UI_SRCS   := $(shell find LiveContainerSwiftUI -name '*.m' -o -name '*.c') $(addprefix MultitaskSupport/,$(MULTITASK))
UI_BRIDGE := LiveContainerSwiftUI/LiveContainerSwiftUI-Bridging-Header.h
UI_DEFS   := -DCONFIG_TYPE=\"$(CONFIGURATION)\" -DCONFIG_BRANCH=\"$(GIT_BRANCH)\" -DCONFIG_COMMIT=\"$(GIT_COMMIT)\"
UI_CFLAGS := $(UI_DEFS)
UI_SWIFTFLAGS := -swift-version 5 -import-objc-header $(UI_BRIDGE) $(addprefix -Xcc ,$(UI_DEFS)) \
                 -I $(OBJ)/SAP/swift -I $(OBJ)/MAK/swift -I $(OBJ)/ASC/swift -F AppStoreAuth \
                 -I AppStoreAuth/NativeStore/include -Xcc -IAppStoreAuth/NativeStore/include
UI_SWIFT_EXTRA_DEPS := $(UI_BRIDGE)
$(eval $(call swiftmodule,UI))
UI_DEPS   := $(UI_SWIFT_HDR)
$(eval $(call objects,UI))
UI_FW := $(PRODUCTS)/LiveContainerSwiftUI.framework

$(UI_FW)/LiveContainerSwiftUI: $(UI_SWIFT_OBJ) $(UI_OBJS) $(SHARED_FW)/LiveContainerShared $(ASA_LINK_OBJS)
	@mkdir -p $(@D); echo "  LINK  LiveContainerSwiftUI.framework"
	@$(SWIFTC) -target $(call triple,$(UI_MIN)) $(SWIFT_LDFLAGS) -emit-library $(UI_SWIFT_OBJ) $(UI_OBJS) $(ASA_LINK_OBJS) -o $@ \
	    -Xlinker -install_name -Xlinker @rpath/LiveContainerSwiftUI.framework/LiveContainerSwiftUI \
	    -Xlinker -rpath -Xlinker @executable_path/Frameworks -Xlinker -rpath -Xlinker @loader_path/Frameworks \
	    -F $(PRODUCTS) -framework LiveContainerShared -framework IOKit -larchive -lz \
	    -F AppStoreAuth -framework MacADICore -framework Security -lc++ -lresolv -lcompression -lbz2 \
	    -Xlinker -U -Xlinker '_OBJC_CLASS_$$_RBSTarget' $(LD_FILTER)
$(UI_FW)/Info.plist:
	@$(LCBUILD) plist -o $@ $(call fw_plist,LiveContainerSwiftUI,com.kdtLiveContainerSwiftUI,FMWK,1.0,1,$(UI_MIN))

# ---------------------------------------------------------------------------
# SideStoreSupport.framework  (target SideStoreSupport)
# ---------------------------------------------------------------------------
SS_MIN    := 15.0
SS_MODULE := SideStoreSupport
SS_SWIFT  := $(wildcard SideStoreSupport/*.swift)
SS_SRCS   := $(wildcard SideStoreSupport/*.m)
SS_BRIDGE := SideStoreSupport/SideStore-Bridging-Header.h
SS_SWIFTFLAGS := -swift-version 5 -import-objc-header $(SS_BRIDGE) -enable-upcoming-feature MemberImportVisibility
SS_SWIFT_EXTRA_DEPS := $(SS_BRIDGE)
$(eval $(call swiftmodule,SS))
SS_DEPS   := $(SS_SWIFT_HDR)
$(eval $(call objects,SS))
SS_FW := $(PRODUCTS)/SideStoreSupport.framework

$(SS_FW)/SideStoreSupport: $(SS_SWIFT_OBJ) $(SS_OBJS) $(SHARED_FW)/LiveContainerShared
	@mkdir -p $(@D); echo "  LINK  SideStoreSupport.framework"
	@$(SWIFTC) -target $(call triple,$(SS_MIN)) $(SWIFT_LDFLAGS) -emit-library $(SS_SWIFT_OBJ) $(SS_OBJS) -o $@ \
	    -Xlinker -install_name -Xlinker @rpath/SideStoreSupport.framework/SideStoreSupport \
	    -Xlinker -rpath -Xlinker @executable_path/Frameworks -Xlinker -rpath -Xlinker @loader_path/Frameworks \
	    -F $(PRODUCTS) -framework LiveContainerShared $(LD_FILTER)
$(SS_FW)/Info.plist:
	@$(LCBUILD) plist -o $@ $(call fw_plist,SideStoreSupport,$(BUNDLE_ID).SideStoreSupport,FMWK,1.0,1,$(SS_MIN))

# ---------------------------------------------------------------------------
# Plain dylibs: TweakLoader, ZSign, TestJITLess
# ---------------------------------------------------------------------------
TL_MIN  := 15.0
TL_SRCS := $(addprefix TweakLoader/,BackgroundTasks.m DocumentPicker.m Notification.m TweakLoader.m UIKit+GuestHooks.m)
$(eval $(call objects,TL))
$(PRODUCTS)/TweakLoader.dylib: $(TL_OBJS)
	@mkdir -p $(@D); echo "  LINK  TweakLoader.dylib"
	@$(CC) -target $(call triple,$(TL_MIN)) $(LDFLAGS_COMMON) -dynamiclib $^ -o $@ \
	    -install_name @rpath/TweakLoader.dylib -framework Foundation -framework UIKit \
	    -Wl,-U,'_OBJC_CLASS_$$_FBSSceneParameters' -Wl,-U,'_OBJC_CLASS_$$_LSApplicationWorkspace' \
	    -Wl,-U,'_OBJC_CLASS_$$_DOCConfiguration' $(LD_FILTER)

OPENSSL_FW := OpenSSL/Frameworks/iphoneos/OpenSSL.framework
ZS_MIN    := 15.0
ZS_SRCS   := $(shell find ZSign -name '*.cpp' -o -name '*.mm')
# <openssl/x.h> only resolves into OpenSSL.framework/Headers on a
# case-insensitive filesystem; give Linux an explicit openssl/ include dir
ZS_CFLAGS := -fno-modules -F OpenSSL/Frameworks/iphoneos -I$(OBJ)/openssl-include
ZS_DEPS   := $(OBJ)/openssl-include/openssl
$(OBJ)/openssl-include/openssl:
	@mkdir -p $(@D) && ln -sfn $(abspath $(OPENSSL_FW))/Headers $@
$(eval $(call objects,ZS))
$(PRODUCTS)/ZSign.dylib: $(ZS_OBJS)
	@mkdir -p $(@D); echo "  LINK  ZSign.dylib"
	@$(CXX) -target $(call triple,$(ZS_MIN)) $(LDFLAGS_COMMON) -stdlib=libc++ -dynamiclib $^ -o $@ \
	    -install_name @rpath/ZSign.dylib -Wl,-rpath,@executable_path/Frameworks \
	    -F OpenSSL/Frameworks/iphoneos -framework OpenSSL -framework Foundation $(LD_FILTER)

TJ_MIN  := 15.0
TJ_SRCS := $(wildcard TestJITLess/*.m)
$(eval $(call objects,TJ))
$(PRODUCTS)/TestJITLess.dylib: $(TJ_OBJS)
	@mkdir -p $(@D); echo "  LINK  TestJITLess.dylib"
	@$(CC) -target $(call triple,$(TJ_MIN)) $(LDFLAGS_COMMON) -dynamiclib $^ -o $@ \
	    -install_name @rpath/TestJITLess.dylib -framework Foundation $(LD_FILTER)

# ---------------------------------------------------------------------------
# AppStore auth stack (ported from WaffleStore AnisetteKit)
#   MacADICore.framework : prebuilt static CoreADI (self-contained, incl Unicorn)
#   NativeStore          : ObjC, Apple Store AMD proof
#   SAPKit               : SAP signer / kbsync (Swift; drives Unicorn via MacADICore)
#   MacAnisetteKit       : CoreADI anisette wrapper (Swift)
# ---------------------------------------------------------------------------
ASA_DIR    := AppStoreAuth
ASA_F      := -F $(ASA_DIR)
ASA_NS_INC := -I$(ASA_DIR)/NativeStore/include

NS_MIN    := 15.0
NS_SRCS   := $(ASA_DIR)/NativeStore/NativeStore.m
NS_CFLAGS := $(ASA_NS_INC)
$(eval $(call objects,NS))

SAP_MIN    := 15.0
SAP_MODULE := SAPKit
SAP_SWIFT  := $(wildcard $(ASA_DIR)/SAPKit/*.swift)
SAP_SWIFTFLAGS := -swift-version 5 $(ASA_F)
$(eval $(call swiftmodule,SAP))

MAK_MIN    := 15.0
MAK_MODULE := MacAnisetteKit
MAK_SWIFT  := $(wildcard $(ASA_DIR)/MacAnisetteKit/*.swift)
MAK_SWIFTFLAGS := -swift-version 5 $(ASA_F) $(ASA_NS_INC) -Xcc $(ASA_NS_INC)
$(eval $(call swiftmodule,MAK))

ASC_MIN    := 15.0
ASC_MODULE := AppStoreCore
ASC_SWIFT  := $(wildcard $(ASA_DIR)/AppStoreCore/*.swift)
ASC_SWIFTFLAGS := -swift-version 5 $(ASA_F) $(ASA_NS_INC) -Xcc $(ASA_NS_INC) \
                  -I $(OBJ)/SAP/swift -I $(OBJ)/MAK/swift
ASC_SWIFT_EXTRA_DEPS := $(SAP_SWIFT_OBJ) $(MAK_SWIFT_OBJ)
$(eval $(call swiftmodule,ASC))

.PHONY: appstoreauth
appstoreauth: $(NS_OBJS) $(SAP_SWIFT_OBJ) $(MAK_SWIFT_OBJ) $(ASC_SWIFT_OBJ)
	@echo "  APPSTOREAUTH modules compiled (NativeStore, SAPKit, MacAnisetteKit, AppStoreCore)"

# Link the AppStore auth modules + MacADICore into LiveContainerSwiftUI.framework,
# and make its Swift compile (which imports them) wait for the modules.
ASA_LINK_OBJS := $(NS_OBJS) $(SAP_SWIFT_OBJ) $(MAK_SWIFT_OBJ) $(ASC_SWIFT_OBJ)
$(UI_FW)/LiveContainerSwiftUI: $(ASA_LINK_OBJS)
$(UI_SWIFT_OBJ): $(SAP_SWIFT_OBJ) $(MAK_SWIFT_OBJ) $(ASC_SWIFT_OBJ)

# ---------------------------------------------------------------------------
# App extensions
# ---------------------------------------------------------------------------
APPEX_RPATH := -Xlinker -rpath -Xlinker @executable_path/Frameworks -Xlinker -rpath -Xlinker @executable_path/../../Frameworks
APPEX_PLIST_VARS = --var PRODUCT_MODULE_NAME=$(1) --var EXECUTABLE_NAME=$(1) --var PRODUCT_NAME=$(1) \
                   --var PRODUCT_BUNDLE_IDENTIFIER=$(BUNDLE_ID).$(1) --var MARKETING_VERSION=$(2) \
                   --var CURRENT_PROJECT_VERSION=$(3)

# LiveProcess.appex (pure ObjC, provides its own NSExtensionMain)
LP_MIN  := 15.0
LP_SRCS := $(wildcard LiveProcess/*.m)
$(eval $(call objects,LP))
LP_APPEX := $(PRODUCTS)/LiveProcess.appex
$(LP_APPEX)/LiveProcess: $(LP_OBJS) $(SHARED_FW)/LiveContainerShared
	@mkdir -p $(@D); echo "  LINK  LiveProcess.appex"
	@$(CC) -target $(call triple,$(LP_MIN)) $(filter-out -Wl$(comma)-dead_strip,$(LDFLAGS_COMMON)) \
	    -fapplication-extension $(LP_OBJS) -o $@ -e _NSExtensionMain $(APPEX_RPATH) \
	    -F $(PRODUCTS) -framework LiveContainerShared -framework Foundation $(LD_FILTER)
LP_KEYS := NFCReaderUsageDescription NSAppleMusicUsageDescription NSBluetoothAlwaysUsageDescription \
  NSBluetoothPeripheralUsageDescription NSCameraUsageDescription NSContactsUsageDescription \
  NSFaceIDUsageDescription NSFallDetectionUsageDescription NSGKFriendListUsageDescription \
  NSHealthClinicalHealthRecordsShareUsageDescription NSHealthShareUsageDescription \
  NSHealthUpdateUsageDescription NSHomeKitUsageDescription NSIdentityUsageDescription \
  NSLocalNetworkUsageDescription NSLocationAlwaysAndWhenInUseUsageDescription \
  NSLocationTemporaryUsageDescriptionDictionary NSLocationUsageDescription \
  NSLocationWhenInUseUsageDescription NSMicrophoneUsageDescription NSMotionUsageDescription \
  NSNearbyInteractionAllowOnceUsageDescription NSNearbyInteractionUsageDescription \
  NSPhotoLibraryAddUsageDescription NSPhotoLibraryUsageDescription NSSensorKitUsageDescription \
  NSSiriUsageDescription NSSpeechRecognitionUsageDescription NSUserTrackingUsageDescription
$(LP_APPEX)/Info.plist: LiveProcess/Info.plist
	@$(LCBUILD) plist -i $< -o $@ $(call fw_plist,LiveProcess,$(BUNDLE_ID).LiveProcess,XPC!,1.0,1,$(LP_MIN)) \
	    --default CFBundleDisplayName=LiveProcess --default GCSupportsControllerUserInteraction=true \
	    --default GCSupportsGameMode=true \
	    $(foreach k,$(LP_KEYS),--default '$(k)=The guest app is requesting for this permission.')

# ShareExtension.appex (Swift + ObjC)
SE_MIN    := 16.0
SE_MODULE := ShareExtension
SE_SWIFT  := $(wildcard ShareExtension/*.swift)
SE_SRCS   := $(wildcard ShareExtension/*.m)
SE_BRIDGE := ShareExtension/ShareExtension-Bridging-Header.h
SE_SWIFTFLAGS := -swift-version 5 -import-objc-header $(SE_BRIDGE) -enable-upcoming-feature MemberImportVisibility \
                 -application-extension
SE_SWIFT_EXTRA_DEPS := $(SE_BRIDGE)
SE_CFLAGS := -fapplication-extension
$(eval $(call swiftmodule,SE))
SE_DEPS   := $(SE_SWIFT_HDR)
$(eval $(call objects,SE))
SE_APPEX := $(PRODUCTS)/ShareExtension.appex
$(SE_APPEX)/ShareExtension: $(SE_SWIFT_OBJ) $(SE_OBJS) $(SHARED_FW)/LiveContainerShared
	@mkdir -p $(@D); echo "  LINK  ShareExtension.appex"
	@$(SWIFTC) -target $(call triple,$(SE_MIN)) $(SWIFT_LDFLAGS) -emit-executable $(SE_SWIFT_OBJ) $(SE_OBJS) -o $@ \
	    -Xlinker -e -Xlinker _NSExtensionMain -Xlinker -application_extension $(APPEX_RPATH) \
	    -F $(PRODUCTS) -framework LiveContainerShared -framework Foundation $(LD_FILTER)
$(SE_APPEX)/Info.plist: ShareExtension/Info.plist
	@$(LCBUILD) plist -i $< -o $@ $(call APPEX_PLIST_VARS,ShareExtension,3.7.11,3.7.11) \
	    $(call fw_plist,ShareExtension,$(BUNDLE_ID).ShareExtension,XPC!,3.7.11,3.7.11,$(SE_MIN))

# LaunchAppExtension.appex (ExtensionKit / AppIntents, Swift @main + ObjC)
LA_MIN    := 16.0
LA_MODULE := LaunchAppExtension
LA_SWIFT  := $(wildcard LaunchAppExtension/*.swift)
LA_SRCS   := $(wildcard LaunchAppExtension/*.m)
LA_BRIDGE := LaunchAppExtension/LaunchAppExtension-Bridging-Header.h
LA_SWIFTFLAGS := -swift-version 5 -import-objc-header $(LA_BRIDGE) -enable-upcoming-feature MemberImportVisibility \
                 -application-extension
LA_SWIFT_EXTRA_DEPS := $(LA_BRIDGE)
LA_CFLAGS := -fapplication-extension
$(eval $(call swiftmodule,LA))
LA_DEPS   := $(LA_SWIFT_HDR)
$(eval $(call objects,LA))
LA_APPEX := $(PRODUCTS)/LaunchAppExtension.appex
$(LA_APPEX)/LaunchAppExtension: $(LA_SWIFT_OBJ) $(LA_OBJS) $(SHARED_FW)/LiveContainerShared
	@mkdir -p $(@D); echo "  LINK  LaunchAppExtension.appex"
	@$(SWIFTC) -target $(call triple,$(LA_MIN)) $(SWIFT_LDFLAGS) -emit-executable $(LA_SWIFT_OBJ) $(LA_OBJS) -o $@ \
	    -Xlinker -application_extension $(APPEX_RPATH) \
	    -F $(PRODUCTS) -framework LiveContainerShared $(LD_FILTER)
$(LA_APPEX)/Info.plist: LaunchAppExtension/Info.plist
	@$(LCBUILD) plist -i $< -o $@ $(call fw_plist,LaunchAppExtension,$(BUNDLE_ID).LaunchAppExtension,XPC!,1.0,1,$(LA_MIN)) \
	    --default CFBundleDisplayName=LaunchAppExtension

# ---------------------------------------------------------------------------
# LiveContainer (main executable: main.c only, entry _LiveContainerMainC)
# ---------------------------------------------------------------------------
LC_MIN  := 15.0
LC_SRCS := LiveContainer/main.c
$(eval $(call objects,LC))
$(PRODUCTS)/LiveContainer: $(LC_OBJS)
	@mkdir -p $(@D); echo "  LINK  LiveContainer"
	@$(CC) -target $(call triple,$(LC_MIN)) $(LDFLAGS_COMMON) $^ -o $@ \
	    -e _LiveContainerMainC -Wl,-rpath,@executable_path/Frameworks $(LD_FILTER)

# ---------------------------------------------------------------------------
# Resources, entitlements, bundle assembly
# ---------------------------------------------------------------------------
XCSTRINGS_OUT := $(BUILD)/strings
$(XCSTRINGS_OUT)/.stamp: Resources/Localizable.xcstrings build-support/lcbuild.py
	@echo "  STRINGS Localizable.xcstrings"; rm -rf $(XCSTRINGS_OUT)
	@$(LCBUILD) xcstrings $< $(XCSTRINGS_OUT) && touch $@

ENT_VARS := --var APP_GROUP_SIDESTORE=group.com.SideStore.SideStore --var APP_GROUP_ALTSTORE=group.com.rileytestut.AltStore \
            --var AppIdentifierPrefix=$(TEAM_ID). --var DEVELOPMENT_TEAM=$(TEAM_ID)
$(BUILD)/ent/LiveContainer.xml: entitlements.xml
	@$(LCBUILD) plist -i $< -o $@ $(ENT_VARS) --var PRODUCT_BUNDLE_IDENTIFIER=$(BUNDLE_ID)
define appex_ent
$(BUILD)/ent/$(1).xml: $(1)/$(1).entitlements
	@$$(LCBUILD) plist -i $$< -o $$@ $$(ENT_VARS) --var PRODUCT_BUNDLE_IDENTIFIER=$(BUNDLE_ID).$(1)
endef
$(foreach e,LiveProcess ShareExtension LaunchAppExtension,$(eval $(call appex_ent,$(e))))

$(BUILD)/tools/ldid:
	@mkdir -p $(@D); echo "  FETCH ldid"; curl -fsSL -o $@ $(LDID_URL) && chmod +x $@

FRAMEWORKS := $(SHARED_FW) $(UI_FW) $(if $(filter 1,$(INCLUDE_SIDESTORE)),$(SS_FW))
FW_BINS    := $(SHARED_FW)/LiveContainerShared $(SHARED_FW)/Info.plist \
              $(UI_FW)/LiveContainerSwiftUI $(UI_FW)/Info.plist \
              $(if $(filter 1,$(INCLUDE_SIDESTORE)),$(SS_FW)/SideStoreSupport $(SS_FW)/Info.plist)
DYLIBS     := $(PRODUCTS)/TweakLoader.dylib $(PRODUCTS)/ZSign.dylib $(PRODUCTS)/TestJITLess.dylib
APPEXES    := $(LP_APPEX) $(SE_APPEX) $(LA_APPEX)
APPEX_BINS := $(LP_APPEX)/LiveProcess $(LP_APPEX)/Info.plist $(SE_APPEX)/ShareExtension $(SE_APPEX)/Info.plist \
              $(LA_APPEX)/LaunchAppExtension $(LA_APPEX)/Info.plist
ENTS       := $(BUILD)/ent/LiveContainer.xml $(BUILD)/ent/LiveProcess.xml $(BUILD)/ent/ShareExtension.xml \
              $(BUILD)/ent/LaunchAppExtension.xml
# Regenerate plists and entitlements when the generator changes (its rules list the
# source plist first, so $< is unaffected).
$(filter %/Info.plist,$(FW_BINS) $(APPEX_BINS)) $(ENTS): build-support/lcbuild.py

APP_PLIST_ARGS := --var PRODUCT_BUNDLE_IDENTIFIER=$(BUNDLE_ID) \
    --set 'LCVersionInfo=$(CONFIGURATION) ($(GIT_BRANCH)/$(GIT_COMMIT))' \
    --set MinimumOSVersion=$(LC_MIN) --set 'CFBundleSupportedPlatforms=["iPhoneOS"]' \
    --set DTPlatformName=iphoneos --set CFBundleDevelopmentRegion=en \
    --delete UILaunchStoryboardName --delete UILaunchImageFile --delete UILaunchImages \
    --set 'UILaunchScreen={}' \
    --default UIApplicationSupportsIndirectInputEvents=true \
    --default 'UISupportedInterfaceOrientations~ipad=["UIInterfaceOrientationPortrait","UIInterfaceOrientationPortraitUpsideDown","UIInterfaceOrientationLandscapeLeft","UIInterfaceOrientationLandscapeRight"]'

.PHONY: all app ipa clean frameworks dylibs extensions
all: ipa
frameworks: $(FW_BINS)
dylibs: $(DYLIBS)
extensions: $(APPEX_BINS)

APP_STAMP := $(BUILD)/.app.stamp
app: $(APP_STAMP)
$(APP_STAMP): $(PRODUCTS)/LiveContainer $(FW_BINS) $(DYLIBS) $(APPEX_BINS) $(ENTS) \
               $(XCSTRINGS_OUT)/.stamp LiveContainer/Info.plist $(LDID) Makefile
	@echo "  APP   $(APP)"
	@rm -rf $(APP) && mkdir -p $(APP)/Frameworks $(APP)/PlugIns
	@cp $(PRODUCTS)/LiveContainer $(APP)/
	@$(LCBUILD) plist -i LiveContainer/Info.plist -o $(APP)/Info.plist $(APP_PLIST_ARGS)
	@printf 'APPL????' > $(APP)/PkgInfo
	@# resources (Resources/ folder members of the LiveContainer target)
	@cp -r Resources/Settings.bundle Resources/universal.js Resources/DefaultIcon.png \
	       Resources/AppIconGrey60x60@2x.png 'Resources/AppIconGrey76x76@2x~ipad.png' $(APP)/
	@cp -r $(XCSTRINGS_OUT)/*.lproj $(APP)/
	@cp -rn Resources/*.lproj $(APP)/ 2>/dev/null || true
	@for l in Resources/*.lproj; do cp -n $$l/* $(APP)/$$(basename $$l)/ 2>/dev/null || true; done
	@cp LiveContainerSwiftUI/ViewApp.intentdefinition $(APP)/
	@# embedded frameworks / dylibs (headers stripped like RemoveHeadersOnCopy)
	@cp -r $(FRAMEWORKS) $(APP)/Frameworks/
	@cp -r Resources/Frameworks/CydiaSubstrate.framework $(APP)/Frameworks/
	@cp -r $(OPENSSL_FW) $(APP)/Frameworks/
	@rm -rf $(APP)/Frameworks/*.framework/{Headers,Modules,_CodeSignature}
	@cp $(DYLIBS) $(APP)/Frameworks/
	@cp -r $(APPEXES) $(APP)/PlugIns/
	@echo "  SIGN  (ldid, ad-hoc + entitlements)"
	@for f in $(APP)/Frameworks/*.dylib $(APP)/Frameworks/*.framework; do $(LDID) -S $$f; done
	@for x in LiveProcess ShareExtension LaunchAppExtension; do \
	    $(LDID) -S$(BUILD)/ent/$$x.xml -I$(BUNDLE_ID).$$x $(APP)/PlugIns/$$x.appex/$$x || exit 1; done
	@$(LDID) -S$(BUILD)/ent/LiveContainer.xml -I$(BUNDLE_ID) $(APP)/LiveContainer
	@touch $@

ipa: $(IPA)
$(IPA): $(APP_STAMP)
	@echo "  IPA   $@"
	@rm -f $@ && cd $(BUILD) && $(ZIP) -qry $(notdir $@) Payload -x '*/.DS_Store'
	@ls -la $@

clean:
	rm -rf $(BUILD) build-idl

# ---------------------------------------------------------------------------
# idl hybrid: build + stage the dynamic components that idl's single-target
# `direct` builder can't express, so `idl build` can assemble the .app.
#   make stage && idl build   -> build-idl/LiveContainer.ipa
# idl builds the main.c bootstrap stub and bundles/signs/zips; this target
# produces the frameworks, dylibs, .appex extensions, the processed Info.plist,
# and the localized .lproj, laid out under build-idl/stage/.
# ---------------------------------------------------------------------------
IDL_STAGE := build-idl/stage
.PHONY: stage idl idl-postbundle
stage: $(FW_BINS) $(DYLIBS) $(APPEX_BINS) $(ENTS) $(XCSTRINGS_OUT)/.stamp LiveContainer/Info.plist $(LDID) Makefile
	@echo "  STAGE $(IDL_STAGE)"
	@rm -rf $(IDL_STAGE) build-idl/gen && mkdir -p $(IDL_STAGE)/Frameworks $(IDL_STAGE)/dylibs $(IDL_STAGE)/PlugIns $(IDL_STAGE)/lproj build-idl/gen
	@# idl bundles opaque .framework dirs (routed to Frameworks/) itself.
	@cp -r $(FRAMEWORKS) $(IDL_STAGE)/Frameworks/
	@cp -r Resources/Frameworks/CydiaSubstrate.framework $(IDL_STAGE)/Frameworks/
	@cp -r $(OPENSSL_FW) $(IDL_STAGE)/Frameworks/
	@rm -rf $(IDL_STAGE)/Frameworks/*.framework/{Headers,Modules,_CodeSignature}
	@# Loose dylibs + .appex extensions idl can't place; injected post-build.
	@cp $(DYLIBS) $(IDL_STAGE)/dylibs/
	@cp -r $(APPEXES) $(IDL_STAGE)/PlugIns/
	@echo "  SIGN  staged dylibs / frameworks / extensions (ldid)"
	@for f in $(IDL_STAGE)/Frameworks/*.framework $(IDL_STAGE)/dylibs/*.dylib; do $(LDID) -S $$f; done
	@for x in LiveProcess ShareExtension LaunchAppExtension; do \
	    $(LDID) -S$(BUILD)/ent/$$x.xml -I$(BUNDLE_ID).$$x $(IDL_STAGE)/PlugIns/$$x.appex/$$x || exit 1; done
	@# Processed app Info.plist for idl (strips the LaunchScreen storyboard key).
	@$(LCBUILD) plist -i LiveContainer/Info.plist -o build-idl/gen/Info.plist $(APP_PLIST_ARGS)
	@# Localized resources (xcstrings-generated + checked-in .lproj).
	@cp -r $(XCSTRINGS_OUT)/*.lproj $(IDL_STAGE)/lproj/ 2>/dev/null || true
	@cp -rn Resources/*.lproj $(IDL_STAGE)/lproj/ 2>/dev/null || true
	@for l in Resources/*.lproj; do cp -n $$l/* $(IDL_STAGE)/lproj/$$(basename $$l)/ 2>/dev/null || true; done
	@echo "  STAGE done -> $(IDL_STAGE)"

# Full idl build: stage components, let idl assemble + sign + zip, then inject
# the dylibs/appexes idl's resource model can't place and re-zip the IPA.
idl: stage
	@command -v idl >/dev/null || { echo "idl not on PATH"; exit 1; }
	idl build
	@$(MAKE) --no-print-directory idl-postbundle

IDL_APP := build-idl/Payload/LiveContainer.app
idl-postbundle:
	@echo "  INJECT dylibs -> $(IDL_APP)/Frameworks, extensions -> PlugIns"
	@cp $(IDL_STAGE)/dylibs/*.dylib $(IDL_APP)/Frameworks/
	@mkdir -p $(IDL_APP)/PlugIns && cp -r $(IDL_STAGE)/PlugIns/*.appex $(IDL_APP)/PlugIns/
	@cp -r $(IDL_STAGE)/lproj/*.lproj $(IDL_APP)/ 2>/dev/null || true
	@echo "  IPA   build-idl/LiveContainer.ipa (repacked)"
	@rm -f build-idl/LiveContainer.ipa && cd build-idl && $(ZIP) -qry LiveContainer.ipa Payload -x '*/.DS_Store'
	@ls -la build-idl/LiveContainer.ipa
