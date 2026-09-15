#!/bin/sh
# Strip quarantine from a downloaded Wine .app
xattr -dr com.apple.quarantine "$1"
