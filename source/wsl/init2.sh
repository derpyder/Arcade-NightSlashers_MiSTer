#!/bin/bash
cd "$HOME/jtcores" || exit 1
echo "PWD=$(pwd)"
echo "--- .gitmodules entries ---"
git config -f .gitmodules --get-regexp 'submodule\.(modules/)?(jt51|jt6295|jteeprom)' 2>&1 || true
echo "--- status before ---"
git submodule status modules/jt51 modules/jt6295 modules/jteeprom 2>&1
git config --global url."https://github.com/".insteadOf "git@github.com:"
for m in jt51 jt6295 jteeprom; do
  echo "--- update $m ---"
  GIT_SSH_COMMAND='ssh -o BatchMode=yes' git -c submodule.recurse=false submodule update --init --depth 1 "modules/$m" </dev/null 2>&1
  echo "rc=$?  hdl .v: $(ls modules/$m/hdl/*.v 2>/dev/null | wc -l)"
done
echo DONE
