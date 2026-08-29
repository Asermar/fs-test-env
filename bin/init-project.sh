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
# Uso:  <arnés>/bin/init-project.sh            (interactivo)
#       VAR=... <arnés>/bin/init-project.sh    (no interactivo, toma de entorno)
#
# Opciones:
#   --en-el-principal   escape para configurar en el checkout PRINCIPAL. Se niega ahí porque el
#                       entorno de test vive en la copia (ver bin/lib/ancla.sh), y el único caso
#                       legítimo es DAR DE ALTA EL ANCLA del proyecto — que es justo lo que se hace
#                       en el principal, y por eso hay escape y no prohibición. Avisa cada vez.
#
# Lo que no se reconozca hace FALLAR la invocación (rc 2) en vez de ignorarse.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <arnés>/bin

# --- opciones ---------------------------------------------------------------------------------
# Estricto por el mismo motivo que en el provisionador: un `--en-el-principal` mal escrito que se
# ignorara dejaría el rechazo en pie y quien lo escribió creería haberlo saltado, o al revés según
# el flag. Medido antes de cerrar la puerta: hoy nadie invoca este script con argumentos —la batería
# `test/registro.sh` lo llama por entorno—, así que no hay llamador que romper.
PERMITIR_PRINCIPAL=0
for _a in "$@"; do
    case "$_a" in
        --en-el-principal) PERMITIR_PRINCIPAL=1 ;;
        *)
            echo "ERROR: opción desconocida: '$_a'." >&2
            echo "  La única que hay:" >&2
            echo "    --en-el-principal   escape para configurar en el checkout principal (avisa)." >&2
            exit 2
            ;;
    esac
done
FS_TEST_DIR="${FS_TEST_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"  # el arnés: derivado de dónde vive ESTE script

# La raíz del PROYECTO ya no se puede deducir de dónde vive el arnés: desde que vive fuera
# (`~/Dev/Tooling/fs-test`), su directorio padre es Tooling y no el proyecto de nadie. Se deriva del
# REPOSITORIO en el que estás —que es lo que no se rompe al mudar nada— y, si eso no dice nada útil,
# del directorio actual. `FS_PROJECT_ROOT` sigue mandando sobre todo, para invocaciones no estándar.
FS_PROJECT_ROOT="${FS_PROJECT_ROOT:-$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || echo "$PWD")}"

# Precondición, y falla ruidosamente a propósito: si lo de arriba ha resuelto al propio arnés, es que
# se ha lanzado desde su carpeta sin decir sobre qué proyecto. Configurar «el arnés sobre sí mismo»
# escribiría un `.fs-test-env.env` dentro del producto compartido por dos clientes.
if [ "$FS_PROJECT_ROOT" = "$FS_TEST_DIR" ]; then
    echo "ERROR: se ha resuelto la raíz del proyecto al propio arnés ($FS_TEST_DIR)." >&2
    echo "  Arreglo: lánzalo desde la raíz del proyecto que quieres configurar," >&2
    echo "           o dilo explícitamente: FS_PROJECT_ROOT=/ruta/del/proyecto $0" >&2
    exit 1
fi

ENV_FILE="$FS_PROJECT_ROOT/.fs-test-env.env"
OUT_DIR="$FS_PROJECT_ROOT/.fs-test-env"

# --- el registro: de dónde sale cada valor ------------------------------------------------------
# `.fs-test-env.env` deja de ser un fichero VERSIONADO en el repo del cliente y pasa a ser un fichero
# GENERADO, como `src/config.php` en Mesa/FS. Es la norma de la casa: *cualquier fichero que cambie
# por entorno y siga versionado tiene un defecto latente*.
# shellcheck disable=SC1091
. "$FS_TEST_DIR/bin/lib/registro.sh"

FS_TEST_ID="${FS_TEST_ID:-$(registro_id_de "$FS_PROJECT_ROOT")}"
# De qué bloque sale la clase (C): el propio, o el de la instalación padre si esto es una copia.
# Una copia sin entrada NO es una instalación nueva — es `mesa-fs` otra vez, en otro árbol.
ORIGEN_C="$(registro_origen_de "$REGISTRO_CONF" "$FS_TEST_ID" || true)"
NUEVA=0
[ -n "$ORIGEN_C" ] || NUEVA=1
HEREDADA=0
[ -n "$ORIGEN_C" ] && [ "$ORIGEN_C" != "$FS_TEST_ID" ] && HEREDADA=1

