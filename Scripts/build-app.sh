#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
output_root=${1:-"${project_dir}/DerivedData/Products"}
bundle="${output_root}/SpeakerRouter.app"
contents="${bundle}/Contents"
driver_output_root="${project_dir}/DerivedData/ManualBuild"

cd "${project_dir}"
"${project_dir}/Scripts/build-driver.sh" "${driver_output_root}"
swift build -c release --product SpeakerRouterApp
swift build -c release --product SpeakerRouterGuard

mkdir -p "${contents}/MacOS" "${contents}/Helpers" "${contents}/Resources"
cp "${project_dir}/.build/release/SpeakerRouterApp" \
  "${contents}/MacOS/SpeakerRouterApp"
cp "${project_dir}/.build/release/SpeakerRouterGuard" \
  "${contents}/Helpers/SpeakerRouterGuard"
/usr/bin/ditto "${driver_output_root}/SpeakerRouterHAL.driver" \
  "${contents}/Resources/SpeakerRouterHAL.driver"
cp "${project_dir}/Scripts/driver-manager.sh" \
  "${contents}/Resources/driver-manager.sh"
cp "${project_dir}/Packaging/SpeakerRouter-Info.plist" "${contents}/Info.plist"
codesign --force --deep --sign - "${bundle}"

echo "Built ${bundle}"
