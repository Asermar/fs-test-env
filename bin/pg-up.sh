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
#
# Y antes, que el destino sea un fichero normal o no exista: si es un directorio, `ln` publicaría
# DENTRO de él y el chmod 600 de abajo lo dejaría inatravesable (TOOLING_FS_TEST_PG_ENV=~/.config/tooling
# es un error fácil). Un enlace a un fichero vale: -f lo sigue.
if { [ -e "$TOOLING_FS_TEST_PG_ENV" ] || [ -L "$TOOLING_FS_TEST_PG_ENV" ]; } && [ ! -f "$TOOLING_FS_TEST_PG_ENV" ]; then
    if [ -d "$TOOLING_FS_TEST_PG_ENV" ]; then que="un directorio"
    elif [ ! -e "$TOOLING_FS_TEST_PG_ENV" ]; then que="un enlace roto"
    else que="algo que no es un fichero normal"; fi
    echo "ERROR: $TOOLING_FS_TEST_PG_ENV es $que, no es un fichero: no se toca." >&2
    echo "  TOOLING_FS_TEST_PG_ENV tiene que nombrar el fichero de la contraseña, no su carpeta." >&2
    exit 1
fi
if [ ! -f "$TOOLING_FS_TEST_PG_ENV" ]; then
    if [ -f "$TOOLING_FS_TEST_PG_DATA/PG_VERSION" ]; then
        echo "ERROR: falta $TOOLING_FS_TEST_PG_ENV, pero en $TOOLING_FS_TEST_PG_DATA ya hay un clúster." >&2
        echo "  Una contraseña nueva no sería la del servidor: sólo cuenta al crear el clúster." >&2
        echo "  Recupera el fichero, o sigue «Rotar la contraseña» del README de fs-test." >&2
        exit 1
    fi
    # Lo mismo si el contenedor ya existe: su clúster puede estar en OTRO directorio de datos (el que
    # tenía TOOLING_FS_TEST_PG_DATA al crearlo), y entonces la comprobación de arriba no lo ve.
    # `exists` separa «no existe» (1) de «podman no ha podido mirar» (125, medido con podman 4.9.3):
    # tratar el segundo como el primero volvería a generar una contraseña ajena.
    podman container exists "$CONTENEDOR"
    case $? in
        0)  echo "ERROR: falta $TOOLING_FS_TEST_PG_ENV, pero el contenedor $CONTENEDOR ya existe." >&2
            echo "  Se creó con una contraseña; una nueva no sería la suya." >&2
            echo "  Recupera el fichero, o sigue «Rotar la contraseña» del README de fs-test." >&2
            exit 1 ;;
        1)  ;;
        *)  echo "ERROR: no se pudo comprobar si existe $CONTENEDOR (podman ha fallado); no se genera contraseña." >&2
            exit 1 ;;
    esac
    dir_env="$(dirname "$TOOLING_FS_TEST_PG_ENV")"
    mkdir -p "$dir_env" || exit 1
    # Se genera en un temporal del MISMO directorio (mktemp lo crea en 0600) y sólo se publica entero,
    # con `ln`, que es atómico y no sobrescribe. Así el fichero no existe nunca a medias: ni queda uno
    # roto si la generación falla, ni otro pg-up.sh lanzado a la vez puede leerlo antes de tiempo.
    # Si `ln` encuentra el destino, lo publicó el otro, también entero: se usa el suyo. La contraseña
    # no pasa por ninguna variable ni argumento.
    temporal="$(mktemp "$dir_env/.$(basename "$TOOLING_FS_TEST_PG_ENV").XXXXXX")" || exit 1
    trap 'rm -f -- "$temporal"' EXIT
    head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32 \
        | { printf 'POSTGRES_PASSWORD='; cat; printf '\n'; } > "$temporal"
    # Se valida contra lo que se acaba de generar, 32 alfanuméricos: una contraseña truncada o vacía
    # no se publica. (Un fichero que ya existía se valida más abajo con menos exigencia, porque tras
    # rotarla puede llevar cualquier carácter.)
    if ! grep -qxE 'POSTGRES_PASSWORD=[A-Za-z0-9]{32}' "$temporal" || [ "$(wc -l < "$temporal")" != 1 ]; then
        echo "ERROR: no se pudo generar la contraseña; no se crea $TOOLING_FS_TEST_PG_ENV." >&2
        exit 1
    fi
    # -T: el destino es ESE nombre, nunca una carpeta en la que meterlo.
    if ln -T -- "$temporal" "$TOOLING_FS_TEST_PG_ENV" 2>/dev/null; then
        echo "Contraseña del superusuario generada en $TOOLING_FS_TEST_PG_ENV (0600)."
    elif [ -f "$TOOLING_FS_TEST_PG_ENV" ]; then
        echo "$TOOLING_FS_TEST_PG_ENV lo ha creado otro pg-up.sh a la vez; se usa esa contraseña."
    else
        echo "ERROR: no se pudo escribir $TOOLING_FS_TEST_PG_ENV." >&2
        exit 1
    fi
    rm -f -- "$temporal"
    trap - EXIT
fi
# -L: el modo del fichero, no el del enlace si TOOLING_FS_TEST_PG_ENV es uno (un enlace siempre da 777).
modo="$(stat -L -c %a "$TOOLING_FS_TEST_PG_ENV")"
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
# «No existe» se crea; «podman no ha podido mirar» no: con inspect `|| true` se leían igual, y el
# script decía «Creando…» y lanzaba podman-compose con podman roto.
podman container exists "$CONTENEDOR"
case $? in
    0)  estado="$(podman container inspect "$CONTENEDOR" --format '{{.State.Status}}')" || {
            echo "ERROR: no se pudo leer el estado de $CONTENEDOR." >&2; exit 1; } ;;
    1)  estado="" ;;
    *)  echo "ERROR: no se pudo comprobar si existe $CONTENEDOR (podman ha fallado)." >&2
        exit 1 ;;
esac
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
