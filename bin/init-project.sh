#!/bin/bash
# =============================================================================
# Generador de la configuración del despliegue del entorno de test.
#
# - Crea/actualiza <proyecto>/.fs-test-env.env (config del despliegue).
# - Renderiza, a partir de templates/, las piezas del proyecto en
#   <proyecto>/.fs-test-env/ :
#     * test.conf   -> vhost apache (móntalo en el contenedor).
#     * service.yaml -> servicio compose (pégalo en tu podman/docker-compose).
#
# No hardcodea nada del proyecto: pregunta (o toma de entorno / del .env existente)
# y sustituye los placeholders @@VAR@@ de las plantillas.
#
# Uso:  test-bin/bin/init-project.sh            (interactivo)
#       VAR=... test-bin/bin/init-project.sh    (no interactivo, toma de entorno)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # test-bin/bin
SUBMODULE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"                # test-bin
FS_PROJECT_ROOT="${FS_PROJECT_ROOT:-$(cd "$SUBMODULE_DIR/.." && pwd)}"

ENV_FILE="$FS_PROJECT_ROOT/.fs-test-env.env"
OUT_DIR="$FS_PROJECT_ROOT/.fs-test-env"

# valores previos (si ya existe) como defaults
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

INTERACTIVE=1
[ -t 0 ] || INTERACTIVE=0

ask() {  # ask VAR "pregunta" "default"
    local var="$1" prompt="$2" def="${3:-}"
    local cur="${!var:-$def}"
    if [ "$INTERACTIVE" = "1" ]; then
        local val
        read -rp "$prompt [$cur]: " val
        printf -v "$var" '%s' "${val:-$cur}"
    else
        printf -v "$var" '%s' "$cur"
    fi
}

echo ">> Configuración del entorno de test para: $FS_PROJECT_ROOT"
ask FS_CORE_DIR            "Carpeta del core (src | .)" "src"
ask TESTENV_REPO_PATH      "Ruta absoluta del proyecto (host=contenedor)" "$FS_PROJECT_ROOT"
ask TEST_DB                "Nombre de la BD de pruebas" "fs_test"
ask CORE_REPO              "Repositorio del core" "https://github.com/NeoRazorX/facturascripts.git"
ask CORE_BRANCH            "Rama o tag del core (vacío = versión instalada, v<Kernel::version()>)" ""
ask FS_LANG                "Idioma (FS_LANG)" "es_ES"
ask FS_TIMEZONE            "Zona horaria (FS_TIMEZONE)" "UTC"
ask TEST_WEB_TITLE         "Título del runner web" "Tests de plugins"
ask TEST_WEB_URL           "URL del runner web (informativa)" ""
ask TESTENV_SERVICE        "Nombre del servicio compose" "fs-testenv"
ask TESTENV_CONTAINER      "container_name" "fs-testenv"
ask TESTENV_HOST           "Host (ServerName / traefik)" "test.localhost"
ask TESTENV_IMAGE          "Imagen del contenedor" "localhost/php_devel:8.4"
ask TESTENV_NETWORK        "Red compose" "default"
ask TESTENV_TRAEFIK_ROUTER "Nombre del router traefik" "fs-testenv"
ask TESTENV_RUN_USER       "Usuario apache dentro del contenedor" "www-data"
ask TESTENV_DB_SERVICE     "Servicio de BD del compose (depends_on)" "db"
ask CONTAINER_ENGINE       "Motor de contenedores (podman | docker)" "podman"

case "$CONTAINER_ENGINE" in
    podman|docker) ;;
    *) echo "ERROR: CONTAINER_ENGINE debe ser 'podman' o 'docker' (dado: '$CONTAINER_ENGINE')." >&2; exit 1 ;;
esac

# TESTENV_DIR concreto para rendes (vacío -> default)
TESTENV_DIR="${TESTENV_DIR:-$FS_PROJECT_ROOT/test-env/facturascripts}"
ENABLE_LIST="${ENABLE_LIST:-}"

