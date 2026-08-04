#!/bin/bash
# instalar.sh — instala el puente Switch 2 Pro Controller → macOS/Wine.
#
# Es idempotente: puedes volver a ejecutarlo tras actualizar CrossOver para
# reponer la shim de SDL dentro del bundle.
set -euo pipefail

RAIZ="$(cd "$(dirname "$0")" && pwd)"
SOPORTE="$HOME/Library/Application Support/Switch2Bridge"
APP="$HOME/Applications/Switch2Bridge.app"
AGENTE="$HOME/Library/LaunchAgents/dev.swondev.switch2bridge.plist"
ETIQUETA="dev.swondev.switch2bridge"

azul()  { printf "\033[1;34m%s\033[0m\n" "$*"; }
verde() { printf "\033[1;32m%s\033[0m\n" "$*"; }
rojo()  { printf "\033[1;31m%s\033[0m\n" "$*"; }
aviso() { printf "\033[1;33m%s\033[0m\n" "$*"; }

azul "▸ 1/6  Compilando el demonio BLE"
cd "$RAIZ/daemon"
swift build -c release
BINARIO="$RAIZ/daemon/.build/release/Switch2Bridge"

azul "▸ 2/6  Montando Switch2Bridge.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BINARIO" "$APP/Contents/MacOS/Switch2Bridge"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>            <string>es</string>
    <key>CFBundleExecutable</key>                   <string>Switch2Bridge</string>
    <key>CFBundleIdentifier</key>                   <string>dev.swondev.switch2bridge</string>
    <key>CFBundleName</key>                         <string>Switch2Bridge</string>
    <key>CFBundleDisplayName</key>                  <string>Puente Switch 2</string>
    <key>CFBundlePackageType</key>                  <string>APPL</string>
    <key>CFBundleShortVersionString</key>           <string>1.0</string>
    <key>CFBundleVersion</key>                      <string>1</string>
    <key>LSMinimumSystemVersion</key>               <string>15.0</string>
    <!-- Sin icono en el Dock: el puente es invisible. -->
    <key>LSUIElement</key>                          <true/>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>Switch2Bridge necesita Bluetooth para conectarse a tu mando Pro de Nintendo Switch 2.</string>
</dict>
</plist>
PLIST
# Identificador estable para que TCC recuerde el permiso de Bluetooth.
codesign -s - -f -i dev.swondev.switch2bridge "$APP" >/dev/null 2>&1
verde "  app creada en $APP"

azul "▸ 3/6  Preparando la shim de SDL"
mkdir -p "$SOPORTE"

# Detecta CUALQUIER runtime de Wine instalado (CrossOver, Wine oficial,
# empaquetados propios…). El criterio es objetivo: que tenga winebus.so con bus
# SDL y una libSDL2 propia que podamos reexportar.
INSTALACIONES=()
NOMBRES=()
while IFS= read -r bus; do
    [ -n "$bus" ] || continue
    destino="$(dirname "$bus")"
    raiz="$(cd "$destino/../../.." && pwd)"
    # Busca la libSDL2 original del runtime, fuera del directorio del bus.
    # Debe ser x86_64: es la arquitectura en la que corre el bus de Wine.
    sdl=""
    while IFS= read -r candidata; do
        if file "$candidata" 2>/dev/null | grep -q "x86_64"; then sdl="$candidata"; break; fi
    done < <(find -L "$raiz" -name "libSDL2-2.0.0.dylib" -not -path "$destino/*" 2>/dev/null)
    [ -n "$sdl" ] || continue
    INSTALACIONES+=("$destino|$sdl")
    NOMBRES+=("$(echo "$raiz" | sed "s|/Contents/.*||; s|^$HOME|~|")")
    # -L para seguir enlaces simbólicos: hay apps enlazadas desde otras carpetas.
done < <(find -L /Applications ~/Applications -maxdepth 10 -path "*/lib/wine/x86_64-unix/winebus.so" 2>/dev/null \
         | while read -r r; do realpath "$r" 2>/dev/null || echo "$r"; done | sort -u)

