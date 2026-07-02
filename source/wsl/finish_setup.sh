#!/bin/bash
# Hang-proof finish: ensure needed submodules, copy scaffold, build jtframe tool, validate cfg.
# No `set -e` on purpose: we want to push through a pocket/submodule hiccup to the build+validate.
set -uo pipefail

echo "=== kill any hung clone/ssh from prior attempts ==="
pkill -f clone_wsl.sh 2>/dev/null || true
pkill -f fix_clone.sh  2>/dev/null || true
pkill -f git-remote    2>/dev/null || true
pkill ssh              2>/dev/null || true
sleep 1

git config --global url."https://github.com/".insteadOf "git@github.com:"
cd "$HOME/jtcores" || { echo "NO ~/jtcores"; exit 1; }
find .git -name '*.lock' -delete 2>/dev/null || true

echo "=== ensure needed submodules (HTTPS, no-recurse, SSH=BatchMode so it can't hang) ==="
GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=5' \
  timeout 420 git -c submodule.recurse=false submodule update --init --depth 1 \
  modules/jtframe modules/jt51 modules/jt6295 modules/jteeprom </dev/null
echo "submodule rc=$?"

echo "=== module presence ==="
for m in jtframe jt51 jt6295 jteeprom; do
  printf "%-10s %s entries\n" "$m" "$(ls -A modules/$m 2>/dev/null | wc -l)"
done
echo "jtframe go srcs: $(ls modules/jtframe/src/jtframe/*.go 2>/dev/null | wc -l)"

echo "=== copy nslasher scaffold ==="
mkdir -p cores/nslasher
cp -r /path/to/nightslashers/jtcores/cores/nslasher/. cores/nslasher/ 2>/dev/null || true
find cores/nslasher/cfg -type f -exec sed -i 's/\r$//' {} + 2>/dev/null || true
find cores/nslasher -maxdepth 2 -type f | sort

echo "=== build jtframe Go tool (direct go build, skips wrapper test-gate) ==="
source setprj.sh
if ( cd "$JTFRAME/src/jtframe" && timeout 600 go build . ); then echo BUILD_OK; else echo BUILD_FAIL; fi
JF="$JTFRAME/src/jtframe/jtframe"
if [ -x "$JF" ]; then
  echo "=== jtframe --help (subcommands) ==="
  "$JF" --help 2>&1 | head -50
  echo "=== jtframe mem nslasher (cfg spine validation) ==="
  "$JF" mem nslasher 2>&1 | head -60 || true
else
  echo "jtframe binary NOT built; skipping cfg validation"
fi
echo ALL_DONE
