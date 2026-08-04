#!/bin/bash
# verificar.sh — comprobación completa de la cadena, eslabón por eslabón.
#
# Este script es el "blindaje" del proyecto: si algún día deja de funcionar,
# ejecútalo y te dirá EXACTAMENTE dónde se rompió, sin tener que rehacer la
# investigación. Cada comprobación explica qué significa si falla.
set -uo pipefail

SOPORTE="$HOME/Library/Application Support/Switch2Bridge"
SOCKET="$SOPORTE/estado.sock"
ETIQUETA="dev.swondev.switch2bridge"

FALLOS=0
AVISOS=0

ok()    { printf "  \033[1;32m✓\033[0m %s\n" "$*"; }
mal()   { printf "  \033[1;31m✗\033[0m %s\n" "$*"; FALLOS=$((FALLOS+1)); }
aviso() { printf "  \033[1;33m•\033[0m %s\n" "$*"; AVISOS=$((AVISOS+1)); }
info()  { printf "    \033[2m%s\033[0m\n" "$*"; }
titulo(){ printf "\n\033[1;34m%s\033[0m\n" "$*"; }

printf "\n\033[1;36m╭─────────────────────────────────────────────╮\033[0m\n"
printf "\033[1;36m│  Switch2Bridge · verificación de la cadena  │\033[0m\n"
printf "\033[1;36m╰─────────────────────────────────────────────╯\033[0m\n"

# ───────────────────────────────────────────────────────────── 1. Demonio
titulo "1 · Demonio BLE"

if launchctl print "gui/$(id -u)/$ETIQUETA" >/dev/null 2>&1; then
    ok "agente cargado en launchd (arranca solo al iniciar sesión)"
else
    mal "el agente NO está cargado"
    info "arréglalo con: ./instalar.sh"
fi

if pgrep -f "Switch2Bridge.app/Contents/MacOS/Switch2Bridge" >/dev/null 2>&1; then
    ok "proceso en marcha"
else
    mal "el proceso no está corriendo"
    info "mira $SOPORTE/error.log"
fi

if [ -S "$SOCKET" ]; then
    ok "socket de estado disponible"
else
    mal "falta el socket en $SOCKET"
fi

# ─────────────────────────────────────────────────────────────── 2. Mando
titulo "2 · Mando por Bluetooth"

python3 - "$SOCKET" <<'PY'
import socket, struct, sys, time
ruta = sys.argv[1]
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(4)
    s.connect(ruta)
    t0 = time.time(); n = 0; conectado = 0; ultimo = None
    while time.time() - t0 < 2.0:
        d = b""
        while len(d) < 20:
            c = s.recv(20 - len(d))
            if not c: raise ConnectionError
            d += c
        m, b, lx, ly, rx, ry, gl, gr, conectado, _ = struct.unpack("<IIhhhhBBBB", d)
        ultimo = (b, lx, ly, rx, ry, gl, gr); n += 1
    hz = n / 2.0
    if conectado:
        print(f"  \033[1;32m✓\033[0m MANDO CONECTADO — {hz:.0f} tramas/s")
        b, lx, ly, rx, ry, gl, gr = ultimo
        print(f"    \033[2mstick izq ({lx}, {ly}) · stick der ({rx}, {ry}) · ZL {gl} ZR {gr} · botones 0x{b:08X}\033[0m")
        if hz < 5:
            print("  \033[1;33m•\033[0m tasa baja: el mando podría estar entrando en reposo")
    else:
        print("  \033[1;33m•\033[0m demonio activo pero SIN mando conectado")
        print("    \033[2mpulsa un botón; si no vuelve, mantén SYNC hasta que parpadeen los LEDs\033[0m")
except Exception as e:
    print(f"  \033[1;31m✗\033[0m no se pudo leer el estado ({e})")
PY

# ───────────────────────────────────────────────────────────────── 3. USB
titulo "3 · Mando por USB-C (opcional)"

if hidutil list 2>/dev/null | grep -qi "0x57e"; then
    ok "presente como gamepad HID real del sistema"
    info "$(hidutil list 2>/dev/null | grep -i '0x57e' | head -1 | awk '{print $1, $2, $8, $9}')"
else
    aviso "sin mando por cable (normal si juegas por Bluetooth)"
fi

# ──────────────────────────────────────────────────── 4. Runtimes de Wine
titulo "4 · Integración con Wine (juegos de Windows)"