# --- escribir .fs-test-env.env ---
umask 077
cat > "$ENV_FILE" <<EOF
# Generado por test-bin/bin/init-project.sh. Config del despliegue del entorno de test.
FS_CORE_DIR="$FS_CORE_DIR"
TESTENV_REPO_PATH="$TESTENV_REPO_PATH"
TESTENV_DIR="$TESTENV_DIR"
TEST_DB="$TEST_DB"
CORE_REPO="$CORE_REPO"
CORE_BRANCH="$CORE_BRANCH"
ENABLE_LIST="$ENABLE_LIST"
FS_LANG="$FS_LANG"
FS_TIMEZONE="$FS_TIMEZONE"
TEST_WEB_TITLE="$TEST_WEB_TITLE"
TEST_WEB_URL="$TEST_WEB_URL"
TESTENV_SERVICE="$TESTENV_SERVICE"
TESTENV_CONTAINER="$TESTENV_CONTAINER"
TESTENV_HOST="$TESTENV_HOST"
TESTENV_IMAGE="$TESTENV_IMAGE"
TESTENV_NETWORK="$TESTENV_NETWORK"
TESTENV_TRAEFIK_ROUTER="$TESTENV_TRAEFIK_ROUTER"
TESTENV_RUN_USER="$TESTENV_RUN_USER"
TESTENV_DB_SERVICE="$TESTENV_DB_SERVICE"
CONTAINER_ENGINE="$CONTAINER_ENGINE"
EOF
umask 022
echo "   escrito $ENV_FILE"

# --- renderizar plantillas ---
render() {  # render <plantilla>
    sed \
        -e "s#@@FS_CORE_DIR@@#${FS_CORE_DIR}#g" \
        -e "s#@@TESTENV_REPO_PATH@@#${TESTENV_REPO_PATH}#g" \
        -e "s#@@TESTENV_DIR@@#${TESTENV_DIR}#g" \
        -e "s#@@TEST_DB@@#${TEST_DB}#g" \
        -e "s#@@CORE_BRANCH@@#${CORE_BRANCH}#g" \
        -e "s#@@FS_TIMEZONE@@#${FS_TIMEZONE}#g" \
        -e "s#@@TEST_WEB_TITLE@@#${TEST_WEB_TITLE}#g" \
        -e "s#@@TESTENV_SERVICE@@#${TESTENV_SERVICE}#g" \
        -e "s#@@TESTENV_CONTAINER@@#${TESTENV_CONTAINER}#g" \
        -e "s#@@TESTENV_HOST@@#${TESTENV_HOST}#g" \
        -e "s#@@TESTENV_IMAGE@@#${TESTENV_IMAGE}#g" \
        -e "s#@@TESTENV_NETWORK@@#${TESTENV_NETWORK}#g" \
        -e "s#@@TESTENV_TRAEFIK_ROUTER@@#${TESTENV_TRAEFIK_ROUTER}#g" \
        -e "s#@@TESTENV_RUN_USER@@#${TESTENV_RUN_USER}#g" \
        -e "s#@@TESTENV_DB_SERVICE@@#${TESTENV_DB_SERVICE}#g" \
        "$1"
}

SERVICE_TMPL="$SUBMODULE_DIR/templates/testenv.service.$CONTAINER_ENGINE.tmpl.yaml"
[ -f "$SERVICE_TMPL" ] || { echo "ERROR: no existe la plantilla $SERVICE_TMPL" >&2; exit 1; }

mkdir -p "$OUT_DIR"
render "$SUBMODULE_DIR/templates/test.conf.tmpl" > "$OUT_DIR/test.conf"
render "$SERVICE_TMPL"                            > "$OUT_DIR/service.yaml"
echo "   renderizado $OUT_DIR/test.conf"
echo "   renderizado $OUT_DIR/service.yaml  (motor: $CONTAINER_ENGINE)"

if [ "$CONTAINER_ENGINE" = "docker" ]; then
    UP_CMD="docker compose up -d $TESTENV_SERVICE"
else
    UP_CMD="podman-compose up -d $TESTENV_SERVICE"
fi

cat <<EOF

================================================================
Entorno de test configurado (motor: $CONTAINER_ENGINE).

1) Añade a .gitignore del proyecto (si no quieres versionar la config local):
     .fs-test-env
     .fs-test-env.env

2) Pega el servicio de $OUT_DIR/service.yaml en tu compose y levántalo:
     $UP_CMD
   El vhost $OUT_DIR/test.conf ya está referenciado en el servicio
   (./.fs-test-env/test.conf -> /etc/apache2/sites-enabled/test.conf).

3) Provisiona el entorno:
     - en el host:      test-bin/bin/setup-test-env.sh   (interactivo)
     - o en contenedor: se ejecuta test-env-provision.sh al arrancar.
================================================================
EOF
