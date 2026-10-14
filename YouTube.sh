#!/bin/bash
# YouTube Mobile Client for Anbernic RG DS on ROCKNIX

PORTS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P) || exit 1
APP_DIR="$PORTS_DIR/youtube"
cd "$APP_DIR" || exit 1

export XDG_RUNTIME_DIR="/var/run/0-runtime-dir"
export WAYLAND_DISPLAY="wayland-1"
export SWAYSOCK="/var/run/0-runtime-dir/sway-ipc.0.sock"
export PATH="$APP_DIR:$PATH"

# 1. Limpeza de processos anteriores
killall -9 mpv love.aarch64 2>/dev/null
pkill -f "api_server.py" 2>/dev/null
rm -f /tmp/mpvsocket

# 2. Ativar tela inferior touch (DSI-1)
swaymsg 'output DSI-1 power on' >/dev/null 2>&1

# 3. Ocultar EmulationStation
swaymsg '[app_id="emulationstation"] move scratchpad' >/dev/null 2>&1

# 4. Iniciar Backend Local
python3 "$APP_DIR/api_server.py" &
API_PID=$!
sleep 0.4

# 5. Iniciar mpv na tela superior (DSI-2)
mpv --wayland-app-id=ytds-player \
    --vo=wlshm \
    --idle=yes \
    --force-window=yes \
    --image-display-duration=inf \
    --input-ipc-server=/tmp/mpvsocket &
MPV_PID=$!

# 6. Iniciar Love2D GUI nativa na tela inferior (DSI-1)
export SDL_VIDEODRIVER=wayland
export SDL_VIDEO_DOUBLE_BUFFER=1
export LOVE_GRAPHICS_USE_OPENGLES=1
export LD_LIBRARY_PATH="/storage/roms/ports/eReaderDS/runtime/libs.aarch64:/storage/roms/ports/eReaderDS/runtime/libs.rocknix:/usr/lib:/lib"

LOVE_BIN=""
if [ -f "/storage/roms/ports/eReaderDS/runtime/love.aarch64" ]; then
    LOVE_BIN="/storage/roms/ports/eReaderDS/runtime/love.aarch64"
elif which love >/dev/null 2>&1; then
    LOVE_BIN=$(which love)
fi

"$LOVE_BIN" "$APP_DIR/app" &
LOVE_PID=$!

# 7. Posicionar janelas no Sway
for i in $(seq 1 15); do
    swaymsg '[app_id="ytds-player"] move window to output DSI-2, fullscreen enable' >/dev/null 2>&1
    swaymsg '[title="ytds-ui"] move window to output DSI-1, fullscreen enable, focus' >/dev/null 2>&1
    sleep 0.1
done

# 8. Aguardar saída
wait $LOVE_PID 2>/dev/null

# 9. Cleanup
kill $MPV_PID $API_PID 2>/dev/null
wait $MPV_PID 2>/dev/null

# 10. Restaurar EmulationStation
swaymsg '[app_id="emulationstation"] scratchpad show, floating enable, fullscreen disable, move absolute position 0 0, focus' >/dev/null 2>&1
