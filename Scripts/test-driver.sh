#!/bin/zsh

set -euo pipefail

project_dir=${0:A:h:h}
audio_support_dir="${project_dir}/Sources/SpeakerRouterAudioSupport"
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

"${project_dir}/Scripts/build-driver.sh" "${work_dir}"
xcrun clang -std=c11 -O2 -Wall -Wextra -Werror \
  -I "${audio_support_dir}/include" \
  "${project_dir}/Tests/SpeakerRouterHALTests/AppVolumeTests.c" \
  "${audio_support_dir}/SRSharedAudioTransport.c" \
  "${audio_support_dir}/SRAppVolume.c" \
  -framework CoreAudio -framework CoreFoundation \
  -o "${work_dir}/test-driver"

"${work_dir}/test-driver" "${work_dir}/SpeakerRouterHAL.driver/Contents/MacOS/SpeakerRouterHAL"
