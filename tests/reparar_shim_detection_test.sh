#!/bin/bash
# shellcheck disable=SC1091,SC2317
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/switch2bridge-shim-test.XXXXXX")"
trap 'find "$TEST_ROOT" -depth -delete' EXIT

mkdir -p "$TEST_ROOT/bin"
touch "$TEST_ROOT/libSDL2-2.0.0.dylib"

cat > "$TEST_ROOT/bin/otool" <<'EOF'
#!/bin/bash
case "${SWITCH2BRIDGE_TEST_MODE:-}" in
    portable)
        printf '\t@loader_path/libSDL2-real.dylib (compatibility version 3001.0.0)\n'
        ;;
    historica)
        printf '\t/Users/test/Library/Application Support/Switch2Bridge/libSDL2-real-Test.dylib (compatibility version 3001.0.0)\n'
        ;;
    *)
        printf '\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0)\n'
        ;;
esac
EOF
chmod +x "$TEST_ROOT/bin/otool"

PATH="$TEST_ROOT/bin:$PATH"
# shellcheck source=../reparar.sh
source "$ROOT/reparar.sh"

SWITCH2BRIDGE_TEST_MODE=portable shim_esta_integrada "$TEST_ROOT/libSDL2-2.0.0.dylib"
SWITCH2BRIDGE_TEST_MODE=historica shim_esta_integrada "$TEST_ROOT/libSDL2-2.0.0.dylib"

if SWITCH2BRIDGE_TEST_MODE=ajena shim_esta_integrada "$TEST_ROOT/libSDL2-2.0.0.dylib"; then
    echo "ERROR: una SDL ajena se identificó como shim integrada" >&2
    exit 1
fi

if SWITCH2BRIDGE_TEST_MODE=portable shim_esta_integrada "$TEST_ROOT/inexistente.dylib"; then
    echo "ERROR: una biblioteca inexistente se identificó como shim integrada" >&2
    exit 1
fi

echo "Detección de shim portable e histórica: OK"