# --- EN EL CHECKOUT PRINCIPAL NO SE CONFIGURA (salvo para dar de alta el ancla) ------------------
#
# La señal, el mensaje y el porqué están en `lib/ancla.sh`. Aquí sólo importa DÓNDE va: antes de
# preguntar y antes de escribir, así que un rechazo no deja a medias ni el `.fs-test-env.env` ni el
# `.fs-test-env/`. Ésa es exactamente la puerta por la que entró el caso del 29-ago-2026, cuando
# este script corrió contra el principal de Mesa/FS y generó las dos cosas sin protestar.
#
# VA ANTES QUE LA GUARDA DE «COPIA SIN ANCLA» de abajo, y no es indiferente: una carpeta llamada
# `FS-wt-falso` que fuera un repo normal es «copia» para el id y «principal» para git. Manda git,
# que es lo que dice la regla — habla del árbol de trabajo, no de cómo se llame.
# shellcheck disable=SC1091
. "$FS_TEST_DIR/bin/lib/ancla.sh"
if ancla_es_principal "$FS_PROJECT_ROOT" && [ "$PERMITIR_PRINCIPAL" = 0 ]; then
    ancla_niega "$FS_PROJECT_ROOT" "$FS_TEST_ID" "generar la configuración del entorno de test" \
        "$0 --en-el-principal"
    cat >&2 <<FIN

  ── Y si lo que venías a hacer es DAR DE ALTA EL ANCLA de este proyecto, entonces sí es aquí:

      $0 --en-el-principal

  El ancla la crea el proyecto, no la primera copia, y es el paso previo a poder abrir worktrees.
  Sólo configura: no crea base, ni clona el core, ni levanta contenedores.
FIN
    exit 1
fi
[ "$PERMITIR_PRINCIPAL" = 1 ] && ancla_avisa_escape "$FS_PROJECT_ROOT" "generando la configuración"

# --- UNA COPIA SIN ANCLA NO SE CONFIGURA: FALLA Y PIDE CREARLA -----------------------------------
#
# El bloque del proyecto es su ANCLA: el punto del que derivan sus copias. Darla de alta es el paso
# PREVIO a habilitar worktrees en un super FS, no un residuo de nada.
#
# Antes, una copia sin ancla se trataba como instalación nueva, preguntaba los nueve valores y
# ESCRIBÍA el ancla bajo el id DE LA COPIA. A partir de ahí ninguna copia siguiente encontraba
# `<proyecto>`, así que cada una se registraba por su cuenta y el registro degeneraba en una entrada
# por copia — justo lo que se decidió no tener. El ancla la crea el proyecto, no la primera copia.
#
# Se aborta AQUÍ, antes de preguntar y antes de escribir: ni el registro versionado ni el fichero de
# máquina se tocan.
if [ "$NUEVA" = "1" ] && PADRE_ESPERADO="$(registro_padre_de "$FS_TEST_ID")"; then
    RAIZ_ANCLA="${FS_PROJECT_ROOT%%-wt-*}"
    cat >&2 <<FIN
ERROR: «$FS_TEST_ID» es una COPIA y su instalación de origen, «$PADRE_ESPERADO», no está
  registrada. No se configura ni se escribe nada.

  El bloque de «$PADRE_ESPERADO» es el ANCLA del proyecto: el punto del que heredan sus copias.
  Crearlo es el paso PREVIO a trabajar con worktrees aquí, y lo crea el proyecto — no la primera
  copia que pase. Si lo diera de alta esta copia, quedaría registrada con SU nombre y ninguna copia
  siguiente encontraría a su padre.

  Créala una vez, desde la raíz del proyecto — y con el escape, porque la raíz del proyecto ES el
  checkout principal y ahí este script se niega por defecto:

      cd "$RAIZ_ANCLA"
      $FS_TEST_DIR/bin/init-project.sh --en-el-principal

  Eso solo CONFIGURA —no crea base, ni clona el core, ni levanta contenedores—, así que se puede
  hacer sin montar el entorno. Luego vuelve aquí y repite.
