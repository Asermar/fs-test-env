#!/bin/bash
# =============================================================================
# Levanta el entorno de test (contenedor) de forma idempotente.
#
#   - Si el contenedor YA está corriendo: no toca nada (la provisión del entorno
#     ocurre al arrancar el contenedor, TESTENV_AUTO_PROVISION=1).
#   - Si está parado o no existe: lo levanta con el compose del proyecto
#     (<engine>-compose up -d <servicio>). Al arrancar, el contenedor ejecuta
#     test-env-provision.sh, que CREA el entorno de pruebas si falta y lo
#     ACTUALIZA si ya existe (clona/pull del core, composer, BD, plugins, warm-up).
#
# No interactivo: pensado para lanzarse desde un botón (p.ej. la sección Scripts
# de OkoGit) o desde la terminal. La configuración se lee de <proyecto>/.fs-test-env.env
# (generado por bin/init-project.sh); todo es sobreescribible por entorno.
#
# Variables (todas opcionales; con defaults / autodetección):
#   CONTAINER_ENGINE     'podman' (def) o 'docker'.
#   TESTENV_SERVICE      nombre del servicio en el compose (def: testmesafs -> fs-testenv).
#   TESTENV_CONTAINER    nombre del contenedor (def: derivado del servicio).
#   TESTENV_COMPOSE_FILE ruta al compose. Si no se define, se autodetecta bajo la raíz.
#   FS_PROJECT_ROOT      raíz del proyecto (def: el padre de test-bin/).
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FS_PROJECT_ROOT="${FS_PROJECT_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
[ -f "$FS_PROJECT_ROOT/.fs-test-env.env" ] && . "$FS_PROJECT_ROOT/.fs-test-env.env"

CONTAINER_ENGINE="${CONTAINER_ENGINE:-podman}"
TESTENV_SERVICE="${TESTENV_SERVICE:-fs-testenv}"
TESTENV_CONTAINER="${TESTENV_CONTAINER:-$TESTENV_SERVICE}"

# --- motor de contenedores y su comando compose ---
if ! command -v "$CONTAINER_ENGINE" >/dev/null 2>&1; then
    echo "ERROR: no se encuentra el motor de contenedores '$CONTAINER_ENGINE'." >&2
    exit 1
fi
case "$CONTAINER_ENGINE" in
    podman) COMPOSE=(podman-compose) ;;
    docker) COMPOSE=(docker compose) ;;
    *)      echo "ERROR: CONTAINER_ENGINE '$CONTAINER_ENGINE' no soportado (podman|docker)." >&2; exit 1 ;;
esac
if ! command -v "${COMPOSE[0]}" >/dev/null 2>&1; then
    echo "ERROR: no se encuentra '${COMPOSE[*]}' para el motor '$CONTAINER_ENGINE'." >&2
    exit 1
fi

# --- localizar el fichero compose ---
find_compose() {
    if [ -n "${TESTENV_COMPOSE_FILE:-}" ]; then
        # ruta absoluta o relativa a la raíz del proyecto
        case "$TESTENV_COMPOSE_FILE" in
            /*) echo "$TESTENV_COMPOSE_FILE" ;;
            *)  echo "$FS_PROJECT_ROOT/$TESTENV_COMPOSE_FILE" ;;
        esac
        return
    fi
    local candidates=()
    if [ "$CONTAINER_ENGINE" = "podman" ]; then
        candidates=(
            "$FS_PROJECT_ROOT/podman/podman-compose.yaml"
            "$FS_PROJECT_ROOT/podman-compose.yaml"
        )
    else
        candidates=(
            "$FS_PROJECT_ROOT/docker-compose.yaml"
            "$FS_PROJECT_ROOT/docker/docker-compose.yaml"
            "$FS_PROJECT_ROOT/compose.yaml"
        )
    fi
    local f
    for f in "${candidates[@]}"; do
        [ -f "$f" ] && { echo "$f"; return; }
    done
    return 1
}

COMPOSE_FILE="$(find_compose || true)"
if [ -z "$COMPOSE_FILE" ] || [ ! -f "$COMPOSE_FILE" ]; then
    echo "ERROR: no se encuentra el fichero compose del proyecto." >&2
    echo "       Define TESTENV_COMPOSE_FILE en .fs-test-env.env (ruta al compose)." >&2
    exit 1
fi

# --- aviso informativo si el tooling está desfasado (no bloquea) ---
[ -x "$SCRIPT_DIR/version.sh" ] && "$SCRIPT_DIR/version.sh" || true
echo

# --- estado del contenedor ---
status="$("$CONTAINER_ENGINE" inspect -f '{{.State.Status}}' "$TESTENV_CONTAINER" 2>/dev/null || echo absent)"
if [ "$status" = "running" ]; then
    echo "✓ '$TESTENV_CONTAINER' ya está levantado. Nada que hacer."
    exit 0
fi

echo ">> Levantando '$TESTENV_SERVICE' con: ${COMPOSE[*]} -f $COMPOSE_FILE up -d"
echo "   (estado previo del contenedor: $status)"
( cd "$(dirname "$COMPOSE_FILE")" && "${COMPOSE[@]}" -f "$COMPOSE_FILE" up -d "$TESTENV_SERVICE" )

echo "✓ '$TESTENV_CONTAINER' levantado. El arranque provisiona/actualiza el entorno de pruebas."
