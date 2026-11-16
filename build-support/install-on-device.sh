#!/usr/bin/env bash
#
# install-on-device.sh: idl post_build step. If Jimpactor is running and
# reports a connected device, install the freshly built IPA on it. Otherwise
# skip quietly so builds work without a phone.
#
# Vars:
#   INSTALL_IPA     IPA to install (default: LiveContainer+SideStore.ipa next to
#                   $IDL_IPA, falling back to $IDL_IPA itself)
#   IDL_DEVICE      device to use (UDID, UDID prefix or name; default: first
#                   available device)
#   IDL_NO_INSTALL  set to 1 to skip installing
set -uo pipefail

log() { echo "[install] $*"; }

if [ "${IDL_NO_INSTALL:-0}" = 1 ]; then log "IDL_NO_INSTALL=1; skipping"; exit 0; fi

IDL="${IDL:-idl}"
LC_IPA="${IDL_IPA:-build/LiveContainer.ipa}"
IPA="${INSTALL_IPA:-$(dirname "$LC_IPA")/LiveContainer+SideStore.ipa}"
[ -f "$IPA" ] || IPA="$LC_IPA"
[ -f "$IPA" ] || { log "no IPA at $IPA"; exit 1; }

if ! devices=$("$IDL" devices list 2>&1); then
    log "Jimpactor not reachable; skipping (${devices##*: })"
    exit 0
fi

# `idl devices list`: header line, then "UDID CONNECTION AVAILABLE NAME..."
device=""
while read -r udid connection available name; do
    [ "$available" = yes ] || continue
    if [ -z "${IDL_DEVICE:-}" ] || [[ "$udid" == "$IDL_DEVICE"* ]] || [ "$name" = "$IDL_DEVICE" ]; then
        device="$udid"
        label="$name ($connection)"
        break
    fi
done < <(tail -n +2 <<<"$devices")

if [ -z "$device" ]; then
    log "no connected device${IDL_DEVICE:+ matching '$IDL_DEVICE'}; skipping"
    exit 0
fi

log "installing $(basename "$IPA") on $label"
exec "$IDL" install --ipa "$IPA" "$device"
