#!/bin/zsh

set -euo pipefail

if (( EUID != 0 )); then
  echo "uninstall-driver.sh must run as root" >&2
  exit 1
fi

target_bundle="/Library/Audio/Plug-Ins/HAL/SpeakerRouterHAL.driver"

if [[ ! -e "${target_bundle}" ]]; then
  echo "SpeakerRouterHAL is not installed"
  exit 0
fi

bundle_id=$(/usr/bin/plutil -extract CFBundleIdentifier raw "${target_bundle}/Contents/Info.plist")
if [[ "${bundle_id}" != "com.liubaoyuan.SpeakerRouterHAL" ]]; then
  echo "Refusing to remove unexpected bundle: ${bundle_id}" >&2
  exit 1
fi

/bin/rm -rf "${target_bundle}"
/usr/bin/killall coreaudiod || true

echo "Removed ${target_bundle}"
