#!/bin/bash
# Init the leaf sound/eeprom submodules (no jtframe => no pocket recursion), copy their hdl to Windows for reading.
cd "$HOME/jtcores" || exit 1
git config --global url."https://github.com/".insteadOf "git@github.com:"
GIT_SSH_COMMAND='ssh -o BatchMode=yes' timeout 180 git -c submodule.recurse=false \
    submodule update --init --depth 1 modules/jt51 modules/jt6295 modules/jteeprom </dev/null
echo "submodule rc=$?"
for m in jt51 jt6295 jteeprom; do
  echo "$m: $(ls -A modules/$m 2>/dev/null | wc -l) entries; hdl .v: $(ls modules/$m/hdl/*.v 2>/dev/null | wc -l)"
done
for m in jt51 jt6295 jteeprom; do
  rm -rf "/path/to/nightslashers/$m-hdl"
  cp -r "modules/$m/hdl" "/path/to/nightslashers/$m-hdl" 2>/dev/null || true
done
echo "=== top .v files ==="
ls /path/to/nightslashers/jt51-hdl/*.v /path/to/nightslashers/jt6295-hdl/*.v /path/to/nightslashers/jteeprom-hdl/*.v 2>/dev/null | xargs -n1 basename
echo DONE_INIT
