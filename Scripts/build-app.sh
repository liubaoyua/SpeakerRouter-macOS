#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
output_root=${1:-"${project_dir}/DerivedData/Products"}
bundle="${output_root}/SpeakerRouter.app"
contents="${bundle}/Contents"

cd "${project_dir}"
swift build -c release --product SpeakerRouterApp
swift build -c release --product SpeakerRouterGuard

mkdir -p "${contents}/MacOS" "${contents}/Helpers"
cp "${project_dir}/.build/release/SpeakerRouterApp" \
  "${contents}/MacOS/SpeakerRouterApp"
cp "${project_dir}/.build/release/SpeakerRouterGuard" \
  "${contents}/Helpers/SpeakerRouterGuard"
cp "${project_dir}/Packaging/SpeakerRouter-Info.plist" "${contents}/Info.plist"
codesign --force --deep --sign - "${bundle}"

echo "Built ${bundle}"
