#!/usr/bin/env bash
#
# embed-sidestore.sh — Linux port of .github/build_github.sh's SideStore embed.
#
# Runs as the LiveContainer target's idl post_build step: takes the standalone
# LiveContainer build (build/LiveContainer.ipa) plus a SideStore .ipa, and
# produces LiveContainer+SideStore.ipa next to it:
# SideStore.app is dylibified into Frameworks/SideStoreApp.framework, its intents
# metadata/widget are wired in, and the SideStore Info.plist / Settings keys are
# added — so `sideStoreExist` is true and the built-in SideStore can launch.
#
# Vars:
#   LC_IPA        standalone LiveContainer ipa     (default $IDL_IPA, else build/LiveContainer.ipa)
#   SIDESTORE_IPA SideStore ipa to embed           (default: SideStore/SideStore.ipa, else download nightly)
#   OUT           output ipa                        (default <LC_IPA dir>/LiveContainer+SideStore.ipa)
#
# Use your own SideStore *fork* build (with LCProvisioningBridge) via SIDESTORE_IPA
# to get working certificate provisioning; the nightly only proves the pipeline.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
LC_IPA="${LC_IPA:-${IDL_IPA:-$REPO/build/LiveContainer.ipa}}"
OUT="${OUT:-$(dirname "$LC_IPA")/LiveContainer+SideStore.ipa}"
DYLIBIFY="$REPO/build-support/dylibify.py"
SIDELC="$REPO/build-support/sidelc"

