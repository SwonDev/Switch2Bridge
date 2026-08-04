#!/bin/bash
# desinstalar.sh — revierte por completo la instalación del puente.
set -uo pipefail

SOPORTE="$HOME/Library/Application Support/Switch2Bridge"
APP="$HOME/Applications/Switch2Bridge.app"
AGENTE="$HOME/Library/LaunchAgents/dev.swondev.switch2bridge.plist"
ETIQUETA="dev.swondev.switch2bridge"

verde() { printf "\033[1;32m%s\033[0m\n" "$*"; }

echo "Desinstalando el puente Switch 2…"

launchctl bootout "gui/$(id -u)/$ETIQUETA" 2>/dev/null && verde "  agente descargado" || true
rm -f "$AGENTE"
rm -rf "$APP"
verde "  app y agente eliminados"

# La shim vive dentro del bundle de CrossOver: quitarla lo deja como estaba.
for candidato in "/Applications/CrossOver.app" "/Applications/CrossOver Preview.app"; do
    SHIM="$candidato/Contents/SharedSupport/CrossOver/lib/wine/x86_64-unix/libSDL2-2.0.0.dylib"
    if [ -f "$SHIM" ]; then
        rm -f "$SHIM"
        verde "  shim retirada de $(basename "$candidato")"
    fi
done

# El bus SDL de Wine se deja activado a propósito: es inocuo y reversible a mano
# con reg delete sobre HKLM\System\CurrentControlSet\Services\winebus\Parameters.

rm -rf "$SOPORTE"
verde "  datos de soporte eliminados"

echo
verde "Desinstalado. Cierra las sesiones de Wine con: pkill -f winedevice"
