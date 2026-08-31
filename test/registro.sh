#!/usr/bin/env bash
# =============================================================================
# Batería del REGISTRO DE INSTALACIONES: la herencia de una copia, sus guardas y
# lo que el generador deriva. Es el primer test de este repo.
#
#   test/registro.sh                 # desde la raíz del arnés
#   test/registro.sh /ruta/al/arnes  # o diciéndole dónde está
#
# ## LO QUE ESTA BATERÍA NO ES, y hay que saberlo antes de leer sus verdes
#
# **Nació DESPUÉS del código que comprueba.** Es una reconstrucción: la
# verificación original vivía en línea, dentro de los `bash -c` con los que se
# fue construyendo el registro, y se perdió al terminar. Así que **NO validó los
# cambios de esta rama mientras se hacían**: su valor es de REGRESIÓN — atrapa lo
# que se rompa de aquí en adelante, no acredita lo que ya está hecho.
#
# Se dice aquí porque es justo lo que el siguiente no puede deducir: leer «22
# comprobaciones, todas en verde» invita a creer que este trabajo estuvo cubierto
# mientras se hacía, y no lo estuvo.
#
# ## AUTOCONTENIDA
#
# No toca el registro versionado, ni el fichero de máquina real, ni ningún
# proyecto de verdad: se fabrica sus instalaciones de pega —un `src/config.php` y
# un compose mínimos— en un temporal y lo borra al salir. No necesita
# contenedores, ni base de datos, ni red. Lo único que hace falta fuera es `php`,
# y no lo añade ella: lo usa `bin/lib/registro.sh` para leer `FS_DB_NAME`.
# =============================================================================
set -uo pipefail

# La raíz del arnés es el PADRE de este directorio: la batería vive en `test/`.
T="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
[ -x "$T/bin/init-project.sh" ] || { echo "ERROR: no encuentro el arnés en $T" >&2; exit 1; }

BASE="$(mktemp -d "${TMPDIR:-/tmp}/fs-test-registro-XXXXXX")"
trap 'rm -rf "$BASE"' EXIT
export REGISTRO_MAQUINA="$BASE/maquina.conf" REGISTRO_CONF="$BASE/instalaciones.conf"
cp "$T/config/instalaciones.conf" "$REGISTRO_CONF"

OK=0; FALLOS=0
ok()  { OK=$((OK+1));         printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
mal() { FALLOS=$((FALLOS+1)); printf '  \033[1;31m✗\033[0m %s\n' "$*"; }
bloques() { sed -n 's/^\[\(.*\)\]$/\1/p' "$1" | tr '\n' ' '; }
tiene()   { case " $(bloques "$1") " in *" $2 "*) return 0 ;; *) return 1 ;; esac; }
valor()   { grep "^$2=" "$1/.fs-test-env.env" | cut -d'"' -f2; }

# instalacion <dir> <FS_DB_NAME> — un proyecto de pega con lo mínimo que el generador lee
instalacion() {
    rm -rf "$1"; mkdir -p "$1/src/Core" "$1/podman"
    printf '<?php\ndefine("FS_DB_NAME","%s");\n' "$2" > "$1/src/config.php"
    printf 'services:\n  db:\n    container_name: %s-db\n  t:\n    container_name: %s-test\n    labels:\n      - traefik.http.routers.%s-test.rule=Host(`%s-test.asermar.com`)\n' \
        "$2" "$2" "$2" "$2" > "$1/podman/podman-compose.yaml"
}
genera() { FS_TEST_ID="$1" FS_PROJECT_ROOT="$2" FS_TEST_DIR="$T" "$T/bin/init-project.sh" "${@:3}" < /dev/null 2>&1; }

printf '\n\033[1;36m— una COPIA hereda del padre, y es el caso que puede fallar —\033[0m\n'
instalacion "$BASE/c1" mesafs_rutas; SAL="$(genera mesa-fs-wt-rutas "$BASE/c1")"
grep -qF 'hereda la configuración de producto de [mesa-fs]' <<<"$SAL" && ok "hereda, y lo DICE en voz alta" || mal "fallback silencioso"
grep -qF 'configuración del producto (se guardará' <<<"$SAL" && mal "sigue preguntando la clase (C)" || ok "no pregunta nada de producto: sirve desde okoworktree"
[ "$(valor "$BASE/c1" FS_TIMEZONE)" = 'Atlantic/Canary' ] && ok "heredó la clase (C) del padre" || mal "no heredó la (C)"
[ "$(valor "$BASE/c1" TESTENV_REPO_PATH)" = "$BASE/c1" ] && ok "NO heredó la ruta: la clase (A) es suya" || mal "heredó una ruta absoluta del padre"
[ "$(valor "$BASE/c1" TEST_DB)" = 'mesafs_rutas_test' ] && ok "derivó SU base de test" || mal "base mal derivada"
tiene "$REGISTRO_CONF" mesa-fs-wt-rutas && mal "ensucia el registro versionado con una copia" || ok "no ensucia el registro versionado"
tiene "$REGISTRO_MAQUINA" mesa-fs-wt-rutas && ok "queda en el de máquina, así que la guarda la ve" || mal "no queda en el de máquina"

