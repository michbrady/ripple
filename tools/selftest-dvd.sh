#!/bin/zsh
# Runs the app's own copies of ffmpeg, spumux, dvdauthor, and hdiutil on two videos it makes, and builds a real Video DVD image.
# Writes nothing to a drive. Needs ./build.sh to have carried the tools (tools/fetch-ffmpeg.sh and tools/build-dvdauthor.sh first).
set -u
rm -rf ~/Library/Saved\ Application\ State/com.michael.ripple.savedState
store=/tmp/Ripple-real.store
rm -f $store $store-shm $store-wal
RIPPLE_REAL_DVD=1 APP_STORE=$store ~/Applications/Ripple.app/Contents/MacOS/Ripple --selftest
