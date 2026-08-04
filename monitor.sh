#!/bin/bash
# monitor.sh — visor en vivo del mando. Útil para comprobar el mapeo.
exec python3 - "$HOME/Library/Application Support/Switch2Bridge/estado.sock" <<'PY'
import socket, struct, sys, os

RUTA = sys.argv[1]
MAGIA = 0x53325031

BOTONES = [
    (0x00000008, "A"), (0x00000004, "B"), (0x00000002, "X"), (0x00000001, "Y"),
    (0x00400000, "L"), (0x00000040, "R"), (0x00800000, "ZL"), (0x00000080, "ZR"),
    (0x00000100, "−"), (0x00000200, "+"), (0x00001000, "HOME"), (0x00002000, "CAPT"),
    (0x00000800, "L3"), (0x00000400, "R3"),
    (0x00020000, "↑"), (0x00010000, "↓"), (0x00080000, "←"), (0x00040000, "→"),
    (0x01000000, "GR"), (0x02000000, "GL"), (0x00004000, "C"),
]

def barra(valor, ancho=21):
    """Dibuja un eje -32767..32767 como barra centrada."""
    centro = ancho // 2
    pos = int(round((valor / 32767) * centro)) + centro
    pos = max(0, min(ancho - 1, pos))
    fila = ["·"] * ancho
    fila[centro] = "|"
    fila[pos] = "●"
    return "".join(fila)

try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(5)
    s.connect(RUTA)
except Exception as e:
    print(f"No se pudo conectar al demonio: {e}")
    print("Comprueba que está en marcha con ./estado.sh")
    sys.exit(1)

print("\033[?25l", end="")  # oculta el cursor
print("Mueve los sticks y pulsa botones. Ctrl+C para salir.\n")
try:
    while True:
        datos = b""
        while len(datos) < 20:
            trozo = s.recv(20 - len(datos))
            if not trozo:
                print("\nEl demonio cerró la conexión.")
                sys.exit(1)
            datos += trozo
        magia, botones, lx, ly, rx, ry, gl, gr, conectado, _ = struct.unpack("<IIhhhhBBBB", datos)
        if magia != MAGIA:
            continue

        pulsados = " ".join(n for m, n in BOTONES if botones & m) or "—"
        estado = "\033[1;32mCONECTADO\033[0m" if conectado else "\033[1;31mDESCONECTADO\033[0m"

        sys.stdout.write("\033[6A" if getattr(barra, "_pintado", False) else "")
        barra._pintado = True
        print(f"  Estado: {estado}          \n"
              f"  Stick izq  X {barra(lx)}  {lx:6d}   Y {barra(ly)}  {ly:6d}\n"
              f"  Stick der  X {barra(rx)}  {rx:6d}   Y {barra(ry)}  {ry:6d}\n"
              f"  Gatillos   ZL {gl:3d}   ZR {gr:3d}                         \n"
              f"  Botones: {pulsados:<60}\n")
except KeyboardInterrupt:
    pass
finally:
    print("\033[?25h", end="")  # restaura el cursor
PY