printf '\n\033[1;36m— LA PAREJA: una instalación nueva de verdad sigue preguntando —\033[0m\n'
# Sin esto, el fallback podría haberse convertido en un tragadero de defaults.
instalacion "$BASE/c2" clientenuevo; SAL="$(genera cliente-nuevo "$BASE/c2")"
grep -qF '(NUEVA:' <<<"$SAL" && ok "la trata como nueva" || mal "no la trata como nueva"
grep -qF 'configuración del producto (se guardará' <<<"$SAL" && ok "SIGUE preguntando la clase (C)" || mal "ha dejado de preguntar"
tiene "$REGISTRO_CONF" cliente-nuevo && ok "se da de alta en el registro" || mal "no se da de alta"

printf '\n\033[1;36m— EL NEGATIVO: una copia SIN ANCLA no se configura, FALLA —\033[0m\n'
# El bloque del proyecto es su ANCLA y lo crea el proyecto, no la primera copia que pase. Antes esto
# se trataba como «instalación nueva» y escribía el ancla bajo el id de la COPIA: a partir de ahí
# ninguna copia siguiente encontraba a su padre y el registro degeneraba en una entrada por copia.
instalacion "$BASE/c3" huerfana; SAL="$(genera noexiste-wt-x "$BASE/c3")"; RC=$?
[ "$RC" -ne 0 ] && ok "falla en vez de configurarse (rc $RC)" || mal "no falla: sigue tratándola como nueva"
grep -qF 'init-project.sh' <<<"$SAL" && ok "el mensaje dice QUÉ ejecutar" || mal "el mensaje no nombra el generador"
grep -qF 'noexiste' <<<"$SAL" && ok "…y nombra el ancla que falta" || mal "no dice qué ancla falta"
tiene "$REGISTRO_CONF" noexiste-wt-x && mal "escribió en el registro versionado" || ok "no escribió en el registro versionado"
tiene "$REGISTRO_MAQUINA" noexiste-wt-x && mal "escribió en el de máquina" || ok "ni en el de máquina"
[ -f "$BASE/c3/.fs-test-env.env" ] && mal "generó el fichero pese a fallar" || ok "y no generó nada"

printf '\n\033[1;36m— la guarda sigue viendo las copias, aunque no estén en el registro —\033[0m\n'
instalacion "$BASE/c4" mesafs_rutas; SAL="$(genera mesa-fs-wt-choque "$BASE/c4")"; RC=$?
[ "$RC" -ne 0 ] && ok "dos copias con la misma base: se NIEGA (rc $RC)" || mal "no se niega: la guarda dejó de verlas"
grep -qF 'mesa-fs-wt-rutas' <<<"$SAL" && ok "…y nombra con cuál choca" || mal "no dice con cuál choca"
[ -f "$BASE/c4/.fs-test-env.env" ] && mal "escribió pese a negarse" || ok "y no escribió nada"
# PAREJA: con su propia base, pasa. Sin esto, «se niega» podría ser «se niega siempre».
instalacion "$BASE/c5" mesafs_otra; genera mesa-fs-wt-otra "$BASE/c5" >/dev/null; RC=$?
[ "$RC" -eq 0 ] && ok "…y una copia con SU base sí se configura" || mal "se niega también con base propia"

printf '\n\033[1;36m— el compose sin router de traefik no mata al generador —\033[0m\n'
# Lo destapó una fixture: `set -u` moría con «TEST_WEB_URL: unbound variable».
rm -rf "$BASE/c6"; mkdir -p "$BASE/c6/src/Core" "$BASE/c6/podman"
printf '<?php\ndefine("FS_DB_NAME","sinrouter");\n' > "$BASE/c6/src/config.php"
printf 'services:\n  t:\n    container_name: sinrouter-test\n' > "$BASE/c6/podman/podman-compose.yaml"
genera mesa-fs-wt-sinrouter "$BASE/c6" >/dev/null; RC=$?
[ "$RC" -eq 0 ] && ok "sale 0 con un compose sin traefik" || mal "muere sin router (rc $RC)"
[ -z "$(valor "$BASE/c6" TEST_WEB_URL)" ] && ok "…y deja vacío lo que no puede derivar" || mal "se inventó una URL"

