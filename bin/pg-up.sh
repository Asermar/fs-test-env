#!/bin/bash
# =============================================================================
# Levanta el PostgreSQL 13 del arnés de test (contenedor `fstest-pg`) de forma idempotente.
#
#   - Si ya está corriendo: no lo toca.
#   - Si está parado: lo arranca con `podman start` (`podman-compose up -d` no arranca uno parado;
#     ver bin/up.sh).
#   - Si no existe: lo crea con postgres/podman-compose.yaml.
#
# Y en los tres casos termina comprobando que responde (el healthcheck, `pg_isready`): decir
# «levantado» de un servidor que no contesta es justo lo que este script no debe hacer.
#
# Antes de crear nada se asegura de lo que el compose necesita fuera del repo:
#   - la contraseña del superusuario, en ~/.config/tooling/fs-test_pg.env (0600). Si no existe la
#     genera al azar. Nunca la imprime ni la pasa por argv: sale de /dev/urandom por una tubería.
#   - el directorio de datos, ~/.local/share/tooling/fs-test_pg/data (0700).
#
# Variables (opcionales):
#   TOOLING_FS_TEST_PG_ENV    fichero de la contraseña (def: ~/.config/tooling/fs-test_pg.env)
#   TOOLING_FS_TEST_PG_DATA   directorio de datos      (def: ~/.local/share/tooling/fs-test_pg/data)
#
# Salida: 0 si queda corriendo y respondiendo; 1 si no; 2 si la invocación es incorrecta.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/../postgres/podman-compose.yaml"
CONTENEDOR="fstest-pg"
PROYECTO="fstest"

if [ $# -gt 0 ]; then
    echo "ERROR: $0 no admite opciones (recibió: $*)." >&2
    exit 2
fi

export TOOLING_FS_TEST_PG_ENV="${TOOLING_FS_TEST_PG_ENV:-${XDG_CONFIG_HOME:-$HOME/.config}/tooling/fs-test_pg.env}"
export TOOLING_FS_TEST_PG_DATA="${TOOLING_FS_TEST_PG_DATA:-${XDG_DATA_HOME:-$HOME/.local/share}/tooling/fs-test_pg/data}"

for orden in podman podman-compose; do
    command -v "$orden" >/dev/null 2>&1 || { echo "ERROR: no se encuentra '$orden'." >&2; exit 1; }
done

# --- la contraseña ---------------------------------------------------------------------------
# UNA CONTRASEÑA NUEVA CON UN CLÚSTER VIEJO SERÍA MENTIRA: POSTGRES_PASSWORD sólo se aplica al crear
# el clúster, así que si el directorio de datos ya tiene uno, generar otra dejaría en el fichero una
# contraseña que el servidor no acepta. Se niega y dice qué hacer.
if [ ! -f "$TOOLING_FS_TEST_PG_ENV" ]; then
    if [ -f "$TOOLING_FS_TEST_PG_DATA/PG_VERSION" ]; then
        echo "ERROR: falta $TOOLING_FS_TEST_PG_ENV, pero en $TOOLING_FS_TEST_PG_DATA ya hay un clúster." >&2
        echo "  Una contraseña nueva no sería la del servidor: sólo cuenta al crear el clúster." >&2
        echo "  Recupera el fichero, o sigue «Rotar la contraseña» del README de fs-test." >&2
        exit 1
    fi
    # Lo mismo si el contenedor ya existe: su clúster puede estar en OTRO directorio de datos (el que
    # tenía TOOLING_FS_TEST_PG_DATA al crearlo), y entonces la comprobación de arriba no lo ve.
    if podman container inspect "$CONTENEDOR" >/dev/null 2>&1; then
        echo "ERROR: falta $TOOLING_FS_TEST_PG_ENV, pero el contenedor $CONTENEDOR ya existe." >&2
        echo "  Se creó con una contraseña; una nueva no sería la suya." >&2
        echo "  Recupera el fichero, o sigue «Rotar la contraseña» del README de fs-test." >&2
        exit 1
    fi
    mkdir -p "$(dirname "$TOOLING_FS_TEST_PG_ENV")" || exit 1
    # En una subshell con umask 077, para que el fichero nazca en 0600 y no haya un instante en que
    # otro pueda leerlo. La contraseña no pasa por ninguna variable ni argumento.
    if ! ( umask 077
           head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32 \
               | { printf 'POSTGRES_PASSWORD='; cat; printf '\n'; } > "$TOOLING_FS_TEST_PG_ENV" ); then
        echo "ERROR: no se pudo escribir $TOOLING_FS_TEST_PG_ENV." >&2
        exit 1
    fi
    echo "Contraseña del superusuario generada en $TOOLING_FS_TEST_PG_ENV (0600)."
fi
modo="$(stat -c %a "$TOOLING_FS_TEST_PG_ENV")"
if [ "$modo" != 600 ]; then
    chmod 600 "$TOOLING_FS_TEST_PG_ENV" || exit 1
    echo "AVISO: $TOOLING_FS_TEST_PG_ENV estaba en $modo; queda en 600."
fi
if ! grep -qE '^POSTGRES_PASSWORD=.+' "$TOOLING_FS_TEST_PG_ENV"; then
    echo "ERROR: $TOOLING_FS_TEST_PG_ENV no tiene una línea POSTGRES_PASSWORD=<algo>." >&2
    exit 1
fi

# --- los datos -------------------------------------------------------------------------------
mkdir -p "$TOOLING_FS_TEST_PG_DATA" && chmod 700 "$TOOLING_FS_TEST_PG_DATA" || exit 1

# --- el contenedor ---------------------------------------------------------------------------
estado="$(podman container inspect "$CONTENEDOR" --format '{{.State.Status}}' 2>/dev/null || true)"
case "$estado" in
    running)
        echo "$CONTENEDOR ya estaba corriendo."
        ;;
    "")
        echo "Creando $CONTENEDOR…"
        podman-compose -p "$PROYECTO" -f "$COMPOSE_FILE" up -d >/dev/null || {
            echo "ERROR: podman-compose no pudo crear $CONTENEDOR." >&2
            exit 1
        }
        ;;
    *)
        echo "$CONTENEDOR estaba '$estado'; arrancándolo…"
        podman start "$CONTENEDOR" >/dev/null || { echo "ERROR: no arrancó $CONTENEDOR." >&2; exit 1; }
        ;;
esac

# --- postcondición: responde -----------------------------------------------------------------
# `podman healthcheck run` ejecuta el healthcheck del compose AHORA, sin depender de los temporizadores
# de systemd que el modo rootless usa para repetirlo.
for _ in $(seq 1 60); do
    if podman healthcheck run "$CONTENEDOR" >/dev/null 2>&1; then
        echo "$CONTENEDOR responde (127.0.0.1:5432, fstest-pg.asermar.com en la red asermar.com)."
        exit 0
    fi
    sleep 1
done
echo "ERROR: $CONTENEDOR no responde tras 60 s. Mira: podman logs $CONTENEDOR" >&2
exit 1