if [ ${#INSTALACIONES[@]} -eq 0 ]; then
    aviso "  No se encontró ningún runtime de Wine: se omite esa integración."
else
  indice=0
  for entrada in "${INSTALACIONES[@]}"; do
    DESTINO_SHIM="${entrada%%|*}/libSDL2-2.0.0.dylib"
    SDL_ORIGINAL="${entrada##*|}"
    etiqueta="${NOMBRES[$indice]}"
    indice=$((indice + 1))
    # La etiqueta lleva la ruta completa (puede haber la misma app en dos
    # sitios); para nombres de fichero necesitamos una versión saneada.
    slug="$(echo "$etiqueta" | tr -c '[:alnum:]' '_' | sed 's/__*/_/g; s/^_//; s/_$//')"

    # Copiamos la SDL original fuera del bundle y la reexportamos desde la shim,
    # así el runtime conserva toda su funcionalidad de SDL.
    COPIA="$SOPORTE/libSDL2-real-${slug}.dylib"
    cp "$SDL_ORIGINAL" "$COPIA"
    install_name_tool -id "$COPIA" "$COPIA" 2>/dev/null || true
    codesign -s - -f "$COPIA" >/dev/null 2>&1

    clang -dynamiclib -arch x86_64 -O2 \
        -install_name libSDL2-2.0.0.dylib \
        -Wl,-reexport_library,"$COPIA" \
        "$RAIZ/shim/shim_sdl.c" -o "$SOPORTE/shim-${slug}.dylib" 2>/dev/null || {
            aviso "  no se pudo compilar la shim para «${etiqueta}»"; continue; }
    codesign -s - -f "$SOPORTE/shim-${slug}.dylib" >/dev/null 2>&1

    cp "$SOPORTE/shim-${slug}.dylib" "$DESTINO_SHIM"
    verde "  shim instalada en «${etiqueta}»"
  done

  azul "▸ 4/6  Activando el bus SDL en las botellas de Wine"
  # Un prefijo de Wine se reconoce sin ambigüedad por tener system.reg junto a
  # drive_c. Buscamos así, en vez de por nombre de producto, para cubrir
  # CrossOver, Whisky, Mythic, Wineskin, Heroic y prefijos sueltos.
  encontradas=0
  while IFS= read -r reg; do
      [ -n "$reg" ] || continue
      botella="$(dirname "$reg")"
      [ -d "$botella/drive_c" ] || continue
      encontradas=$((encontradas + 1))
      etiqueta_botella="$(echo "$botella" | sed "s|^$HOME|~|")"
      if grep -q '"Enable SDL"=dword:00000001' "$reg" 2>/dev/null; then
          verde "  ${etiqueta_botella}: bus SDL ya activado"
      else
          printf '\n[System\\\\CurrentControlSet\\\\Services\\\\winebus\\\\Parameters] 0\n"Enable SDL"=dword:00000001\n' >> "$reg"
          verde "  ${etiqueta_botella}: bus SDL activado"
      fi
  done < <(find -L "$HOME/Library/Application Support" "$HOME/Library/Containers" \
                "$HOME/Games" "$HOME/Applications" /Applications \
                -maxdepth 6 -name "system.reg" 2>/dev/null | sort -u)
  [ "$encontradas" -eq 0 ] && aviso "  no se encontró ninguna botella (créala y reejecuta)"
fi

azul "▸ 5/6  Instalando los agentes de arranque"
# El reparador necesita el código de la shim para recompilarla por runtime.
cp "$RAIZ/shim/shim_sdl.c" "$SOPORTE/shim_sdl.c"
cp "$RAIZ/reparar.sh" "$SOPORTE/reparar.sh"
chmod +x "$SOPORTE/reparar.sh"

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$AGENTE" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>              <string>$ETIQUETA</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP/Contents/MacOS/Switch2Bridge</string>
    </array>
    <key>RunAtLoad</key>          <true/>
    <key>KeepAlive</key>          <true/>
    <key>ProcessType</key>        <string>Interactive</string>
    <key>StandardOutPath</key>    <string>$SOPORTE/salida.log</string>
    <key>StandardErrorPath</key>  <string>$SOPORTE/error.log</string>
</dict>
</plist>
PLIST

# Descarga el agente previo: dos demonios a la vez se pelearían por el socket.
launchctl bootout "gui/$(id -u)/$ETIQUETA" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENTE"
verde "  agente del demonio cargado"

# Agente de mantenimiento: repone la shim si una actualización se la lleva y
# activa el bus SDL en botellas nuevas, sin que el usuario tenga que enterarse.
AGENTE_REPARADOR="$HOME/Library/LaunchAgents/${ETIQUETA}.reparar.plist"
cat > "$AGENTE_REPARADOR" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>              <string>${ETIQUETA}.reparar</string>
    <key>ProgramArguments</key>
    <array>
        <string>$SOPORTE/reparar.sh</string>
        <string>--silencioso</string>
    </array>
    <key>RunAtLoad</key>          <true/>
    <key>StartInterval</key>      <integer>21600</integer>
    <key>ProcessType</key>        <string>Background</string>
</dict>
</plist>
PLIST
launchctl bootout "gui/$(id -u)/${ETIQUETA}.reparar" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENTE_REPARADOR"
verde "  agente de mantenimiento cargado (revisa cada 6 h)"

azul "▸ 6/6  Comprobando"
sleep 2
if launchctl print "gui/$(id -u)/$ETIQUETA" >/dev/null 2>&1; then
    verde "  demonio en marcha"
else
    rojo "  el demonio no arrancó; revisa $SOPORTE/error.log"
fi

echo
verde "Instalación completada."
echo
echo "Ahora:"
echo "  1. Enciende el mando y mantén pulsado el botón SYNC (arriba, junto al USB-C)"
echo "     hasta que los LEDs parpadeen."
echo "  2. macOS pedirá permiso de Bluetooth la primera vez: acéptalo."
echo "  3. Comprueba el estado con:  $RAIZ/estado.sh"
echo
echo "Para que Wine vea el mando debes cerrar la sesión de la botella:"
echo "  pkill -f winedevice; pkill -f wineserver"
