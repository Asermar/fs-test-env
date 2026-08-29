#!/bin/bash
# =============================================================================
# Levanta el entorno de test (contenedor) de forma idempotente.
#
#   - Si el contenedor YA está corriendo: no toca nada (la provisión del entorno
#     ocurre al arrancar el contenedor, TESTENV_AUTO_PROVISION=1).
#   - Si está PARADO: lo arranca con el motor. `<engine>-compose up -d` NO sirve para esto —
#     medido abajo—, y este script prometía en esta misma línea algo que no hacía.
#   - Si NO EXISTE: lo crea con el compose del proyecto
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
#   FS_PROJECT_ROOT      raíz del proyecto (def: la del repositorio en el que estás).
#
# Opciones:
#   --en-el-principal   escape para levantar el entorno en el checkout PRINCIPAL, donde se niega
#                       por defecto (ver bin/lib/ancla.sh). Avisa cada vez.
#
# Lo que no se reconozca hace FALLAR la invocación (rc 2) en vez de ignorarse.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- opciones ---------------------------------------------------------------------------------
PERMITIR_PRINCIPAL=0
for _a in "$@"; do
    case "$_a" in
        --en-el-principal) PERMITIR_PRINCIPAL=1 ;;
        *)
            echo "ERROR: opción desconocida: '$_a'." >&2
            echo "  La única que hay:" >&2
            echo "    --en-el-principal   escape para levantar en el checkout principal (avisa)." >&2
            exit 2
            ;;
    esac
done

# LA RAÍZ DEL PROYECTO, Y AQUÍ ESTABA EL DEFECTO QUE DEJABA ESTE SCRIPT INSERVIBLE.
#
# Subir dos niveles desde `bin/` era correcto cuando el arnés vivía DENTRO del proyecto como
# `test-bin/`. Desde que vive en `Tooling/fs-test` resuelve a `~/Dev/Tooling`, que no es el proyecto
# de nadie — medido: ahí no hay compose, así que la autodetección no encontraba nada y el script
# moría pidiendo `TESTENV_COMPOSE_FILE`.
#
# EL DIAGNÓSTICO QUE ESO PROVOCA ES EL CARO: parece que falta configuración, y el arreglo aparente
# es añadir `TESTENV_COMPOSE_FILE` al registro o al `.env` generado — o sea, una clave nueva y para
# siempre en el registro para tapar un bug de derivación de una línea. El candidato correcto
# (`<raíz>/podman/podman-compose.yaml`) YA estaba en la lista de abajo; lo que estaba mal era la
# raíz. Es el cuarto sitio con este mismo defecto: la v3.0.0 lo arregló en el provisionador, en
# `init-project.sh` y en el runner web, y luego apareció en el teardown.
#
# Se deriva del REPOSITORIO, como `init-project.sh`, y no del directorio actual como el
# provisionador: este script se lanza desde un botón (la sección Scripts de OkoGit) cuyo directorio
# puede ser cualquier subcarpeta del proyecto, y `--show-toplevel` acierta desde todas.
FS_PROJECT_ROOT="${FS_PROJECT_ROOT:-$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || echo "$PWD")}"
[ -f "$FS_PROJECT_ROOT/.fs-test-env.env" ] && . "$FS_PROJECT_ROOT/.fs-test-env.env"

# --- EL ENTORNO DE TEST VIVE EN UNA COPIA -------------------------------------------------------
# Va ANTES de tocar el motor de contenedores: un rechazo no debe dejar nada arrancado. Y esta puerta
# importa más que la de la generación, porque lo que levanta aquí es un contenedor que autoprovisiona
# — sin la guarda, el contenedor arranca, el provisionador de dentro SÍ se niega (su guarda existe) y
# queda un contenedor en marcha sin entorno, con el error sólo en un log que nadie mira.
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/ancla.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/registro.sh"
if ancla_es_principal "$FS_PROJECT_ROOT" && [ "$PERMITIR_PRINCIPAL" = 0 ]; then
    ancla_niega "$FS_PROJECT_ROOT" "$(registro_id_de "$FS_PROJECT_ROOT" 2>/dev/null || true)" \
        "levantar el entorno de test" "$0 --en-el-principal"
    exit 1
