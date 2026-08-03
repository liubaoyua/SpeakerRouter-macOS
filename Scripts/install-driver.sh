#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
source_bundle="${project_dir}/DerivedData/ManualBuild/SpeakerRouterHAL.driver"

if [[ ! -d "${source_bundle}" ]]; then
  echo "Missing built driver: ${source_bundle}" >&2
  exit 1
fi

exec /bin/zsh "${script_dir}/driver-manager.sh" install "${source_bundle}"
