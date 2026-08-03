#!/bin/zsh

set -euo pipefail

if (( EUID != 0 )); then
  echo "install-driver.sh must run as root" >&2
  exit 1
fi

script_dir=${0:A:h}
project_dir=${script_dir:h}
source_bundle="${project_dir}/DerivedData/ManualBuild/SpeakerRouterHAL.driver"
target_bundle="/Library/Audio/Plug-Ins/HAL/SpeakerRouterHAL.driver"

if [[ ! -d "${source_bundle}" ]]; then
  echo "Missing built driver: ${source_bundle}" >&2
  exit 1
fi

if [[ -e "${target_bundle}" ]]; then
  echo "Refusing to overwrite existing driver: ${target_bundle}" >&2
  exit 1
fi

/usr/bin/ditto "${source_bundle}" "${target_bundle}"
/usr/sbin/chown -R root:wheel "${target_bundle}"
/bin/chmod -R go-w "${target_bundle}"
/usr/bin/killall coreaudiod || true

echo "Installed ${target_bundle}"