FIN
    exit 1
fi

# --- UN DIRECTORIO DONDE VA UN FICHERO: SE DICE, NO SE MUERE CON UN ERROR DE REDIRECCIÓN ---------
#
# Si el proyecto se levantó sin haber generado antes estas piezas, podman monta un bind sobre un
# fichero que no existe y **crea un DIRECTORIO con ese nombre**. A partir de ahí este generador moría
# con «.fs-test-env/test.conf: Is a directory» —un error de bash, no un diagnóstico— y el entorno
# quedaba con el sitio de apache montado como directorio, que es lo que acaba sirviendo un **403** en
# el runner: el vhost no carga y apache cae a su sitio por defecto.
#
# Es la última pieza de una cadena que se ve desde tres sitios distintos y ninguno la nombraba: falta
# el .fs-test-env.env → falta el test.conf renderizado → podman crea un directorio → 403.
_esc=""; [ "$PERMITIR_PRINCIPAL" = 1 ] && _esc=" --en-el-principal"
for _pieza in test.conf service.yaml; do
    if [ -d "$OUT_DIR/$_pieza" ]; then
        cat >&2 <<FIN
ERROR: «$OUT_DIR/$_pieza» es un DIRECTORIO, y ahí tiene que ir un fichero.

  No lo has creado tú: lo crea el motor de contenedores al montar un bind sobre un fichero que aún
  no existía, y pasa cuando el stack se levanta ANTES de generar esta configuración.

  Mientras siga siendo un directorio, el sitio de apache del runner no carga y la web contesta un
  403 que no dice nada de esto.

  Arreglo, con el stack de este proyecto abajo para que no lo vuelva a crear:

      rmdir "$OUT_DIR/$_pieza"
      $0$_esc
FIN
        exit 1
    fi
done

# valores previos (si ya existe el generado) como defaults
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

# (C) del REGISTRO, que manda sobre lo que hubiera en el generado: es la fuente de verdad
reg() { registro_lee "$REGISTRO_CONF" "$ORIGEN_C" "$1"; }
if [ "$NUEVA" = "0" ]; then
    CORE_REPO="$(reg core_repo)";           CORE_BRANCH="$(reg core_branch)"
    ENABLE_LIST="$(reg enable_list)";       FS_LANG="$(reg fs_lang)"
    FS_TIMEZONE="$(reg fs_timezone)";       TEST_WEB_TITLE="$(reg test_web_title)"
    TESTENV_IMAGE="$(reg testenv_image)";   TESTENV_NETWORK="$(reg testenv_network)"
    CONTAINER_ENGINE="$(reg container_engine)"
fi

# (A) de la MÁQUINA: del fichero de máquina, que es el único que las sabe
maq() { registro_lee "$REGISTRO_MAQUINA" "$FS_TEST_ID" "$1"; }
TESTENV_REPO_PATH="${TESTENV_REPO_PATH:-$(maq repo_path)}"
TESTENV_DIR="${TESTENV_DIR:-$(maq testenv_dir)}"
TESTENV_RUN_USER="${TESTENV_RUN_USER:-$(maq run_user)}"
FS_CORE_DIR="${FS_CORE_DIR:-$(maq core_dir)}"

