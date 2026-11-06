#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
output_root=${1:-"${project_dir}/DerivedData/Products"}
bundle="${output_root}/SpeakerRouter.app"
contents="${bundle}/Contents"
driver_output_root="${project_dir}/DerivedData/ManualBuild"
adapter_output_root="${project_dir}/DerivedData/MediaRemoteAdapterBuild"

cd "${project_dir}"
"${project_dir}/Scripts/build-driver.sh" "${driver_output_root}"
"${project_dir}/Scripts/build-mediaremote-adapter.sh" "${adapter_output_root}"
swift build -c release --product SpeakerRouterApp
swift build -c release --product SpeakerRouterGuard

mkdir -p \
  "${contents}/MacOS" \
  "${contents}/Helpers" \
  "${contents}/Frameworks" \
  "${contents}/Resources/MediaRemoteAdapter" \
  "${contents}/Resources/ThirdPartyLicenses"
cp "${project_dir}/.build/release/SpeakerRouterApp" \
  "${contents}/MacOS/SpeakerRouterApp"
cp "${project_dir}/.build/release/SpeakerRouterGuard" \
  "${contents}/Helpers/SpeakerRouterGuard"
/usr/bin/ditto "${driver_output_root}/SpeakerRouterHAL.driver" \
  "${contents}/Resources/SpeakerRouterHAL.driver"
/usr/bin/ditto "${adapter_output_root}/MediaRemoteAdapter.framework" \
  "${contents}/Frameworks/MediaRemoteAdapter.framework"
cp "${project_dir}/ThirdParty/mediaremote-adapter/bin/mediaremote-adapter.pl" \
  "${contents}/Resources/MediaRemoteAdapter/mediaremote-adapter.pl"
cp "${project_dir}/ThirdParty/mediaremote-adapter/LICENSE" \
  "${contents}/Resources/ThirdPartyLicenses/MediaRemoteAdapter-LICENSE"
cp "${project_dir}/ThirdParty/lucide/LICENSE" \
  "${contents}/Resources/ThirdPartyLicenses/Lucide-LICENSE"
cp "${project_dir}/Scripts/driver-manager.sh" \
  "${contents}/Resources/driver-manager.sh"
cp "${project_dir}/Assets/SpeakerRouter.icns" \
  "${contents}/Resources/SpeakerRouter.icns"
cp "${project_dir}/Packaging/SpeakerRouter-Info.plist" "${contents}/Info.plist"
codesign --force --deep --sign - "${bundle}"

echo "Built ${bundle}"