printf '\n\033[1;36m— dar de baja del fichero de máquina —\033[0m\n'
# La simétrica de `guarda` no existía, y por eso el fichero acumulaba instalaciones muertas: la
# entrada la escribe `init-project.sh` al configurar una copia y no la borraba nadie al retirarla.
# Medido el 30-ago-2026: cuatro bloques huérfanos. Se prueba en las dos direcciones —que quita lo
# suyo y que NO se lleva lo ajeno—, porque un borrado por bloques falla siempre hacia el mismo lado.
M="$BASE/baja.conf"
( export REGISTRO_MAQUINA="$M"
  source "$T/bin/lib/registro.sh"
  registro_maquina_guarda uno  repo_path=/a core_dir=src
  registro_maquina_guarda dos  repo_path=/b core_dir=src
  registro_maquina_guarda tres repo_path=/c core_dir=src )

( export REGISTRO_MAQUINA="$M"; source "$T/bin/lib/registro.sh"; registro_maquina_borra dos )
tiene "$M" dos && mal "el bloque borrado sigue ahí" || ok "quita el bloque que se le pide"
tiene "$M" uno && tiene "$M" tres && ok "…y deja intactos los demás" || mal "se llevó bloques ajenos"
[ "$(grep -c 'repo_path' "$M")" -eq 2 ] && ok "…con sus datos, no sólo la cabecera" || mal "perdió claves de los que quedan"

# Distinguir «no había nada» de «lo he quitado» es lo que hace comprobable el borrado: si dijera lo
# mismo en los dos casos, sería indistinguible de una función que no hace nada.
( export REGISTRO_MAQUINA="$M"; source "$T/bin/lib/registro.sh"; registro_maquina_borra inexistente ) \
    && mal "sale 0 con un id que no está" || ok "sale 1 con un id que no está"

# El caso que de verdad muerde: el id del ancla es PREFIJO del de todas sus copias
# (`mesa-fs` ⊂ `mesa-fs-wt-colorbox`), así que un borrado por coincidencia parcial se las llevaría.
( export REGISTRO_MAQUINA="$M"
  source "$T/bin/lib/registro.sh"
  registro_maquina_guarda mesa-fs              repo_path=/x core_dir=src
  registro_maquina_guarda mesa-fs-wt-colorbox  repo_path=/y core_dir=src
  registro_maquina_borra  mesa-fs >/dev/null )
tiene "$M" mesa-fs-wt-colorbox && ok "borrar el ancla NO se lleva sus copias (el id es prefijo)" \
    || mal "se llevó la copia al borrar el ancla"
tiene "$M" mesa-fs && mal "el ancla sigue ahí" || ok "…y el ancla sí se fue"


printf '\n\033[1;36m— UNA COPIA RECIBE SU IDENTIDAD, NO LA DEL ANCLA —\033[0m\n'
# EL DEFECTO: el compose de un cliente declara sus nombres con `${STACK_SUFFIX:-}` dentro
# (`lcp-fs${STACK_SUFFIX:-}-test`), y `registro_compose` BORRABA esa interpolación en vez de
# sustituirla, así que en una copia derivaba los nombres del ORIGINAL. Medido el 30-ago-2026 sobre
# una copia real: contenedor, host, URL y router, los cuatro del árbol original; sólo `TEST_DB` y las
# rutas salían bien, porque ésas ya se derivaban de la propia copia.
#
# Y no causaba daño visible por una razón que no es una salvaguarda: `okoworktree` REESCRIBE esos
# cuatro valores justo después. O sea que el aislamiento dependía del ORDEN DE LLAMADA, no de la
# herramienta que escribe el fichero — quien siguiera a mano el mensaje de un fallo y provisionara a
# continuación, provisionaría contra el entorno de pruebas del original.
#
# POR QUÉ ESTA BATERÍA MONTA AHORA UN REPO DE GIT. La cabecera de `test/provision.sh` dice que meter
# las dos juntas «obligaría a que la del registro montara repos de git para nada». Ya no es para
# nada: lo que se comprueba aquí es qué DERIVA el registro, y la señal que distingue una copia de un
# principal es de git (`ancla_es_worktree`). El árbol es la fixture mínima de esa señal, no un
# añadido.

