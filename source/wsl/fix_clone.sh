#!/bin/bash
# Recover the stuck clone: kill the hung ssh/clone, route GitHub SSH->HTTPS,
# disable submodule recursion (skip the SSH-only 'pocket' target we don't need),
# finish the submodules we DO need, then copy the nslasher scaffold across.
pkill -f clone_wsl.sh 2>/dev/null || true
pkill ssh 2>/dev/null || true
sleep 1
git config --global url."https://github.com/".insteadOf "git@github.com:"
git config --global submodule.recurse false
cd "$HOME/jtcores" || exit 1
find .git -name '*.lock' -delete 2>/dev/null || true
echo "=== finishing needed submodules (HTTPS, no recurse) ==="
git -c submodule.recurse=false submodule update --init --depth 1 \
    modules/jtframe modules/jt51 modules/jt6295 modules/jteeprom
echo "submodule rc=$?"
git submodule status modules/jtframe modules/jt51 modules/jt6295 modules/jteeprom 2>&1 | sed -n '1,12p'
echo "=== copy nslasher scaffold from Windows clone ==="
mkdir -p cores/nslasher
cp -r /path/to/nightslashers/jtcores/cores/nslasher/. cores/nslasher/
find cores/nslasher/cfg -type f -exec sed -i 's/\r$//' {} + 2>/dev/null || true
echo "--- nslasher files ---"
find cores/nslasher -type f | sort
echo FIX_DONE
