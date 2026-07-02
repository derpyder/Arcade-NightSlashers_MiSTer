#!/bin/bash
# Force a clean re-checkout of the empty sound submodules, copy their hdl + the
# generated mem artifacts to Windows for reading.
cd "$HOME/jtcores" || exit 1
git config --global url."https://github.com/".insteadOf "git@github.com:"
echo "--- deinit + remove stale ---"
git submodule deinit -f modules/jt51 modules/jt6295 modules/jteeprom 2>&1 | tail -4
rm -rf .git/modules/jt51 .git/modules/jt6295 .git/modules/jteeprom modules/jt51 modules/jt6295 modules/jteeprom
echo "--- reinit (fresh checkout) ---"
GIT_SSH_COMMAND='ssh -o BatchMode=yes' git -c submodule.recurse=false submodule update --init --depth 1 \
    modules/jt51 modules/jt6295 modules/jteeprom </dev/null 2>&1 | tail -10
echo "update rc=$?"
for m in jt51 jt6295 jteeprom; do echo "$m .v files: $(find modules/$m -name '*.v' 2>/dev/null | wc -l)"; done
echo "--- copy hdl + generated mem to Windows ---"
for m in jt51 jt6295 jteeprom; do
  rm -rf "/path/to/nightslashers/$m-hdl"
  cp -r "modules/$m/hdl" "/path/to/nightslashers/$m-hdl" 2>/dev/null || true
done
rm -rf /path/to/nightslashers/nslasher-gen
mkdir -p /path/to/nightslashers/nslasher-gen
cp -r cores/nslasher/mist cores/nslasher/mister /path/to/nightslashers/nslasher-gen/ 2>/dev/null || true
echo "--- generated mem artifacts ---"
find /path/to/nightslashers/nslasher-gen -type f 2>/dev/null
echo DONE_FIX
