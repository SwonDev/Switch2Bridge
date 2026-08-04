#!/bin/bash
# estado.sh — diagnóstico rápido del puente.
set -uo pipefail

SOPORTE="$HOME/Library/Application Support/Switch2Bridge"
SOCKET="$SOPORTE/estado.sock"
ETIQUETA="dev.swondev.switch2bridge"

ok()   { printf "  \033[1;32m✓\033[0m %s\n" "$*"; }
mal()  { printf "  \033[1;31m✗\033[0m %s\n" "$*"; }
info() { printf "  \033[1;33m•\033[0m %s\n" "$*"; }

echo
printf "\033[1;34m── Puente Switch 2 Pro Controller ──\033[0m\n"

# 1. Demonio
if launchctl print "gui/$(id -u)/$ETIQUETA" >/dev/null 2>&1; then
    ok "demonio cargado en launchd"
else
    mal "demonio NO cargado (ejecuta ./instalar.sh)"
fi

# 2. Socket
if [ -S "$SOCKET" ]; then
    ok "socket de estado disponible"
else
    mal "socket ausente en $SOCKET"
fi

# 3. Mando: leemos una trama real
python3 - "$SOCKET" <<'PY'
import socket, struct, sys
ruta = sys.argv[1]
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(3)
    s.connect(ruta)
    datos = b""
    while len(datos) < 20:
        trozo = s.recv(20 - len(datos))
        if not trozo:
            raise TimeoutError
        datos += trozo
    magia, botones, lx, ly, rx, ry, gl, gr, conectado, _ = struct.unpack("<IIhhhhBBBB", datos)
    if magia != 0x53325031:
        print("  \033[1;31m✗\033[0m trama no reconocida")
    elif conectado:
        print(f"  \033[1;32m✓\033[0m MANDO CONECTADO")
        print(f"      stick izq: ({lx:6d}, {ly:6d})   stick der: ({rx:6d}, {ry:6d})")
        print(f"      gatillos: L={gl:3d} R={gr:3d}   botones: 0x{botones:08X}")
    else:
        print("  \033[1;33m•\033[0m demonio activo, pero el mando no está conectado")
        print("      Enciéndelo y mantén SYNC pulsado hasta que parpadeen los LEDs.")
except (TimeoutError, socket.timeout):
    print("  \033[1;33m•\033[0m el demonio no emite datos todavía (mando desconectado)")
except Exception as e:
    print(f"  \033[1;31m✗\033[0m no se pudo leer el estado: {e}")
PY

# 4. Integración con CrossOver
for candidato in "/Applications/CrossOver.app" "/Applications/CrossOver Preview.app"; do
    CO="$candidato/Contents/SharedSupport/CrossOver"
    # Sólo aplica a instalaciones que traen la SDL original que reexportamos.
    [ -f "$CO/lib64/libSDL2-2.0.0.dylib" ] || continue
    if [ -f "$CO/lib/wine/x86_64-unix/libSDL2-2.0.0.dylib" ]; then
        ok "shim de SDL instalada en $(basename "$candidato")"
    else
        mal "shim ausente en $(basename "$candidato") (reejecuta ./instalar.sh)"
    fi
done

BOTELLAS="$HOME/Library/Application Support/CrossOver/Bottles"
if [ -d "$BOTELLAS" ]; then
    for botella in "$BOTELLAS"/*; do
        [ -d "$botella" ] || continue
        if grep -q '"Enable SDL"=dword:00000001' "$botella/system.reg" 2>/dev/null; then
            ok "botella «$(basename "$botella")»: bus SDL activado"
        else
            mal "botella «$(basename "$botella")»: bus SDL desactivado"
        fi
    done
fi

# 5. ¿Wine tiene la shim cargada ahora mismo?
PIDS=$(pgrep -f winedevice 2>/dev/null || true)
if [ -n "$PIDS" ]; then
    CARGADA=0
    for p in $PIDS; do
        # grep de macOS no admite \| en BRE: hay que usar -E.
        if vmmap "$p" 2>/dev/null | grep -qE "x86_64-unix/libSDL2|libSDL2-real"; then CARGADA=1; fi
    done
    [ "$CARGADA" = 1 ] && ok "Wine está usando la shim ahora mismo" \
                       || info "Wine corre con la SDL original: reinicia la botella (pkill -f winedevice)"
else
    info "no hay sesión de Wine activa"
fi
echo
