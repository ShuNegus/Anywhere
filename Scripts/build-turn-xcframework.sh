#!/bin/sh
# Builds Frameworks/Turn.xcframework from the vk-turn-proxy Go core.
#
# The framework is a gomobile bind of github.com/cacggghp/vk-turn-proxy/mobile/anywhere,
# which exposes the embeddable clientcore.Dialer (VLESS-mode TURN pipeline) to Swift.
# The binary is NOT checked into git — run this script after cloning.
#
# Requirements:
#   * Go 1.25+
#   * the sagernet gomobile fork:
#       go install github.com/sagernet/gomobile/cmd/gomobile@v0.1.13
#       go install github.com/sagernet/gomobile/cmd/gobind@v0.1.13
#   * a checkout of vk-turn-proxy (branch bublik-dev) — path below or $VK_TURN_PROXY.
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="${VK_TURN_PROXY:-$ROOT/../../../Turn/References/moroka8/vk-turn-proxy}"
OUT="$ROOT/Frameworks/Turn.xcframework"

export PATH="$PATH:$(go env GOPATH)/bin:/opt/homebrew/bin"

[ -d "$CORE" ] || { echo "vk-turn-proxy not found at $CORE (set \$VK_TURN_PROXY)"; exit 1; }
command -v gomobile >/dev/null || { echo "gomobile not found; see header of this script"; exit 1; }
command -v gobind   >/dev/null || { echo "gobind not found; see header of this script";   exit 1; }

cd "$CORE"
rm -rf "$OUT"
# Both slices are mandatory: ios-arm64 for the device, ios-arm64_x86_64-simulator
# for the simulator, otherwise simulator builds fail to link.
gomobile bind -v -target=ios,iossimulator -o "$OUT" ./mobile/anywhere

echo "built $OUT"
ls "$OUT"
