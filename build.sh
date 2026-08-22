#!/bin/zsh
set -e
cd "$(dirname "$0")"
APP=TopBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -parse-as-library -O -o "$APP/Contents/MacOS/TopBar" Sources/*.swift
echo "Built $APP — launching."
open "$APP"
