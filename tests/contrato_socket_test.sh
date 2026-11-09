#!/bin/bash
# Contrato aislado del ABI S2P1 y del servidor multicliente.
#
# Compila las fuentes reales del daemon con el test; no instala nada, no arranca
# el daemon, no toca Bluetooth/USB/Wine y nunca abre el socket real de estado.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/s2p1.XXXXXX")"
# macOS limita sun_path a 104 bytes; /tmp es el respaldo determinista si TMPDIR
# es demasiado largo.
if (( ${#TEST_ROOT} + 12 > 103 )); then
    rm -rf "$TEST_ROOT"
    TEST_ROOT="$(mktemp -d /tmp/s2p1.XXXXXX)"
fi
trap 'rm -rf "$TEST_ROOT"' EXIT

SOCKET="$TEST_ROOT/estado.sock"
if (( ${#SOCKET} >= 104 )); then
    echo "ERROR: ruta de socket demasiado larga (${#SOCKET} bytes)" >&2
    exit 1
fi

mkdir -p "$TEST_ROOT/home"
export HOME="$TEST_ROOT/home"
export CFFIXED_USER_HOME="$TEST_ROOT/home"
export S2P1_SOCKET="$SOCKET"
export TMPDIR="$TEST_ROOT/tmp"
mkdir -p "$TMPDIR"

SWIFTC="$(/usr/bin/xcrun --find swiftc)"
SDK="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
TARGET="$(/usr/bin/uname -m)-apple-macosx15.0"
"$SWIFTC" -swift-version 6 -target "$TARGET" -sdk "$SDK" -parse-as-library -Onone \
    "$ROOT/daemon/Sources/Switch2Bridge/Rutas.swift" \
    "$ROOT/daemon/Sources/Switch2Bridge/Protocolo.swift" \
    "$ROOT/daemon/Sources/Switch2Bridge/ServidorEstado.swift" \
    "$ROOT/tests/contrato_socket_test.swift" \
    -o "$TEST_ROOT/contrato_socket_test"

"$TEST_ROOT/contrato_socket_test" "$SOCKET"