# copia_git <dir del principal> <sufijo> <FS_DB_NAME del principal>
# Un principal con su copia de git de verdad, y el compose interpolando el sufijo COMO LO HACE UN
# CLIENTE REAL — es lo único que reproduce el defecto: con un `container_name` literal no habría nada
# que sustituir y el test saldría verde con el fallo puesto.
copia_git() {
    local base="$1" suf="$2" db="$3" wt="$1-wt-$2"
    rm -rf "$base" "$wt"
    mkdir -p "$base/src/Core" "$base/podman"
    # EL `.keep` NO ES DECORACIÓN: git no versiona directorios vacíos, así que un `src/Core` vacío no
    # viaja al worktree, y sin él `FS_CORE_DIR` cae a «.» y el generador no encuentra el config.php.
    # Se descubrió corriendo el test, no leyéndolo.
    : > "$base/src/Core/.keep"
    printf '<?php\ndefine("FS_DB_NAME","%s");\n' "$db" > "$base/src/config.php"
    cat > "$base/podman/podman-compose.yaml" <<'YAML'
services:
  db:
    container_name: pega-fs${STACK_SUFFIX:-}-db
  t:
    container_name: pega-fs${STACK_SUFFIX:-}-test
    labels:
      - traefik.http.routers.pegafs-test.rule=Host(`pega-fs${STACK_SUFFIX:-}-test.asermar.com`)
YAML
    git init -q "$base"
    ( cd "$base" && git -c user.email=t@t -c user.name=t add -A >/dev/null \
      && git -c user.email=t@t -c user.name=t commit -q -m x )
    git -C "$base" worktree add -q --detach "$wt" HEAD
    # La copia tiene SU base de trabajo, como se la deja `okoworktree` al regenerar su config.
    printf '<?php\ndefine("FS_DB_NAME","%s_%s");\n' "$db" "$suf" > "$wt/src/config.php"
}

copia_git "$BASE/g1" suf pegafs
SAL="$(genera mesa-fs-wt-suf "$BASE/g1-wt-suf")"; RC=$?
# ANTES DE MIRAR NINGÚN VALOR, que el fichero exista. Sin esto, `valor` devuelve vacío y el negativo
# de abajo —«ninguno es el del original»— sale verde solo, que es el modo de fallo más caro: una
# comprobación que no puede fallar. Pasó al escribir este bloque.
{ [ "$RC" -eq 0 ] && [ -f "$BASE/g1-wt-suf/.fs-test-env.env" ]; } \
    && ok "la copia se configura (rc 0) y escribe su .fs-test-env.env" \
    || mal "la copia no llegó a configurarse (rc $RC): lo de abajo no mediría nada — $(head -3 <<<"$SAL")"
[ "$(valor "$BASE/g1-wt-suf" TESTENV_CONTAINER)" = 'pega-fs-suf-test' ] \
    && ok "TESTENV_CONTAINER lleva el sufijo de la copia" \
    || mal "TESTENV_CONTAINER es del ORIGINAL: $(valor "$BASE/g1-wt-suf" TESTENV_CONTAINER)"
[ "$(valor "$BASE/g1-wt-suf" TESTENV_HOST)" = 'pega-fs-suf-test.asermar.com' ] \
    && ok "…y TESTENV_HOST también" \
    || mal "TESTENV_HOST es del ORIGINAL: $(valor "$BASE/g1-wt-suf" TESTENV_HOST)"
[ "$(valor "$BASE/g1-wt-suf" TEST_WEB_URL)" = 'https://pega-fs-suf-test.asermar.com' ] \
    && ok "…y TEST_WEB_URL" \
    || mal "TEST_WEB_URL es del ORIGINAL: $(valor "$BASE/g1-wt-suf" TEST_WEB_URL)"
# El router NO se arregla por interpolación: su nombre es la CLAVE de la etiqueta de traefik y
# `podman-compose` 1.0.6 interpola valores, nunca claves. Así que en el compose es literal y hay que
# sufijarlo aparte. Y hace falta: dos copias que declaren el mismo router se anulan MUTUAMENTE en
# traefik, y de paso tumban al original.
[ "$(valor "$BASE/g1-wt-suf" TESTENV_TRAEFIK_ROUTER)" = 'pegafs-suf-test' ] \
    && ok "…y TESTENV_TRAEFIK_ROUTER, que va aparte porque es una clave de etiqueta" \
    || mal "TESTENV_TRAEFIK_ROUTER es del ORIGINAL: $(valor "$BASE/g1-wt-suf" TESTENV_TRAEFIK_ROUTER)"

