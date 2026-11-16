# LiveContainer + SideStore (custom fork)

Fork of LiveContainer (https://github.com/LiveContainer/LiveContainer) with a
native App Store login/download/FairPlay-decrypt pipeline and an embedded
SideStore fork. Built on Linux with the Darwin SDK from `xtool setup`; no Xcode.

## Build

    git submodule update --init      # OpenSSL, litehook
    idl build                        # -> build/LiveContainer.ipa
                                     #    build/LiveContainer+SideStore.ipa

Everything is described in idlproj.yml: the app, its frameworks, dylibs,
extensions and the static App Store auth modules. `idl build <target>` builds
one target plus its dependencies; `idl list` shows them; `idl clean` removes
build/. After packaging, the app's post_build step (build-support/
embed-sidestore.sh) embeds SideStore. Pick the SideStore build with
`SIDESTORE_IPA=/path/to/SideStore.ipa idl build`. The default is
SideStore/SideStore.ipa, falling back to the upstream LiveContainer/SideStore
nightly.

Requirements: idl (~/projs/ios-dev-linux, with product-target support),
swiftly toolchain, `xtool setup` (Darwin SDK), ldid, python3, zip.

## Layout

    LiveContainer/          LiveContainerShared.framework + main.c bootstrap
    LiveContainerSwiftUI/   UI framework (incl. App Store + FairPlay pipeline)
    AppStoreAuth/           vendored App Store auth stack (CoreADI, SAP, anisette)
    MultitaskSupport/       multitask windows (linked into the UI framework)
    SideStoreSupport/       framework injected into the built-in SideStore
    TweakLoader/ ZSign/ TestJITLess/   dylibs
    LiveProcess/ ShareExtension/ LaunchAppExtension/   app extensions
    Resources/              bundle resources, strings, CydiaSubstrate
    OpenSSL/ litehook/      submodules
    build-support/          embed-sidestore.sh, dylibify.py, sidelc/, ViewAppIntent.swift,
                            include/openssl (case-sensitive OpenSSL header shim)
    idlproj.yml, entitlements.xml
    SideStore/              SideStore fork (separate git repo, built on macOS; ignored here)

License: AGPL-3.0 (see LICENSE).
