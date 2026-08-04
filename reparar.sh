#!/bin/bash
# reparar.sh — mantiene la integración con Wine al día, sin intervención.
#
# Se ejecuta solo (al iniciar sesión y cada pocas horas) y hace dos cosas:
#
#   1. Repone la shim de SDL en los runtimes de Wine donde falte. Las
#      actualizaciones de CrossOver sobrescriben su bundle y se la llevan por
#      delante; sin esto habría que reinstalar a mano cada vez.
#   2. Activa el bus SDL en las botellas que aún no lo tengan, incluidas las
#      creadas después de instalar.
#
# Es idempotente y silencioso: si no hay nada que hacer, no toca nada.
# También puede ejecutarse a mano para forzar una revisión.
set -uo pipefail

SOPORTE="$HOME/Library/Application Support/Switch2Bridge"
FUENTE_SHIM="$SOPORTE/shim_sdl.c"
REGISTRO="$SOPORTE/reparacion.log"

silencioso=0
[ "${1:-}" = "--silencioso" ] && silencioso=1

traza() {
    printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$REGISTRO"
    [ "$silencioso" = 1 ] || printf '  %s\n' "$*"
}

[ -f "$FUENTE_SHIM" ] || { traza "falta el código de la shim; ejecuta ./instalar.sh"; exit 1; }

cambios=0

# --------------------------------------------------------------------------- #
# 1. Runtimes de Wine                                                          #
# --------------------------------------------------------------------------- #
# Criterio objetivo: que exista winebus.so y una libSDL2 x86_64 que reexportar.
while IFS= read -r bus; do
    [ -n "$bus" ] || continue
    destino="$(dirname "$bus")"
    raiz="$(cd "$destino/../../.." 2>/dev/null && pwd)" || continue
    etiqueta="$(echo "$raiz" | sed "s|/Contents/.*||; s|^$HOME|~|")"

    # ¿Sigue ahí nuestra shim? La reconocemos por su dependencia con la copia
    # de la SDL original, que vive fuera del bundle.
    if [ -f "$destino/libSDL2-2.0.0.dylib" ] && \
       otool -L "$destino/libSDL2-2.0.0.dylib" 2>/dev/null | grep -q "Switch2Bridge/libSDL2-real"; then
        continue
    fi

    sdl=""
    while IFS= read -r candidata; do
        if file "$candidata" 2>/dev/null | grep -q "x86_64"; then sdl="$candidata"; break; fi
    done < <(find -L "$raiz" -name "libSDL2-2.0.0.dylib" -not -path "$destino/*" 2>/dev/null)
    [ -n "$sdl" ] || continue

    slug="$(echo "$etiqueta" | tr -c '[:alnum:]' '_' | sed 's/__*/_/g; s/^_//; s/_$//')"
    copia="$SOPORTE/libSDL2-real-${slug}.dylib"

    cp "$sdl" "$copia" 2>/dev/null || continue
    install_name_tool -id "$copia" "$copia" 2>/dev/null || true
    codesign -s - -f "$copia" >/dev/null 2>&1

    if clang -dynamiclib -arch x86_64 -O2 \
         -install_name libSDL2-2.0.0.dylib \
         -Wl,-reexport_library,"$copia" \
         "$FUENTE_SHIM" -o "$SOPORTE/shim-${slug}.dylib" 2>/dev/null; then
        codesign -s - -f "$SOPORTE/shim-${slug}.dylib" >/dev/null 2>&1
        if cp "$SOPORTE/shim-${slug}.dylib" "$destino/libSDL2-2.0.0.dylib" 2>/dev/null; then
            traza "shim repuesta en «${etiqueta}»"
            cambios=$((cambios + 1))
        fi
    fi
done < <(find -L /Applications ~/Applications -maxdepth 10 \
         -path "*/lib/wine/x86_64-unix/winebus.so" 2>/dev/null \
         | while read -r r; do realpath "$r" 2>/dev/null || echo "$r"; done | sort -u)

# --------------------------------------------------------------------------- #
# 2. Botellas                                                                  #
# --------------------------------------------------------------------------- #
# Un prefijo de Wine se reconoce sin ambigüedad por tener system.reg junto a
# drive_c. Buscamos así en vez de por nombre de producto, para cubrir CrossOver,
# Whisky, Mythic, Wineskin, Heroic y cualquier prefijo suelto.
while IFS= read -r reg; do
    [ -n "$reg" ] || continue
    botella="$(dirname "$reg")"
    [ -d "$botella/drive_c" ] || continue
    grep -q '"Enable SDL"=dword:00000001' "$reg" 2>/dev/null && continue

    printf '\n[System\\\\CurrentControlSet\\\\Services\\\\winebus\\\\Parameters] 0\n"Enable SDL"=dword:00000001\n' >> "$reg"
    traza "bus SDL activado en $(echo "$botella" | sed "s|^$HOME|~|")"
    cambios=$((cambios + 1))
done < <(find -L "$HOME/Library/Application Support" "$HOME/Library/Containers" \
              "$HOME/Games" "$HOME/Applications" /Applications \
              -maxdepth 6 -name "system.reg" 2>/dev/null | sort -u)

# --------------------------------------------------------------------------- #

if [ "$cambios" -gt 0 ]; then
    traza "$cambios cambio(s). Cierra la sesión de Wine para que surtan efecto:"
    traza "  pkill -f winedevice; pkill -f wineserver"
else
    [ "$silencioso" = 1 ] || traza "todo en orden, nada que reparar"
fi
exit 0
