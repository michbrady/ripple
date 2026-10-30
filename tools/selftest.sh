#!/bin/zsh
# Runs the in-app self-test against a fresh store in /tmp. Exit code 0 when every check passed.
set -u
rm -rf ~/Library/Saved\ Application\ State/com.michael.ripple.savedState
store=/tmp/Ripple-self.store
rm -f $store $store-shm $store-wal
APP_STORE=$store ~/Applications/Ripple.app/Contents/MacOS/Ripple --selftest
