#!/bin/zsh

set -euo pipefail

if (( EUID != 0 )); then
  echo "driver-manager.sh must run as root" >&2
  exit 1
fi

action=${1:-}
source_bundle=${2:-}
ready_path=${3:-}
acknowledgement_path=${4:-}
target_bundle="/Library/Audio/Plug-Ins/HAL/SpeakerRouterHAL.driver"
expected_bundle_id="com.liubaoyuan.SpeakerRouterHAL"

bundle_id() {
  /usr/bin/plutil -extract CFBundleIdentifier raw "$1/Contents/Info.plist"
}

validate_driver() {
  local bundle=$1
  if [[ ! -d "${bundle}" ]]; then
    echo "Missing driver bundle: ${bundle}" >&2
    exit 1
  fi
  local actual_bundle_id
  actual_bundle_id=$(bundle_id "${bundle}")
  if [[ "${actual_bundle_id}" != "${expected_bundle_id}" ]]; then
    echo "Unexpected driver bundle identifier: ${actual_bundle_id}" >&2
    exit 1
  fi
}

coordinate_with_app() {
  if [[ -z "${ready_path}" && -z "${acknowledgement_path}" ]]; then
    return
  fi
  if [[ ! -f "${ready_path}" || -z "${acknowledgement_path}" ]]; then
    echo "Invalid driver-operation coordination paths" >&2
    exit 1
  fi

  print -r -- "authorized" > "${ready_path}"
  local attempt
  for attempt in {1..200}; do
    if [[ -f "${acknowledgement_path}" ]]; then
      return
    fi
    /bin/sleep 0.05
  done
  echo "SpeakerRouter did not acknowledge the driver operation" >&2
  exit 1
}

case "${action}" in
  install)
    validate_driver "${source_bundle}"
    if [[ -e "${target_bundle}" ]]; then
      validate_driver "${target_bundle}"
    fi
    coordinate_with_app
    if [[ -e "${target_bundle}" ]]; then
      /bin/rm -rf "${target_bundle}"
    fi
    /usr/bin/ditto "${source_bundle}" "${target_bundle}"
    /usr/sbin/chown -R root:wheel "${target_bundle}"
    /bin/chmod -R go-w "${target_bundle}"
    echo "Installed ${target_bundle}"
    ;;
  uninstall)
    if [[ -e "${target_bundle}" ]]; then
      validate_driver "${target_bundle}"
      coordinate_with_app
      /bin/rm -rf "${target_bundle}"
      echo "Removed ${target_bundle}"
    else
      echo "SpeakerRouterHAL is not installed"
    fi
    ;;
  *)
    echo "Usage: driver-manager.sh install <source.driver> | uninstall" >&2
    exit 2
    ;;
esac

previous_coreaudiod_pid=$(/usr/bin/pgrep -x coreaudiod || true)
/usr/bin/killall coreaudiod || true

# killall returns after delivering the signal, while launchd may still be running the old
# AudioServerPlugIn for a short time. Do not tell the App to reconnect until coreaudiod has
# actually been replaced, otherwise a new protocol token can reach the old driver binary.
for attempt in {1..200}; do
  current_coreaudiod_pid=$(/usr/bin/pgrep -x coreaudiod || true)
  if [[ -n "${current_coreaudiod_pid}" &&
    ( -z "${previous_coreaudiod_pid}" || "${current_coreaudiod_pid}" != "${previous_coreaudiod_pid}" ) ]]; then
    exit 0
  fi
  /bin/sleep 0.05
done

echo "Core Audio did not restart after the driver operation" >&2
exit 1