fi
[ "$PERMITIR_PRINCIPAL" = 1 ] && ancla_avisa_escape "$FS_PROJECT_ROOT" "levantando el entorno de test"

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
    # Se publican para que el mensaje de error pueda enumerarlos: decir dónde se buscó es la mitad
    # del diagnóstico, y sin ella el fallo apunta al sitio equivocado.
    CANDIDATOS_PROBADOS=("${candidates[@]}")
    local f
    for f in "${candidates[@]}"; do
        [ -f "$f" ] && { COMPOSE_FILE="$f"; return 0; }
    done
    return 1
}
CANDIDATOS_PROBADOS=()
COMPOSE_FILE=

# SE LLAMA SIN `$( )` A PROPÓSITO: dentro de una substitución de comandos, las asignaciones ocurren
# en una subshell y NO llegan aquí — medido: el array de candidatos volvía con 0 elementos, así que
# el mensaje de abajo habría enumerado la nada justo cuando más falta hace.
find_compose || true
if [ -z "$COMPOSE_FILE" ] || [ ! -f "$COMPOSE_FILE" ]; then
    # EL MENSAJE DICE LA RAÍZ EN LA QUE BUSCÓ, que es lo que faltaba. Sin eso, un fallo por una raíz
    # mal derivada se lee como «falta configuración» y manda a definir una variable que no hacía
    # falta — que es exactamente lo que pasó mientras la raíz salía de la ubicación del script.
    echo "ERROR: no se encuentra el fichero compose del proyecto." >&2
    echo "       Raíz en la que he buscado: $FS_PROJECT_ROOT" >&2
    echo "       Candidatos ($CONTAINER_ENGINE):" >&2
    [ "${#CANDIDATOS_PROBADOS[@]}" -gt 0 ] && printf '         %s\n' "${CANDIDATOS_PROBADOS[@]}" >&2
    echo "       Si la raíz no es la que esperabas, dila: FS_PROJECT_ROOT=/ruta $0" >&2
    echo "       Si el compose está en otro sitio: TESTENV_COMPOSE_FILE en .fs-test-env.env." >&2
    exit 1
fi

# --- aviso informativo si el tooling está desfasado (no bloquea) ---
[ -x "$SCRIPT_DIR/version.sh" ] && "$SCRIPT_DIR/version.sh" || true
echo

# --- estado del contenedor ---
status="$("$CONTAINER_ENGINE" inspect -f '{{.State.Status}}' "$TESTENV_CONTAINER" 2>/dev/null || echo absent)"

# --- ¿Y DE QUIÉN ES ESTE CONTENEDOR? -----------------------------------------------------------
#
# Va ANTES de mirar el estado, y ahí está lo que faltaba: hasta la v3.3.0 la única comprobación de
# propiedad estaba en la rama de «no existe», así que un contenedor que YA existía se arrancaba —o
# se daba por bueno si corría— sin preguntar de quién era. La v3.3.0 cerró la CREACIÓN del
# contenedor del original desde una copia, pero no su ARRANQUE.
#
# NO ES UN CASO REBUSCADO, es el normal: `init-project.sh` en una copia deriva hoy `TESTENV_CONTAINER`
# del compose del proyecto, que lo nombra sin sufijo, así que una copia nace declarando el contenedor
# del ORIGINAL —medido: `mesa-fs-test` en una copia llamada `excursiones`—. Que no muerda ahora mismo
# es casualidad y no cobertura: ese contenedor no existe en esta máquina, así que cae en la rama de
# «no existe». El día que exista, se arranca.
#
# Y las dos ramas fallaban distinto de mal: con el contenedor PARADO lo arrancaba, y con el
# contenedor CORRIENDO salía 0 diciendo «nada que hacer» — sin una línea que dijera que el entorno
# que da por bueno es el de otro.
if ! ancla_contenedor_es_suyo "$FS_PROJECT_ROOT" "$TESTENV_CONTAINER"; then
    _copia="$(ancla_sufijo_copia "$FS_PROJECT_ROOT")"
    cat >&2 <<FIN
ERROR: '$TESTENV_CONTAINER' no lleva el sufijo de esta copia ('$_copia'): no puedo garantizar que
  sea suyo, así que no lo toco. Estado actual: $status.

  Esto es una COPIA de trabajo, y su entorno de test tiene que ser SUYO. Un contenedor con el
  nombre del original monta el árbol de otro y ocupa su router de traefik: arrancarlo desde aquí
  —o darlo por bueno si ya corre— es servir el entorno del principal creyendo que es el de esta
  copia, y dejar sus tests a merced de lo que pase aquí.

  De dónde sale ese nombre: al configurar una copia, TESTENV_CONTAINER se deriva del compose del
  proyecto, que nombra los contenedores SIN sufijo. Quien se lo pone es el overlay que genera
  okoworktree, no este script.

  El stack de esta copia lo levanta quien sabe de su overlay:

      okoworktree up $_copia

  Si de verdad querías actuar sobre '$TESTENV_CONTAINER', hazlo desde el árbol al que pertenece.
