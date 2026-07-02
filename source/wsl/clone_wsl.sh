#!/bin/bash
set -e
cd "$HOME"
echo "HOME=$HOME"
if [ ! -d jtcores ]; then
  echo "Cloning jtcores (shallow)..."
  git clone --depth 1 https://github.com/jotego/jtcores.git
else
  echo "jtcores already present"
fi
cd "$HOME/jtcores"
echo "Init submodules (jtframe, jt51, jt6295, jteeprom)..."
git submodule update --init --depth 1 modules/jtframe modules/jt51 modules/jt6295 modules/jteeprom
echo "=== submodule status ==="
git submodule status modules/jtframe modules/jt51 modules/jt6295 modules/jteeprom
echo "Copying nslasher scaffold from the Windows clone..."
mkdir -p cores/nslasher
cp -r /path/to/nightslashers/jtcores/cores/nslasher/. cores/nslasher/
# normalize cfg text to LF (authored on Windows)
find cores/nslasher/cfg -type f -exec sed -i 's/\r$//' {} + 2>/dev/null || true
echo "=== nslasher tree ==="
find cores/nslasher -type f | sort
echo CLONE_SETUP_DONE
