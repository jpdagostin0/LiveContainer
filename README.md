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
build/. After packaging, the app's post_build steps run:

1. build-support/embed-sidestore.sh embeds SideStore. Pick the SideStore
   build with `SIDESTORE_IPA=/path/to/SideStore.ipa idl build`. The default is
   SideStore/SideStore.ipa, falling back to the upstream LiveContainer/SideStore
   nightly.
2. build-support/install-on-device.sh (install_on_device) installs
   LiveContainer+SideStore.ipa through Jimpactor when it is running and
   reports a connected device; otherwise it skips. Choose a device with
   `IDL_DEVICE=<udid|name>`, or disable it with `IDL_NO_INSTALL=1`.

`idl build --no-post-build` skips both.

Code quality (idl orchestrates the tools; configs come from the `lint:` and
`format:` sections of idlproj.yml, which exclude vendored code):

    idl lint [--analyze] [-q]   # clang -Wall, swiftc warnings, clang-tidy (if installed)
    idl fmt --check             # clang-format + swift-format (report only)
    idl test                    # bundle checks: Mach-O platform/signing, @rpath resolution, plists

The app icon is generated: `python3 build-support/make-icon.py` (Pillow)
rewrites Resources/Assets.xcassets/AppIcon.appiconset and the AppIconGrey PNGs.

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
    Resources/              bundle resources, strings, app icon (Assets.xcassets), CydiaSubstrate
    OpenSSL/ litehook/      submodules
    build-support/          embed-sidestore.sh, install-on-device.sh, make-icon.py,
                            dylibify.py, sidelc/, ViewAppIntent.swift,
                            include/openssl (case-sensitive OpenSSL header shim)
    idlproj.yml, entitlements.xml
    SideStore/              SideStore fork (separate git repo, built on macOS; ignored here)

License: AGPL-3.0 (see LICENSE).
