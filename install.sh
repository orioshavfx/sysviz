#!/bin/sh
# Собирает sysviz и ставит его в ~/.local/bin, чтобы запускать командой `sysviz`.
# Удалить: sh install.sh --uninstall
set -e

BIN_DIR="${PREFIX:-$HOME/.local}/bin"
TARGET="$BIN_DIR/sysviz"

cd "$(dirname "$0")"

if [ "$1" = "--uninstall" ]; then
    rm -f "$TARGET"
    echo "Удалено: $TARGET"
    exit 0
fi

swift build -c release
BUILT="$(swift build -c release --show-bin-path)/sysviz"

mkdir -p "$BIN_DIR"
install -m 755 "$BUILT" "$TARGET"
echo "Установлено: $TARGET"

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "Добавь $BIN_DIR в PATH, например: fish_add_path $BIN_DIR" ;;
esac
