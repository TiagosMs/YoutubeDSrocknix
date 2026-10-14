#!/bin/bash
# ==============================================================================
# YouTube DS - One-line Installer for ROCKNIX (Anbernic RG DS)
# ==============================================================================
set -e

DEST="/storage/roms/ports"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Instalando YouTube DS para ROCKNIX..."

mkdir -p "$DEST/youtube/app" "$DEST/youtube/cache"

cp "$REPO_DIR/YouTube.sh" "$DEST/YouTube.sh"
chmod +x "$DEST/YouTube.sh"

cp "$REPO_DIR/youtube/api_server.py" "$DEST/youtube/api_server.py"
chmod +x "$DEST/youtube/api_server.py"

cp "$REPO_DIR/youtube/app/conf.lua" "$DEST/youtube/app/conf.lua"
cp "$REPO_DIR/youtube/app/main.lua" "$DEST/youtube/app/main.lua"

echo "==> Baixando yt-dlp fallback..."
if [ ! -f "$DEST/youtube/yt-dlp" ]; then
    curl -sL https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o "$DEST/youtube/yt-dlp" || true
    chmod +x "$DEST/youtube/yt-dlp" 2>/dev/null || true
fi

echo "==> Instalação concluída com sucesso!"
echo "==> Atualize a lista de Ports no EmulationStation para iniciar o YouTube DS."
