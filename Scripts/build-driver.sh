#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
source_dir="${project_dir}/Driver/SpeakerRouterHAL"
audio_support_dir="${project_dir}/Sources/SpeakerRouterAudioSupport"
output_root=${1:-"${project_dir}/DerivedData/ManualBuild"}
bundle="${output_root}/SpeakerRouterHAL.driver"
contents="${bundle}/Contents"

mkdir -p "${contents}/MacOS" "${contents}/Resources/en.lproj"

xcrun clang \
  -std=c11 \
  -O2 \
  -Wall \
  -Wextra \
  -Werror \
  -arch arm64 \
  -arch x86_64 \
  -mmacosx-version-min=10.13 \
  -bundle \
  -I "${audio_support_dir}/include" \
  "${source_dir}/NullAudio.c" \
  "${source_dir}/SRClientVolumes.c" \
  "${audio_support_dir}/SRSharedAudioTransport.c" \
  -framework CoreAudio \
  -framework CoreFoundation \
  -framework IOKit \
  -o "${contents}/MacOS/SpeakerRouterHAL"

cp "${source_dir}/SpeakerRouterHAL-Info.plist" "${contents}/Info.plist"
cp "${source_dir}/en.lproj/Localizable.strings" \
  "${contents}/Resources/en.lproj/Localizable.strings"
codesign --force --sign - "${bundle}"

echo "Built ${bundle}"
