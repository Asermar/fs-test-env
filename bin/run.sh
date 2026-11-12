#!/bin/bash
# =============================================================================
# Ejecuta un escenario de tests de un plugin desde el HOST, en el motor que se pida.
#
#   cd <copia>                      # la raíz del proyecto (o de la copia de okoworktree)
#   <fs-test>/bin/run.sh --plugin OkoPermisos --sub main                       # MariaDB
#   <fs-test>/bin/run.sh --motor postgresql --plugin OkoPermisos --sub main    # PostgreSQL
#
# Opciones: --plugin <P> y --sub <escenario> (obligatorias), --file <XTest.php> (sólo ese fichero),
# --motor <mysql|postgresql> (def. mysql).
#
# ## POR QUÉ HACE FALTA, si ya existe la API del runner
#
# El runner web vive DENTRO del contenedor de test de la copia, y ahí no hay podman: no puede levantar
# el PostgreSQL compartido (`fstest-pg`), que tras un reinicio de la máquina se queda parado
# (unless-stopped, como toda la flota). Así que esto, en el host, hace por orden:
#
#   1. con postgresql, bin/pg-up.sh (idempotente: no toca nada si ya corre);
#   2. si el entorno de ese motor no está provisionado, lo provisiona dentro del contenedor de test
#      (la primera vez en PostgreSQL tarda unos segundos: sólo el core);
#   3. la misma petición `?action=run` de siempre, con `motor=`, y el resumen
#      `{ok, motor, fase, totals, failed}`.
#
# La API sigue valiendo sola, como siempre, para MariaDB.
#
# Salida: 0 si phpunit sale en verde; 1 si hay rojo, la API dice ok:false (el esquema del escenario no
# se pudo construir, no aislado…) o algo de lo anterior falla; 2 si la invocación es incorrecta.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MOTOR=mysql PLUGIN='' SUB='' FILE=''
while [ $# -gt 0 ]; do
    case "$1" in
        --motor)  MOTOR="${2:-}"; shift 2 || shift ;;
        --plugin) PLUGIN="${2:-}"; shift 2 || shift ;;
        --sub)    SUB="${2:-}"; shift 2 || shift ;;
        --file)   FILE="${2:-}"; shift 2 || shift ;;
        *) echo "ERROR: opción desconocida: '$1'." >&2
           echo "  uso: $0 [--motor mysql|postgresql] --plugin <P> --sub <escenario> [--file <XTest.php>]" >&2
           exit 2 ;;
    esac
done
case "$MOTOR" in mysql|postgresql) ;; *) echo "ERROR: motor desconocido: '$MOTOR' (mysql o postgresql)." >&2; exit 2 ;; esac
if [ -z "$PLUGIN" ] || [ -z "$SUB" ]; then
    echo "ERROR: faltan --plugin y --sub." >&2
    exit 2
fi

FS_PROJECT_ROOT="${FS_PROJECT_ROOT:-$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || echo "$PWD")}"
ENV_FILE="$FS_PROJECT_ROOT/.fs-test-env.env"
if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: '$FS_PROJECT_ROOT' no tiene entorno de test (.fs-test-env.env). Lánzalo desde la copia." >&2
    exit 1
fi
# SE LEEN SÓLO LAS CLAVES QUE HACEN FALTA, con sed, y no se hace `source`: el fichero es del proyecto,
# y cargarlo entero ejecutaría lo que lleve dentro y podría pisar MOTOR, PLUGIN, SUB o FILE, que ya
# vienen de los argumentos. Mismo criterio que _fs_env_lee en okoworktree.
lee() { sed -n "s/^$1=//p" "$ENV_FILE" | tail -1 | sed 's/^"\(.*\)"$/\1/'; }
TESTENV_CONTAINER="$(lee TESTENV_CONTAINER)"; TESTENV_HOST="$(lee TESTENV_HOST)"; FS_TEST_DIR="$(lee FS_TEST_DIR)"
TESTENV_DIR="$(lee TESTENV_DIR)"; TESTENV_DIR_POSTGRESQL="$(lee TESTENV_DIR_POSTGRESQL)"
for v in TESTENV_CONTAINER TESTENV_HOST FS_TEST_DIR; do
    [ -n "${!v:-}" ] || { echo "ERROR: $ENV_FILE no define $v." >&2; exit 1; }
done
DIR="${TESTENV_DIR:-$FS_PROJECT_ROOT/test-env/facturascripts}"
[ "$MOTOR" = postgresql ] && DIR="${TESTENV_DIR_POSTGRESQL:-${DIR}-postgresql}"

# --- 1) el servidor ---------------------------------------------------------------------------
if [ "$MOTOR" = postgresql ]; then
    "$SCRIPT_DIR/pg-up.sh" || { echo "ERROR: no pude levantar el PostgreSQL de test." >&2; exit 1; }
fi

# --- 2) el entorno de ese motor ---------------------------------------------------------------
if [ ! -f "$DIR/config.php" ] || [ ! -f "$DIR/warmup-schema.php" ]; then
    if [ "$MOTOR" = postgresql ] && [ ! -e "$DIR/Core" ]; then
        echo "ERROR: falta el entorno de PostgreSQL de esta copia ($DIR)." >&2
        echo "  Lo monta okoworktree, con su base y su rol:  okoworktree up <copia>" >&2
        exit 1
    fi
    echo "Provisionando el entorno de test ($MOTOR) dentro de $TESTENV_CONTAINER…"
    if ! podman exec -i -w "$FS_PROJECT_ROOT" -e FS_PROJECT_ROOT="$FS_PROJECT_ROOT" "$TESTENV_CONTAINER" \
            "$FS_TEST_DIR/bin/test-env-provision.sh" --motor "$MOTOR"; then
        echo "ERROR: la provisión del entorno de test ($MOTOR) falló (lo de arriba)." >&2
        exit 1
    fi
fi

# --- 3) la ejecución, por la API de siempre ---------------------------------------------------
url="${TESTENV_URL:-https://$TESTENV_HOST}/?action=run"
args=(--data-urlencode "plugin=$PLUGIN" --data-urlencode "sub=$SUB" --data-urlencode "motor=$MOTOR")
[ -n "$FILE" ] && args+=(--data-urlencode "file=$FILE")
if ! respuesta="$(curl -sS --fail-with-body -X POST "$url" "${args[@]}")"; then
    echo "ERROR: el runner no respondió bien en $url:" >&2
    printf '%s\n' "$respuesta" | tail -5 >&2
    exit 1
fi
if command -v jq >/dev/null 2>&1; then
    printf '%s' "$respuesta" | jq -c '{ok, motor, fase, aislamiento, exitCode, totals, failed, error}'
    ok="$(printf '%s' "$respuesta" | jq -r '.ok')"
    codigo="$(printf '%s' "$respuesta" | jq -r '.exitCode // 1')"
else
    printf '%s\n' "$respuesta"
    ok="$(printf '%s' "$respuesta" | php -r '$d = json_decode(stream_get_contents(STDIN), true); echo empty($d["ok"]) ? "false" : "true";')"
    codigo="$(printf '%s' "$respuesta" | php -r '$d = json_decode(stream_get_contents(STDIN), true); echo (int) ($d["exitCode"] ?? 1);')"
fi
[ "$ok" = true ] || exit 1
[ "$codigo" = 0 ] || exit 1
exit 0
