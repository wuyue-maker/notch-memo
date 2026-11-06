#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/module-cache .build/clang-cache .build/config .build/security
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
swift test --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security" --scratch-path "$PWD/.build" -Xswiftc -module-cache-path -Xswiftc "$PWD/.build/module-cache" --disable-sandbox