FIN
    exit 1
fi

if [ "$status" = "running" ]; then
    echo "✓ '$TESTENV_CONTAINER' ya está levantado. Nada que hacer."
    exit 0
fi

# CÓMO SE LEVANTA, Y POR QUÉ NO ES SIEMPRE EL COMPOSE.
#
# ## Un contenedor que YA EXISTE se arranca con el motor
#
# `<engine>-compose up -d <servicio>` sobre el compose base de un worktree NO arranca el contenedor
# de la copia: crea (o arranca) el del ORIGINAL. El compose declara `container_name` sin sufijo, y
# quien le pone el sufijo a una copia es el overlay que genera `okoworktree`, que este script no
# tiene. Medido el 29-ago-2026 en `Mesa/FS-wt-guardaancla`: la invocación devolvía 0, el contenedor
# de la copia seguía `Exited` sin una línea de log nueva… y aparecía un `mesa-fs-test` recién creado
# —el nombre del original— montando el árbol de la copia y ocupando su router de traefik.
#
# O sea: no es que el compose «no arranque nada». Arranca **otra cosa**, y eso es peor, porque el
# contenedor del principal es justo el que la decisión del 27-ago dice que no debe existir.
#
# `<engine> start` sobre el contenedor que la copia declara sí lo deja «Up» al instante.
#
# ## Y si NO existe, en una copia se DELEGA
#
# Crear el stack de una copia es de `okoworktree`, que sabe del overlay; hacerlo desde aquí con el
# compose base es exactamente cómo se creó ese huérfano. Así que se dice y se para.
if [ "$status" != "absent" ]; then
    echo ">> Arrancando '$TESTENV_CONTAINER' (estado previo: $status) con $CONTAINER_ENGINE start"
    "$CONTAINER_ENGINE" start "$TESTENV_CONTAINER" >/dev/null
elif ancla_es_worktree "$FS_PROJECT_ROOT"; then
    _copia="$(basename "$FS_PROJECT_ROOT")"; _copia="${_copia##*-wt-}"
    cat >&2 <<FIN
ERROR: '$TESTENV_CONTAINER' no existe, y esto es una COPIA de trabajo.

  No lo creo yo: el compose del proyecto nombra los contenedores SIN el sufijo de la copia —quien se
  lo pone es el overlay que genera okoworktree—, así que crearlo desde aquí levantaría el contenedor
  del ORIGINAL montando el árbol de esta copia. Eso ya ocurrió una vez y dejó un huérfano ocupando
  el router de traefik del entorno principal.

  El stack de una copia lo levanta quien sabe de su overlay:

      okoworktree up $_copia

  Eso deja el contenedor con su nombre y su router. Después, este script ya puede arrancarlo.
FIN
    exit 1
else
    echo ">> Creando '$TESTENV_SERVICE' con: ${COMPOSE[*]} -f $COMPOSE_FILE up -d"
    ( cd "$(dirname "$COMPOSE_FILE")" && "${COMPOSE[@]}" -f "$COMPOSE_FILE" up -d "$TESTENV_SERVICE" )
fi

# SE COMPRUEBA EL EFECTO, NO QUE EL COMANDO VOLVIERA. Antes se afirmaba «levantado» a continuación
# del compose, sin mirar: con el fallo de arriba, este script decía que había levantado el entorno y
# salía 0 con el contenedor parado. Un paso que no hace su trabajo tiene que decirlo.
final="$("$CONTAINER_ENGINE" inspect -f '{{.State.Status}}' "$TESTENV_CONTAINER" 2>/dev/null || echo absent)"
if [ "$final" != "running" ]; then
    echo "ERROR: '$TESTENV_CONTAINER' NO está corriendo (estado: $final) pese a que el comando" >&2
    echo "       de arranque no dio error. El entorno de pruebas no se ha levantado." >&2
    echo "       Últimas líneas de su registro:" >&2
    "$CONTAINER_ENGINE" logs --tail 15 "$TESTENV_CONTAINER" 2>&1 | sed 's/^/         /' >&2 || true
    exit 1
fi

echo "✓ '$TESTENV_CONTAINER' levantado (comprobado: $final). El arranque provisiona/actualiza el entorno."
