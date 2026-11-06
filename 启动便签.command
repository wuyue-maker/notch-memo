#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
if [[ ! -d build/刘海便签.app ]]; then
  zsh scripts/build.sh
fi
/usr/bin/open "$PWD/build/刘海便签.app"
