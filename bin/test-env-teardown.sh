#!/bin/bash
# =============================================================================
# Elimina el entorno de pruebas de FacturaScripts (inverso de test-env-provision.sh).
#
# Borra el core clonado (TESTENV_DIR) y, por defecto, la BD de pruebas, dejando el
# equipo SIN entorno de test. test-env-provision.sh lo vuelve a crear (clon, vendor,
# config, enlaces y esquema) cuando haga falta.
#
# NO toca la instalación ni la BD de TRABAJO: salvaguarda TEST_DB != BD de trabajo,
# y el directorio a borrar debe estar DENTRO del proyecto. No interactivo (pensado
# para un botón de OkoGit). Idempotente: si ya no está, no hace nada.
#
# La config se lee de <proyecto>/.fs-test-env.env (igual que el provisionador).
#
# Uso:
#   .sync/... test-env-teardown.sh            # borra el directorio + la BD de pruebas
#   test-env-teardown.sh --keep-db            # borra solo el directorio, conserva la BD
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FS_PROJECT_ROOT="${FS_PROJECT_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
[ -f "$FS_PROJECT_ROOT/.fs-test-env.env" ] && . "$FS_PROJECT_ROOT/.fs-test-env.env"

FS_CORE_DIR="${FS_CORE_DIR:-src}"
CORE_ROOT="$FS_PROJECT_ROOT/$FS_CORE_DIR"
SRC_CONFIG="$CORE_ROOT/config.php"
TESTENV_DIR="${TESTENV_DIR:-$FS_PROJECT_ROOT/test-env/facturascripts}"
TEST_DB="${TEST_DB:-fs_test}"

KEEP_DB=0
[ "${1:-}" = "--keep-db" ] && KEEP_DB=1

# --- salida de progreso (coloreada + con hora), alineada con test-env-provision.sh ---
# Color por defecto: la ventana de OkoGit no es un TTY pero renderiza ANSI; NO_COLOR
# lo desactiva. Los printf de bash se vuelcan al instante (sin buffering).
if [ -n "${NO_COLOR:-}" ]; then
    C_RESET='' C_STEP='' C_OK='' C_WARN=''
else
    C_RESET=$'\033[0m'; C_STEP=$'\033[1;36m'; C_OK=$'\033[1;32m'; C_WARN=$'\033[1;33m'
fi
log_step() { printf '%s[%s] >> %s%s\n' "$C_STEP" "$(date +%H:%M:%S)" "$*" "$C_RESET"; }
log_ok()   { printf '%s[%s] OK %s%s\n' "$C_OK" "$(date +%H:%M:%S)" "$*" "$C_RESET"; }
log_warn() { printf '%s[%s] !! %s%s\n' "$C_WARN" "$(date +%H:%M:%S)" "$*" "$C_RESET"; }

# --- salvaguardas del directorio a borrar (evita un rm -rf peligroso) ---
case "$TESTENV_DIR" in
    "" | "/" | "$HOME" | "$FS_PROJECT_ROOT")
        echo "ERROR: TESTENV_DIR inseguro para borrar ('$TESTENV_DIR')." >&2
        exit 1
        ;;
esac
case "$TESTENV_DIR" in
    "$FS_PROJECT_ROOT"/*) : ;;
    *)
        echo "ERROR: TESTENV_DIR ('$TESTENV_DIR') no está dentro de FS_PROJECT_ROOT" >&2
        echo "       ('$FS_PROJECT_ROOT'); por seguridad no lo borro." >&2
        exit 1
        ;;
esac

printf '%s================================================================%s\n' "$C_STEP" "$C_RESET"
printf '%sEliminación del entorno de pruebas%s\n' "$C_STEP" "$C_RESET"
echo "Directorio : $TESTENV_DIR"
echo "BD test    : $TEST_DB $([ "$KEEP_DB" -eq 1 ] && echo '(se conserva)' || echo '(se elimina)')"
printf '%s================================================================%s\n' "$C_STEP" "$C_RESET"

# --- 1) borrar el directorio del core de pruebas ---
if [ -d "$TESTENV_DIR" ]; then
    log_step "Borrando directorio del entorno de pruebas..."
    rm -rf "$TESTENV_DIR"
    log_ok "Directorio eliminado: $TESTENV_DIR"
    # si el padre (p. ej. test-env/) queda vacío, lo quitamos también
    parent="$(dirname "$TESTENV_DIR")"
    if [ -d "$parent" ] && [ -z "$(ls -A "$parent" 2>/dev/null)" ]; then
        rmdir "$parent" && log_ok "Directorio padre vacío eliminado: $parent"
    fi
else
    log_step "El directorio ya no existe, nada que borrar: $TESTENV_DIR"
fi

# --- 2) eliminar la BD de pruebas (salvo --keep-db) ---
if [ "$KEEP_DB" -eq 1 ]; then
    log_step "Se conserva la BD de pruebas ($TEST_DB) por --keep-db."
elif [ ! -f "$SRC_CONFIG" ]; then
    log_warn "No existe $SRC_CONFIG; no puedo leer credenciales, omito el borrado de la BD."
elif ! command -v php >/dev/null 2>&1; then
    log_warn "Falta 'php'; omito el borrado de la BD de pruebas."
else
    cfg() { php -r "require '$SRC_CONFIG'; echo defined('$1') ? constant('$1') : '';"; }
    DB_HOST="$(cfg FS_DB_HOST)"
    DB_PORT="$(cfg FS_DB_PORT)"
    DB_USER="$(cfg FS_DB_USER)"
    DB_PASS="$(cfg FS_DB_PASS)"
    DB_WORK="$(cfg FS_DB_NAME)"

    # salvaguarda: NUNCA la BD de trabajo
    if [ -z "$TEST_DB" ] || [ "$TEST_DB" = "$DB_WORK" ]; then
        echo "ERROR: TEST_DB ('$TEST_DB') vacía o igual a la BD de trabajo ('$DB_WORK'); no la borro." >&2
        exit 1
    fi

    log_step "Eliminando la BD de pruebas ($TEST_DB)..."
    php -r '
    $m = new mysqli($argv[1], $argv[3], $argv[4], "", (int)$argv[2]);
    if ($m->connect_errno) { fwrite(STDERR, "conexion: " . $m->connect_error . "\n"); exit(1); }
    $db = $m->real_escape_string($argv[5]);
    $m->query("DROP DATABASE IF EXISTS `$db`");
    echo "   BD eliminada: " . $argv[5] . "\n";
    ' "$DB_HOST" "$DB_PORT" "$DB_USER" "$DB_PASS" "$TEST_DB"
fi

echo
printf '%s================================================================%s\n' "$C_OK" "$C_RESET"
log_ok "Entorno de pruebas eliminado. Se recreará con test-env-provision.sh cuando haga falta."
printf '%s================================================================%s\n' "$C_OK" "$C_RESET"