# EL CONTROL QUE DISTINGUE «lleva el sufijo» de «heredó»: que ninguno sea el del original. Sin esto,
# un arreglo que pegara el sufijo en el sitio equivocado podría salir verde arriba.
COINCIDE=0
for par in "TESTENV_CONTAINER=pega-fs-test" "TESTENV_HOST=pega-fs-test.asermar.com" \
           "TEST_WEB_URL=https://pega-fs-test.asermar.com" "TESTENV_TRAEFIK_ROUTER=pegafs-test"; do
    [ "$(valor "$BASE/g1-wt-suf" "${par%%=*}")" = "${par#*=}" ] && COINCIDE=$((COINCIDE+1))
done
[ "$COINCIDE" -eq 0 ] && ok "…y NINGUNO de los cuatro es el del original" \
    || mal "$COINCIDE de los cuatro siguen siendo los del original"

printf '\n\033[1;36m— EL SIMÉTRICO: en el PRINCIPAL los cuatro siguen SIN sufijo —\033[0m\n'
# Si el arreglo sufijara también aquí, rompería el ALTA DEL ANCLA, que es el único caso legítimo de
# configurar en el principal y el que existe el escape `--en-el-principal` para permitir.
SAL="$(genera mesa-fs "$BASE/g1" --en-el-principal)"; RC=$?
[ "$RC" -eq 0 ] && ok "el alta del ancla en el principal sigue funcionando (rc 0)" \
    || mal "el arreglo rompió el alta del ancla (rc $RC)"
grep -qF 'en el checkout PRINCIPAL con --en-el-principal' <<<"$SAL" \
    && ok "…y el escape sigue avisando" || mal "el escape dejó de avisar"
[ "$(valor "$BASE/g1" TESTENV_CONTAINER)" = 'pega-fs-test' ] \
    && ok "TESTENV_CONTAINER del principal SIN sufijo" \
    || mal "le puso sufijo al principal: $(valor "$BASE/g1" TESTENV_CONTAINER)"
[ "$(valor "$BASE/g1" TESTENV_HOST)" = 'pega-fs-test.asermar.com' ] \
    && ok "…y TESTENV_HOST igual" || mal "host del principal contaminado: $(valor "$BASE/g1" TESTENV_HOST)"
[ "$(valor "$BASE/g1" TESTENV_TRAEFIK_ROUTER)" = 'pegafs-test' ] \
    && ok "…y el router igual" || mal "router del principal contaminado: $(valor "$BASE/g1" TESTENV_TRAEFIK_ROUTER)"

printf '\n\033[1;36m— un compose SIN interpolación no se rompe ni se inventa un sufijo —\033[0m\n'
# La pareja del caso de arriba: no todo compose interpola. Uno con nombres literales tiene que salir
# EXACTAMENTE como hoy, aunque se lance desde una copia — el arreglo sustituye lo que hay, no añade.
rm -rf "$BASE/g2" "$BASE/g2-wt-otro"
mkdir -p "$BASE/g2/src/Core" "$BASE/g2/podman"
: > "$BASE/g2/src/Core/.keep"
printf '<?php\ndefine("FS_DB_NAME","literal");\n' > "$BASE/g2/src/config.php"
printf 'services:\n  t:\n    container_name: literal-test\n' > "$BASE/g2/podman/podman-compose.yaml"
git init -q "$BASE/g2"
( cd "$BASE/g2" && git -c user.email=t@t -c user.name=t add -A >/dev/null \
  && git -c user.email=t@t -c user.name=t commit -q -m x )
git -C "$BASE/g2" worktree add -q --detach "$BASE/g2-wt-otro" HEAD
printf '<?php\ndefine("FS_DB_NAME","literal_otro");\n' > "$BASE/g2-wt-otro/src/config.php"
genera mesa-fs-wt-otro2 "$BASE/g2-wt-otro" >/dev/null; RC=$?
[ "$RC" -eq 0 ] && ok "sale 0 con un compose de nombres literales" || mal "muere sin interpolación (rc $RC)"
[ "$(valor "$BASE/g2-wt-otro" TESTENV_CONTAINER)" = 'literal-test' ] \
    && ok "…y no se inventa un sufijo donde el compose no lo declara" \
    || mal "fabricó un nombre: $(valor "$BASE/g2-wt-otro" TESTENV_CONTAINER)"

printf '\n'
[ "$FALLOS" -eq 0 ] && { printf '\033[1;32m%s comprobaciones, todas en verde.\033[0m\n' "$OK"; exit 0; }
printf '\033[1;31m%s en verde, %s FALLIDAS.\033[0m\n' "$OK" "$FALLOS"; exit 1
