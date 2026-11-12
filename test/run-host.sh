#!/usr/bin/env bash
# =============================================================================
# Batería de bin/run.sh: el .fs-test-env.env del proyecto NO puede pisar lo que llega por argumentos.
#
#   test/run-host.sh
#
# run.sh hacía `source` de ese fichero después de leer sus argumentos, así que un PLUGIN= o un MOTOR=
# dentro de él cambiaba qué se ejecutaba. Ahora lee sólo sus claves con sed. Se comprueba contra el
# run.sh REAL, con un proyecto de pega cuyo .fs-test-env.env intenta pisar PLUGIN y MOTOR, y un runner
# de pega (php -S en 127.0.0.1) que devuelve lo que recibió.
#
# **AUTOCONTENIDA**: sin contenedores ni red de fuera. Sólo php y jq.
# =============================================================================
set -uo pipefail
T="$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd)"
OK=0 FALLOS=0
ok()  { OK=$((OK+1));         printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
mal() { FALLOS=$((FALLOS+1)); printf '  \033[1;31m✗\033[0m %s\n' "$*"; }
command -v jq >/dev/null || { echo "NO COMPROBADO: falta jq." >&2; exit 2; }

BASE="$(mktemp -d)"; trap '[ -n "${PID:-}" ] && kill "$PID" 2>/dev/null; rm -rf -- "$BASE"' EXIT
mkdir -p "$BASE/proyecto/test-env/facturascripts"
: > "$BASE/proyecto/test-env/facturascripts/config.php"; : > "$BASE/proyecto/test-env/facturascripts/warmup-schema.php"
cat > "$BASE/proyecto/.fs-test-env.env" <<ENV
TESTENV_CONTAINER="contenedor-de-pega"
TESTENV_HOST="runner.ejemplo"
FS_TEST_DIR="$T"
TESTENV_DIR="$BASE/proyecto/test-env/facturascripts"
PLUGIN="pisado"
MOTOR="postgresql"
ENV
cat > "$BASE/router.php" <<'PHP'
<?php
header('Content-Type: application/json');
echo json_encode(['ok' => true, 'exitCode' => 0, 'motor' => $_POST['motor'] ?? '', 'error' => 'plugin=' . ($_POST['plugin'] ?? '')]);
PHP
PUERTO=$((20000 + $$ % 20000))
php -S "127.0.0.1:$PUERTO" "$BASE/router.php" >/dev/null 2>&1 & PID=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$PUERTO/" && break; sleep 0.1; done

printf '\n\033[1;36m— el .fs-test-env.env no pisa los argumentos —\033[0m\n'
sal="$(cd "$BASE/proyecto" && FS_PROJECT_ROOT="$BASE/proyecto" TESTENV_URL="http://127.0.0.1:$PUERTO" \
        "$T/bin/run.sh" --plugin Real --sub main 2>&1)"; rc=$?
json="$(printf '%s\n' "$sal" | grep '^{' | tail -1)"
[ "$(printf '%s' "$json" | jq -r '.error')" = "plugin=Real" ] && ok "el plugin es el del argumento, no el del fichero" || mal "el plugin no es el del argumento: $sal"
[ "$(printf '%s' "$json" | jq -r '.motor')" = "mysql" ] && ok "el motor es el de por defecto, no el del fichero" || mal "el motor no es el de los argumentos: $sal"
[ "$rc" = 0 ] && ok "y run.sh sale con 0 (el runner de pega dice verde)" || mal "run.sh salió con $rc: $sal"

printf '\n'
[ "$FALLOS" -eq 0 ] && { printf '\033[1;32m%s comprobaciones, todas en verde.\033[0m\n' "$OK"; exit 0; }
printf '\033[1;31m%s en verde, %s FALLIDAS.\033[0m\n' "$OK" "$FALLOS"; exit 1
