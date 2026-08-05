#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
source_dir="${project_dir}/ThirdParty/mediaremote-adapter"
output_root=${1:-"${project_dir}/DerivedData/MediaRemoteAdapterBuild"}

if [[ ! -f "${source_dir}/CMakeLists.txt" ]]; then
  echo "MediaRemote Adapter source is missing." >&2
  echo "Run: git submodule update --init --recursive" >&2
  exit 1
fi

cmake \
  -S "${source_dir}" \
  -B "${output_root}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
cmake --build "${output_root}" --config Release --target MediaRemoteAdapter

echo "Built ${output_root}/MediaRemoteAdapter.framework"
