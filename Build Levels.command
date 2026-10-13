#!/bin/bash
cd "$(dirname "$0")"
bash ./build.sh --install 2>&1 | tee build.log
echo "EXIT: ${PIPESTATUS[0]}" | tee -a build.log
