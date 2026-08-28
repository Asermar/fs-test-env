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
genera() { FS_TEST_ID="$1" FS_PROJECT_ROOT="$2" FS_TEST_DIR="$T" "$T/bin/init-project.sh" < /dev/null 2>&1; }

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

printf '\n'
[ "$FALLOS" -eq 0 ] && { printf '\033[1;32m%s comprobaciones, todas en verde.\033[0m\n' "$OK"; exit 0; }
printf '\033[1;31m%s en verde, %s FALLIDAS.\033[0m\n' "$OK" "$FALLOS"; exit 1