# (B) DERIVADO de lo que ya está versionado — no se pregunta ni se guarda
FS_CORE_DIR="${FS_CORE_DIR:-$( [ -d "$FS_PROJECT_ROOT/src/Core" ] && echo src || echo . )}"
eval "$(registro_compose "$FS_PROJECT_ROOT" | sed 's/^\([A-Z_]*\)=\(.*\)$/\1="\2"/')"
# SI ESTO NO SE PUEDE DERIVAR, SE DICE. Antes moría aquí en silencio: `registro_db_test` devuelve
# rc 1 cuando no hay de dónde sacar el nombre y, con `set -e`, el script se iba con rc 1 y CERO
# salida — «ni funciona ni lo dice», que es el patrón que este arnés ya persiguió en el warm-up y en
# el runner web. Medido sobre un proyecto sin `src/config.php`: rc 1, longitud de la salida 0.
#
# Y el comentario de abajo lo delata sin querer: dice que «la guarda del TEST_DB es la que sí es
# obligatoria», y esa guarda (`registro_guarda_db`) está setenta líneas más adelante — a la que
# nunca se llegaba, porque el script moría antes de poder ejecutarla.
TEST_DB="$(registro_db_test "$FS_PROJECT_ROOT" "$FS_CORE_DIR" || true)"
if [ -z "$TEST_DB" ]; then
    cat >&2 <<FIN
ERROR: no puedo derivar el nombre de la base de pruebas de «$FS_PROJECT_ROOT».

  Sale de la base de TRABAJO que declara el core del proyecto, añadiéndole «_test»: se lee
  FS_DB_NAME de $FS_PROJECT_ROOT/$FS_CORE_DIR/config.php. Aquí no hay de dónde sacarlo.

  Suele ser una de tres:
    · el proyecto todavía no tiene config.php generado (en Mesa/FS lo hace bin/generar-config.sh);
    · FS_CORE_DIR apunta al sitio equivocado (ahora vale «$FS_CORE_DIR»);
    · no es una instalación de FacturaScripts.

  No se deriva a un nombre por defecto a propósito: una base de pruebas con un nombre inventado
  es una base que nadie reconoce como suya, y el aislamiento de este arnés se apoya justo en que
  el nombre salga de la instalación.
FIN
    exit 1
fi
# Lo derivado puede NO estar: un compose sin router de traefik —local, o con docker— no da host ni
# URL, y con `set -u` eso mataba al generador justo al escribir. Se dejan vacías, que es lo que
# significan: «esta instalación no tiene eso». La guarda del TEST_DB es la que sí es obligatoria.
: "${TESTENV_SERVICE:=}" "${TESTENV_CONTAINER:=}" "${TESTENV_HOST:=}" "${TEST_WEB_URL:=}"
: "${TESTENV_TRAEFIK_ROUTER:=}" "${TESTENV_DB_SERVICE:=}"

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

echo ">> Entorno de test para: $FS_PROJECT_ROOT"
# EL FALLBACK SE DICE EN VOZ ALTA. Uno silencioso que coja el padre equivocado es peor que
# preguntar: la copia se configuraría con la del cliente de al lado y nadie lo vería.
if [ "$HEREDADA" = "1" ]; then
    echo "   instalación: [$FS_TEST_ID]  (copia: hereda la configuración de producto de [$ORIGEN_C])"
elif [ "$NUEVA" = "1" ]; then
    echo "   instalación: [$FS_TEST_ID]  (NUEVA: se dará de alta en el registro)"
else
    echo "   instalación: [$FS_TEST_ID]  (ya registrada: se recupera su bloque)"
fi

