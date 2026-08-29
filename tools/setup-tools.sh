#!/usr/bin/env bash
# Installs local Luau tooling for the BRINE repo into the ignored
# .tools/ directory so you can lint/format/analyze the scripts.
#
# Installs:
#   - luaparse (npm)          -> used by tools/check-syntax.js
#   - stylua (ROBLOX formatter)
#   - selene (Lua linter)
#   - luau (compiler/analyzer)
#
# Usage:
#   bash tools/setup-tools.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.tools/bin"
mkdir -p "$BIN"

echo "[1/3] Installing npm luaparse for tools/check-syntax.js ..."
(
	cd "$ROOT/tools"
	npm install --no-fund --no-audit
)

OS=""
ARCH=""
case "$(uname -s)" in
	Linux)
		OS="linux"
		;;
	Darwin)
		OS="macos"
		;;
	MINGW* | MSYS* | CYGWIN*)
		OS="windows"
		;;
	*)
		echo "Unsupported OS: $(uname -s)"
		exit 1
		;;
esac

case "$(uname -m)" in
	x86_64 | amd64)
		ARCH="x86_64"
		;;
	arm64 | aarch64)
		ARCH="aarch64"
		;;
	*)
		echo "Unsupported arch: $(uname -m)"
		exit 1
		;;
esac

download_zip() {
	local url="$1"
	local name="$2"
	echo "Downloading $name ..."
	curl -fsSL -o "$BIN/$name.zip" "$url"
	unzip -oq "$BIN/$name.zip" -d "$BIN"
	rm -f "$BIN/$name.zip"
}

echo "[2/3] Downloading stylua and selene ..."

# stylua
STYLUA_ASSET="stylua-${OS}-${ARCH}"
if [ "$OS" = "macos" ]; then
	STYLUA_ASSET="stylua-macos-${ARCH}"
fi
download_zip "https://github.com/JohnnyMorganz/StyLua/releases/download/v2.5.2/${STYLUA_ASSET}.zip" "stylua"

# selene
if [ "$OS" = "linux" ]; then
	SELENE_ASSET="selene-0.31.0-linux.zip"
elif [ "$OS" = "macos" ]; then
	SELENE_ASSET="selene-0.31.0-macos.zip"
else
	SELENE_ASSET="selene-0.31.0-windows.zip"
fi
download_zip "https://github.com/Kampfkarren/selene/releases/download/0.31.0/${SELENE_ASSET}" "selene"

echo "[3/3] Downloading Luau compiler/analyzer ..."
if [ "$OS" = "linux" ]; then
	LUAU_ASSET="luau-ubuntu.zip"
elif [ "$OS" = "macos" ]; then
	LUAU_ASSET="luau-macos.zip"
else
	LUAU_ASSET="luau-windows.zip"
fi
download_zip "https://github.com/luau-lang/luau/releases/download/0.736/${LUAU_ASSET}" "luau"

chmod +x "$BIN"/* 2>/dev/null || true

echo ""
echo "Done. Tools are in $BIN"
echo "Run checks with:"
echo "  node tools/check-syntax.js"
echo "  $BIN/stylua --check src"
echo "  $BIN/selene --config tools/selene.toml src"
echo "  $BIN/luau-analyze src"
