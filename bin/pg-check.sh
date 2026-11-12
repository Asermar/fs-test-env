#!/bin/bash
# =============================================================================
# Comprueba que el PostgreSQL del arnés de test (`fstest-pg`) responde, por los dos caminos que
# usan las copias:
#
#   - desde la red `asermar.com`, por su nombre `fstest-pg.asermar.com` (el de los contenedores de
#     test de cada copia);
#   - desde el host, por 127.0.0.1:5432.
#
# Cada camino lo prueba `psql … -c 'select version()'` en un contenedor desechable de la misma imagen
# (en el host no tiene por qué haber psql). Se autentica como `postgres` con la contraseña de
# ~/.config/tooling/fs-test_pg.env, que llega a psql por el entorno y nunca por argv ni por la salida.
#
# Variables (opcionales):
#   TOOLING_FS_TEST_PG_ENV    fichero de la contraseña (def: ~/.config/tooling/fs-test_pg.env)
#
# Salida: 0 «responde» por los dos caminos; 1 «no responde», con el motivo (no hay contenedor, está
# parado, o no contesta por un camino), o «no se pudo comprobar» si no se puede leer su imagen;
# 2 si la invocación es incorrecta.
# =============================================================================
set -uo pipefail

# Constantes del script, y por eso globales en mayúsculas: probar() lee PUERTO sin recibirlo.
readonly CONTENEDOR="fstest-pg"
readonly HOSTNAME_RED="fstest-pg.asermar.com"
readonly RED="asermar.com"
readonly PUERTO=5432

if [ $# -gt 0 ]; then
    echo "ERROR: $0 no admite opciones (recibió: $*)." >&2
    exit 2
fi

ENV_FILE="${TOOLING_FS_TEST_PG_ENV:-${XDG_CONFIG_HOME:-$HOME/.config}/tooling/fs-test_pg.env}"

command -v podman >/dev/null 2>&1 || { echo "no responde: no se encuentra 'podman'." >&2; exit 1; }

# «No hay contenedor» y «no responde» se arreglan distinto (levantarlo frente a mirar sus logs), así
# que el mensaje los separa aunque el rc sea el mismo.
estado="$(podman container inspect "$CONTENEDOR" --format '{{.State.Status}}' 2>/dev/null || true)"
if [ -z "$estado" ]; then
    echo "no responde: no hay contenedor $CONTENEDOR. Levántalo con bin/pg-up.sh." >&2
    exit 1
fi
if [ "$estado" != running ]; then
    echo "no responde: $CONTENEDOR existe pero está '$estado'. Arráncalo con bin/pg-up.sh." >&2
    exit 1
fi

if [ ! -r "$ENV_FILE" ]; then
    echo "no responde: no puedo autenticarme, falta $ENV_FILE." >&2
    exit 1
fi
clave="$(sed -n 's/^POSTGRES_PASSWORD=//p' "$ENV_FILE" | head -n 1)"
if [ -z "$clave" ]; then
    echo "no responde: $ENV_FILE no tiene una línea POSTGRES_PASSWORD=<algo>." >&2
    exit 1
fi

# La imagen del propio contenedor: así no hace falta red para bajar nada, y psql es de la misma versión.
# Si no sale, no es que no responda: es que no se ha podido comprobar, y se dice así.
if ! imagen_pg="$(podman container inspect "$CONTENEDOR" --format '{{.Image}}' 2>/dev/null)" \
   || [ -z "$imagen_pg" ]; then
    echo "no se pudo comprobar: no he podido leer la imagen de $CONTENEDOR (podman container inspect)." >&2
    exit 1
fi

# $1 = descripción del camino, $2 = red del contenedor desechable, $3 = host al que conectar,
# $4 = contraseña de postgres, $5 = imagen. Todo lo que lee lo recibe, salvo la constante PUERTO.
probar() {
    local camino="$1" red="$2" host="$3" contrasena="$4" imagen="$5" version
    if version="$(PGPASSWORD="$contrasena" podman run --rm --pull=never --http-proxy=false \
                    --network "$red" -e PGPASSWORD "$imagen" \
                    psql -h "$host" -p "$PUERTO" -U postgres -d postgres -tAc 'select version()' 2>&1)"; then
        echo "responde por $camino: ${version%%,*}"
        return 0
    fi
    echo "no responde por $camino: $(printf '%s' "$version" | tail -n 1)" >&2
    return 1
}

rc=0
probar "la red $RED ($HOSTNAME_RED)" "$RED" "$HOSTNAME_RED" "$clave" "$imagen_pg" || rc=1
probar "el host (127.0.0.1:$PUERTO)" host 127.0.0.1 "$clave" "$imagen_pg" || rc=1
exit "$rc"