command -v ldid >/dev/null || { echo "[!] ldid not found"; exit 1; }
[ -f "$LC_IPA" ] || { echo "[!] LC_IPA not found: $LC_IPA (run 'idl build' first)"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- resolve SideStore ipa ---
if [ -z "${SIDESTORE_IPA:-}" ]; then
    if [ -f "$REPO/SideStore/SideStore.ipa" ]; then
        SIDESTORE_IPA="$REPO/SideStore/SideStore.ipa"
    else
        echo "[*] No SIDESTORE_IPA given; downloading LiveContainer/SideStore nightly"
        SIDESTORE_IPA="$WORK/SideStore.ipa"
        wget -q https://github.com/LiveContainer/SideStore/releases/download/nightly/SideStore.ipa -O "$SIDESTORE_IPA"
    fi
fi
echo "[*] Embedding SideStore from: $SIDESTORE_IPA"

# --- unpack LiveContainer ---
unzip -oq "$LC_IPA" -d "$WORK/lc"
APP="$WORK/lc/Payload/LiveContainer.app"
[ -d "$APP" ] || { echo "[!] LiveContainer.app not found in $LC_IPA"; exit 1; }

# --- unpack SideStore ---
unzip -oq "$SIDESTORE_IPA" -d "$WORK/ss"
SSAPP="$WORK/ss/Payload/SideStore.app"
[ -d "$SSAPP" ] || { echo "[!] SideStore.app not found in $SIDESTORE_IPA"; exit 1; }

# --- Info.plist / Settings keys (PlistBuddy -> plistlib) ---
python3 - "$APP/Info.plist" "$APP/Settings.bundle/Root.plist" <<'PY'
import plistlib, sys, os
info_path, settings_path = sys.argv[1], sys.argv[2]
with open(info_path, "rb") as f: info = plistlib.load(f)
info["ALTAppGroups"] = ["group.com.SideStore.SideStore"]
urltypes = info.setdefault("CFBundleURLTypes", [])
def add_scheme(name, scheme):
    if any(scheme in e.get("CFBundleURLSchemes", []) for e in urltypes): return
    urltypes.append({"CFBundleURLName": name, "CFBundleURLSchemes": [scheme]})
add_scheme("com.kdt.livecontainer.sidestoreurlscheme", "sidestore")
add_scheme("com.kdt.livecontainer.sidestorebackupurlscheme", "sidestore-com.kdt.livecontainer")
for k in ("INIntentsSupported", "NSUserActivityTypes"):
    cur = set(info.get(k, []))
    info[k] = list(cur | {"RefreshAllIntent", "ViewAppIntent"})
with open(info_path, "wb") as f: plistlib.dump(info, f)
print("[+] patched Info.plist")

if os.path.exists(settings_path):
    with open(settings_path, "rb") as f: settings = plistlib.load(f)
    specs = settings.setdefault("PreferenceSpecifiers", [])
    if not any(s.get("Key") == "LCOpenSideStore" for s in specs):
        specs.append({"Type": "PSToggleSwitchSpecifier", "Title": "Open SideStore",
                      "Key": "LCOpenSideStore", "DefaultValue": False})
        with open(settings_path, "wb") as f: plistlib.dump(settings, f)
        print("[+] patched Settings.bundle/Root.plist")
PY

# --- SideStore.app -> Frameworks/SideStoreApp.framework (dylibified) ---
FW="$APP/Frameworks/SideStoreApp.framework"
rm -rf "$FW"
mv "$SSAPP" "$FW"
python3 "$DYLIBIFY" "$FW/SideStore" "$FW/SideStore.dylib"
rm "$FW/SideStore"
mv "$FW/SideStore.dylib" "$FW/SideStore"
ldid -S"" "$FW/SideStore"
[ -f "$SIDELC/LCAppInfo.plist" ] && cp "$SIDELC/LCAppInfo.plist" "$FW/"

# --- intents definitions + app-intents metadata (map SideStore -> SideStoreSupport) ---
for f in Intents.intentdefinition ViewApp.intentdefinition; do
    [ -f "$FW/$f" ] && cp "$FW/$f" "$APP/"
done
if [ -d "$FW/Metadata.appintents" ]; then
    rm -rf "$APP/Metadata.appintents"
    cp -r "$FW/Metadata.appintents" "$APP/Metadata.appintents"
    AD="$APP/Metadata.appintents/extract.actionsdata"
    if [ -f "$AD" ]; then
        sed -i 's/9SideStore20RefreshAllAppsIntentV/16SideStoreSupport20RefreshAllAppsIntentV/g' "$AD"
        sed -i 's/9SideStore26RefreshAllAppsWidgetIntentV/16SideStoreSupport26RefreshAllAppsWidgetIntentV/g' "$AD"
    fi
fi

# --- AltWidgetExtension -> LiveWidgetExtension.appex ---
WIDGET_SRC="$FW/PlugIns/AltWidgetExtension.appex"
if [ -d "$WIDGET_SRC" ]; then
    mkdir -p "$APP/PlugIns"
    WIDGET="$APP/PlugIns/LiveWidgetExtension.appex"
    rm -rf "$WIDGET"
    mv "$WIDGET_SRC" "$WIDGET"
    python3 - "$WIDGET/Info.plist" <<'PY'
import plistlib, sys
p = sys.argv[1]
with open(p, "rb") as f: d = plistlib.load(f)
d["CFBundleIdentifier"] = "com.kdt.livecontainer.LiveWidget"
d["CFBundleExecutable"] = "LiveWidgetExtension"
with open(p, "wb") as f: plistlib.dump(d, f)
PY
    mv "$WIDGET/AltWidgetExtension" "$WIDGET/LiveWidgetExtension"
    find "$WIDGET" -type d -name "_CodeSignature" -exec rm -rf {} + 2>/dev/null || true
    if [ -f "$SIDELC/LiveWidgetExtension_adhoc.xml" ]; then
        ldid -S"$SIDELC/LiveWidgetExtension_adhoc.xml" "$WIDGET/LiveWidgetExtension"
    else
        ldid -S "$WIDGET/LiveWidgetExtension"
    fi
fi

# --- package ---
rm -f "$OUT"
( cd "$WORK/lc" && zip -rqy "$OUT" Payload -x "._*" -x ".DS_Store" -x "__MACOSX" )
echo "[+] wrote $OUT ($(du -h "$OUT" | cut -f1))"
