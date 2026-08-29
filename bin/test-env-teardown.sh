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
# La BD de pruebas se elimina SIEMPRE. `--keep-db` se retiró: conservar los datos de una corrida
# anterior dejó de ser algo que este arnés ofrezca, y pasarlo ahora FALLA (ver el parseo).
#
# Uso:
#   test-env-teardown.sh                      # borra el directorio y la BD de pruebas
#
# Para refrescar la BD SIN rehacer los ficheros —el caso frecuente y barato— esto no es la
# herramienta: es `test-env-provision.sh --recrear-bd`.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Raíz del proyecto: la dice quien invoca. Subir dos niveles desde aquí era correcto cuando el arnés
# vivía DENTRO del proyecto como `test-bin/`; desde que vive en `Tooling/fs-test` resuelve a
# `~/Dev/Tooling`, que no es un proyecto — el mismo defecto que la v3.0.0 arregló en el
# provisionador, en `init-project.sh` y en el runner web, y que aquí quedó sin arreglar.
#
# NO ERA INOCUO: con el default viejo, la orden documentada en el CLAUDE.md de Mesa/FS
# (`~/Dev/Tooling/fs-test/bin/test-env-teardown.sh` desde la raíz del proyecto) buscaba el
# `config.php` en `Tooling/src/`, no lo encontraba y OMITÍA el borrado de la base con un aviso. O
# sea que el teardown documentado no tiraba la base, que es su trabajo principal.
FS_PROJECT_ROOT="${FS_PROJECT_ROOT:-$PWD}"
[ -f "$FS_PROJECT_ROOT/.fs-test-env.env" ] && . "$FS_PROJECT_ROOT/.fs-test-env.env"

FS_CORE_DIR="${FS_CORE_DIR:-src}"
CORE_ROOT="$FS_PROJECT_ROOT/$FS_CORE_DIR"
SRC_CONFIG="$CORE_ROOT/config.php"
TESTENV_DIR="${TESTENV_DIR:-$FS_PROJECT_ROOT/test-env/facturascripts}"
TEST_DB="${TEST_DB:-fs_test}"

# --- parseo: `--keep-db` SE RETIRÓ Y FALLA ---------------------------------------------------
#
# Va aquí arriba, ANTES del `rm -rf`, para que una invocación con el flag viejo no borre nada.
#
# ## POR QUÉ FALLA EN VEZ DE IGNORARSE, que es la parte que no es obvia
#
# Ignorar un flag desconocido haría que este script TIRASE la base justo cuando quien lo invocó
# pedía conservarla —el daño exacto que el flag existía para evitar— y sin una línea de aviso. Y
# quien lo tuviera escrito en un guion o en un botón no se enteraría nunca de que su suposición
# dejó de valer. Un flag que ya no significa lo que su llamador cree tiene que fallar.
#
# ## POR QUÉ SE RETIRÓ (Alexis, 27-ago-2026)
#
# El único escenario que lo justificaba es rehacer los FICHEROS del entorno sin rehacer la base, y
# el precio de recrear la base es menor que el de permitir contaminación y luego tests falsos: es
# una elección de riesgo, no de comodidad. Recrear cuesta minutos; un verde sobre una base
# contaminada cuesta una decisión equivocada, y eso ya se pagó.
#
# Medido antes de retirarlo: NADIE lo invocaba —ni un script ni un botón—, así que no hay llamador
# que romper.
for _a in "$@"; do
    case "$_a" in
        --keep-db)
            cat >&2 <<'FIN'
ERROR: «--keep-db» se retiró y esta invocación NO ha hecho nada.

  No se ignora a propósito: si se ignorase, este teardown tiraría la BD de pruebas justo cuando
  quien lo invocó pedía conservarla, y en silencio. Si lo tienes escrito en un guion o en un
  botón, ése es el sitio a corregir.

  Por qué salió: conservar los datos de una corrida anterior dejó de ser algo que el arnés
  ofrezca. Recrear la base cuesta minutos; un «tests en verde» sobre datos ajenos cuesta una
  decisión equivocada.

  Qué usar en su lugar:

      test-env-provision.sh --recrear-bd    refresca la BD y CONSERVA el clon del core y su
                                            vendor, que es lo que costaba minutos. Es el caso
                                            para el que se usaba --keep-db al revés.
      test-env-teardown.sh                  se lo lleva todo: directorio y BD.
FIN
            exit 2
            ;;
        *)
            echo "ERROR: opción desconocida: '$_a'." >&2
            echo "  Este script no acepta opciones: borra el directorio del entorno y la BD de" >&2
            echo "  pruebas, siempre. Se rechaza en vez de ignorarse para que un flag que alguien" >&2
            echo "  crea que significa algo no pase inadvertido." >&2
            exit 2
            ;;
    esac
done

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
echo "BD test    : $TEST_DB (se elimina)"
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

# --- 2) eliminar la BD de pruebas (siempre) ---
if [ ! -f "$SRC_CONFIG" ]; then
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
    # La contraseña por ENTORNO y no en argv: `/proc/<pid>/cmdline` lo lee cualquier usuario de la
    # máquina, `/proc/<pid>/environ` sólo su dueño. Mismo motivo que en el provisionador.
    FS_TEST_DB_PASS="$DB_PASS" php -r '
    $m = new mysqli($argv[1], $argv[3], (string) getenv("FS_TEST_DB_PASS"), "", (int)$argv[2]);
    if ($m->connect_errno) { fwrite(STDERR, "conexion: " . $m->connect_error . "\n"); exit(1); }
    $db = $m->real_escape_string($argv[5]);
    $m->query("DROP DATABASE IF EXISTS `$db`");
    echo "   BD eliminada: " . $argv[5] . "\n";
    ' "$DB_HOST" "$DB_PORT" "$DB_USER" "" "$TEST_DB"
fi

echo
printf '%s================================================================%s\n' "$C_OK" "$C_RESET"
log_ok "Entorno de pruebas eliminado. Se recreará con test-env-provision.sh cuando haga falta."
printf '%s================================================================%s\n' "$C_OK" "$C_RESET"