ENCONTRADOS=0
while IFS= read -r bus; do
    [ -n "$bus" ] || continue
    destino="$(dirname "$bus")"
    # Etiqueta con ubicación: puede haber la misma app en dos sitios distintos.
    etiqueta="$(echo "$destino" | sed "s|/Contents/.*||; s|^$HOME|~|")"
    ENCONTRADOS=$((ENCONTRADOS+1))
    if [ -f "$destino/libSDL2-2.0.0.dylib" ]; then
        ok "shim instalada en «${etiqueta}»"
    else
        mal "«${etiqueta}» sin shim"
        info "arréglalo con: ./instalar.sh"
    fi
done < <(find -L /Applications ~/Applications -maxdepth 10 \
         -path "*/lib/wine/x86_64-unix/winebus.so" 2>/dev/null \
         | while read -r r; do realpath "$r" 2>/dev/null || echo "$r"; done | sort -u)

[ "$ENCONTRADOS" -eq 0 ] && aviso "no hay ningún runtime de Wine instalado"

# Un prefijo de Wine se reconoce por tener system.reg junto a drive_c: así
# cubrimos CrossOver, Whisky, Mythic, Wineskin, Heroic y prefijos sueltos.
BOTELLAS_OK=0; BOTELLAS_MAL=0
while IFS= read -r reg; do
    [ -n "$reg" ] || continue
    botella="$(dirname "$reg")"
    [ -d "$botella/drive_c" ] || continue
    if grep -q '"Enable SDL"=dword:00000001' "$reg" 2>/dev/null; then
        BOTELLAS_OK=$((BOTELLAS_OK + 1))
    else
        BOTELLAS_MAL=$((BOTELLAS_MAL + 1))
        mal "botella sin bus SDL: $(echo "$botella" | sed "s|^$HOME|~|")"
    fi
done < <(find -L "$HOME/Library/Application Support" "$HOME/Library/Containers" \
              "$HOME/Games" "$HOME/Applications" /Applications \
              -maxdepth 6 -name "system.reg" 2>/dev/null | sort -u)

if [ "$BOTELLAS_OK" -gt 0 ]; then
    ok "$BOTELLAS_OK botella(s) con el bus SDL activado"
fi
[ "$((BOTELLAS_OK + BOTELLAS_MAL))" -eq 0 ] && aviso "no se encontró ninguna botella de Wine"

if launchctl print "gui/$(id -u)/${ETIQUETA}.reparar" >/dev/null 2>&1; then
    ok "agente de mantenimiento activo (repone la shim tras actualizaciones)"
else
    mal "sin agente de mantenimiento: las actualizaciones romperán la integración"
    info "arréglalo con: ./instalar.sh"
fi

if pgrep -f winedevice >/dev/null 2>&1; then
    CARGADA=0
    for p in $(pgrep -f winedevice); do
        vmmap "$p" 2>/dev/null | grep -qE "x86_64-unix/libSDL2|libSDL2-real" && CARGADA=1
    done
    if [ "$CARGADA" = 1 ]; then
        ok "la sesión de Wine activa TIENE la shim cargada"
    else
        mal "hay una sesión de Wine SIN la shim"
        info "ciérrala: pkill -f winedevice; pkill -f wineserver   (wineserver -k NO basta)"
    fi
else
    info "no hay sesión de Wine activa"
fi

# ──────────────────────────────────────────────────────────── Veredicto
titulo "Veredicto"

if [ "$FALLOS" -eq 0 ]; then
    printf "  \033[1;32mLa cadena está intacta.\033[0m\n"
    printf "     \033[2mRecuerda cerrar la sesión de Wine tras instalar:\033[0m\n"
    printf "     \033[2mpkill -f winedevice; pkill -f wineserver\033[0m\n"
else
    printf "  \033[1;31m✗ %d problema(s) detectado(s).\033[0m\n" "$FALLOS"
    printf "     \033[2mCasi todo se arregla con ./instalar.sh — y si el fallo es de Wine,\033[0m\n"
    printf "     \033[2mcerrando la sesión con: pkill -f winedevice; pkill -f wineserver\033[0m\n"
    printf "     \033[2mDetalle completo en docs/SOLUCION-PROBLEMAS.md\033[0m\n"
fi
[ "$AVISOS" -gt 0 ] && printf "     \033[2m(%d aviso(s) informativo(s), no son errores)\033[0m\n" "$AVISOS"
echo
exit $([ "$FALLOS" -eq 0 ] && echo 0 || echo 1)
