#!/bin/sh
# Build and run the bmp3xx host tests with Alire's native GNAT.
# Run ../../setup.sh once first so the i2c_generic sources are present.
set -e
cd "$(dirname "$0")"
GNAT=$(ls -d "$HOME"/.local/share/alire/toolchains/gnat_native_* | tail -1)
GPR=$(ls -d "$HOME"/.local/share/alire/toolchains/gprbuild_* | tail -1)
PATH="$GNAT/bin:$GPR/bin:$PATH" gprbuild -q -P bmp3xx_tests.gpr
./bin/bmp3xx_tests