# LA RAÍZ NO SE PREGUNTA NI SE HEREDA: es donde estamos, y punto.
#
# Se forzaba a preguntarla con el valor del `.fs-test-env.env` existente como defecto, y ahí había un
# fallo real que destapó la prueba de la copia: **una copia hereda el fichero generado del original**,
# así que `TESTENV_REPO_PATH` entraba con la ruta del ORIGINAL y la copia se registraba apuntando a
# él. Es exactamente el defecto que este registro viene a quitar, colado por la puerta de atrás.
TESTENV_REPO_PATH="$FS_PROJECT_ROOT"
# Y lo mismo con el directorio del core de pruebas: si lo heredado NO cuelga de este proyecto, es de
# otro y no vale. Se recalcula en vez de arrastrarlo.
case "${TESTENV_DIR:-}" in
    "$FS_PROJECT_ROOT"/*) ;;
    *) TESTENV_DIR="$FS_PROJECT_ROOT/test-env/facturascripts" ;;
esac

# (A) LO QUE SÍ SE PREGUNTA: lo de esta máquina que no se puede inferir de nada.
ask FS_TEST_DIR       "Ruta absoluta del arnés (host=contenedor)" "$FS_TEST_DIR"
ask TESTENV_DIR       "Directorio del core de pruebas" "$TESTENV_DIR"
ask TESTENV_RUN_USER  "Usuario que corre apache dentro del contenedor" "${TESTENV_RUN_USER:-www-data}"

# (C) solo si la instalación es NUEVA. Si ya está registrada, cambiarla aquí crearía una segunda
# verdad: se edita `config/instalaciones.conf`, que es donde vive.
if [ "$NUEVA" = "1" ]; then
    echo "   -- configuración del producto (se guardará en el registro) --"
    ask CORE_REPO        "Repositorio del core" "${CORE_REPO:-https://github.com/NeoRazorX/facturascripts.git}"
    ask CORE_BRANCH      "Rama o tag del core (vacío = versión instalada)" "${CORE_BRANCH:-}"
    ask ENABLE_LIST      "Plugins del warm-up (vacío = todos los enlazados)" "${ENABLE_LIST:-}"
    ask FS_LANG          "Idioma (FS_LANG)" "${FS_LANG:-es_ES}"
    ask FS_TIMEZONE      "Zona horaria (FS_TIMEZONE)" "${FS_TIMEZONE:-UTC}"
    ask TEST_WEB_TITLE   "Título del runner web" "${TEST_WEB_TITLE:-Tests de plugins}"
    ask TESTENV_IMAGE    "Imagen del contenedor" "${TESTENV_IMAGE:-localhost/php_devel:8.4}"
    ask TESTENV_NETWORK  "Red compose" "${TESTENV_NETWORK:-default}"
    ask CONTAINER_ENGINE "Motor de contenedores (podman | docker)" "${CONTAINER_ENGINE:-podman}"
fi

# (B) lo derivado se ENSEÑA, no se pregunta: quien lo vea puede desmentirlo.
echo "   -- derivado, ni se pregunta ni se guarda --"
printf '      %-24s %s\n' TEST_DB "$TEST_DB" TESTENV_CONTAINER "${TESTENV_CONTAINER:-}" \
       TESTENV_HOST "${TESTENV_HOST:-}" TEST_WEB_URL "${TEST_WEB_URL:-}" \
       TESTENV_SERVICE "${TESTENV_SERVICE:-}" TESTENV_TRAEFIK_ROUTER "${TESTENV_TRAEFIK_ROUTER:-}" \
       TESTENV_DB_SERVICE "${TESTENV_DB_SERVICE:-}" FS_CORE_DIR "$FS_CORE_DIR"

# LA GUARDA, ANTES DE ESCRIBIR NADA. Dos comprobaciones y hacen falta las dos: que no sea la base de
# TRABAJO (la que ya existía) y que no sea la de OTRA instalación registrada — el caso del worktree,
# que la primera no ve porque son bases distintas.
registro_guarda_db "$FS_PROJECT_ROOT" "$FS_TEST_ID" "$TEST_DB" "$FS_CORE_DIR" || exit 1

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
# Generado por <arnés>/bin/init-project.sh. Config del despliegue del entorno de test.
FS_CORE_DIR="$FS_CORE_DIR"
TESTENV_REPO_PATH="$TESTENV_REPO_PATH"
FS_TEST_DIR="$FS_TEST_DIR"
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
echo "   escrito $ENV_FILE  (GENERADO: no se versiona)"

# --- (A) la máquina: se guarda SIEMPRE, para que la próxima vez no haya que preguntar ------------
registro_maquina_guarda "$FS_TEST_ID" \
    "repo_path=$TESTENV_REPO_PATH" "core_dir=$FS_CORE_DIR" \
    "testenv_dir=$TESTENV_DIR" "run_user=$TESTENV_RUN_USER"
echo "   registrado [$FS_TEST_ID] en $REGISTRO_MAQUINA  (de esta máquina, no se versiona)"

# --- que el generado DEJE DE VERSIONARSE, y por construcción -------------------------------------
# Era un paso manual al final de la ayuda («añade esto a tu .gitignore»), y un paso manual es el
# único que ningún script verifica. Mientras el fichero siga versionado en el repo del cliente,
# sigue en pie el defecto que este registro viene a quitar: rutas absolutas de una máquina dentro
# del repo, y una copia que nace sucia porque hay que reescribirlo.
GITIGNORE="$FS_PROJECT_ROOT/.gitignore"
for patron in '/.fs-test-env.env' '/.fs-test-env/'; do
    if [ -f "$GITIGNORE" ] && grep -qxF "$patron" "$GITIGNORE"; then continue; fi
    printf '%s\n' "$patron" >> "$GITIGNORE"
    echo "   .gitignore += $patron"
done
# Y decirlo si además sigue RASTREADO, porque ignorar no desversiona: `git rm --cached` es una
# decisión de quien lleva ese repo, no de este script.
if git -C "$FS_PROJECT_ROOT" ls-files --error-unmatch .fs-test-env.env >/dev/null 2>&1; then
    echo "   AVISO: .fs-test-env.env sigue RASTREADO por git en este repo." >&2
    echo "          Ignorarlo no lo desversiona. Para cerrarlo del todo:" >&2
    echo "            git -C $FS_PROJECT_ROOT rm --cached .fs-test-env.env" >&2
    echo "          Hasta entonces, este fichero generado sigue viajando en los commits." >&2
fi

# --- (C) el registro del producto: solo si la instalación era NUEVA ------------------------------
# Que el alta sea parte del flujo y no un paso manual que alguien recuerde: un paso manual es el
# único que ningún script verifica, y es el que se salta.
# Una copia HEREDADA no se da de alta: su configuración es la del padre y una entrada por worktree
# llenaría el registro versionado de copias efímeras. Su base de test sigue vigilada, porque la
# guarda mira el fichero de MÁQUINA —donde sí queda registrada— y no éste.
if [ "$NUEVA" = "1" ]; then
    {
        printf '\n[%s]\n' "$FS_TEST_ID"
        printf '%-16s = %s\n' descripcion "" core_repo "$CORE_REPO" core_branch "$CORE_BRANCH" \
               enable_list "$ENABLE_LIST" fs_lang "$FS_LANG" fs_timezone "$FS_TIMEZONE" \
               test_web_title "$TEST_WEB_TITLE" testenv_image "$TESTENV_IMAGE" \
               testenv_network "$TESTENV_NETWORK" container_engine "$CONTAINER_ENGINE"
    } >> "$REGISTRO_CONF"
    echo "   ALTA de [$FS_TEST_ID] en $REGISTRO_CONF"
    echo "   → ese fichero SÍ se versiona: commitéalo, y pon su 'descripcion'."
fi

# --- renderizar plantillas ---
render() {  # render <plantilla>
    sed \
        -e "s#@@FS_CORE_DIR@@#${FS_CORE_DIR}#g" \
        -e "s#@@TESTENV_REPO_PATH@@#${TESTENV_REPO_PATH}#g" \
        -e "s#@@FS_TEST_DIR@@#${FS_TEST_DIR}#g" \
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

SERVICE_TMPL="$FS_TEST_DIR/templates/testenv.service.$CONTAINER_ENGINE.tmpl.yaml"
[ -f "$SERVICE_TMPL" ] || { echo "ERROR: no existe la plantilla $SERVICE_TMPL" >&2; exit 1; }

mkdir -p "$OUT_DIR"
render "$FS_TEST_DIR/templates/test.conf.tmpl" > "$OUT_DIR/test.conf"
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

1) La config local ya está ignorada (`.fs-test-env.env` y `.fs-test-env/`):
     este script la añade al .gitignore, porque el fichero es GENERADO y no debe versionarse.

2) Pega el servicio de $OUT_DIR/service.yaml en tu compose y levántalo:
     $UP_CMD
   El vhost $OUT_DIR/test.conf ya está referenciado en el servicio
   (./.fs-test-env/test.conf -> /etc/apache2/sites-enabled/test.conf).

3) Provisiona el entorno:
     - en el host:      \$FS_TEST_DIR/bin/setup-test-env.sh   (interactivo)
     - o en contenedor: se ejecuta test-env-provision.sh al arrancar.
================================================================
EOF
