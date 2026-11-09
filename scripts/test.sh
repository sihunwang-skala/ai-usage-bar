#!/bin/zsh
# swift test 래퍼. Xcode 없이 Command Line Tools만 있는 Mac에서는 Swift Testing 프레임워크 경로를 직접 알려 줘야 한다.
# (Xcode나 GitHub Actions의 macos 러너에서는 그냥 `swift test`와 같다.)
set -euo pipefail
cd "${0:A:h}/.."
CLT=/Library/Developer/CommandLineTools/Library/Developer
if [[ "$(xcode-select -p)" == "/Library/Developer/CommandLineTools" && -d "$CLT/Frameworks/Testing.framework" ]]; then
    exec swift test \
        -Xswiftc -F -Xswiftc "$CLT/Frameworks" -Xlinker -F -Xlinker "$CLT/Frameworks" \
        -Xlinker -rpath -Xlinker "$CLT/Frameworks" -Xlinker -rpath -Xlinker "$CLT/usr/lib" "$@"
fi
exec swift test "$@"
