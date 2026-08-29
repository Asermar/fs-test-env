#!/usr/bin/env bash
# =============================================================================
# Batería del TEARDOWN: `--keep-db` se retiró y pasarlo FALLA sin tocar nada.
#
#   test/teardown.sh                 # desde la raíz del arnés
#   test/teardown.sh /ruta/al/arnes  # o diciéndole dónde está
#
# ## POR QUÉ ES UN GUION APARTE
#
# Igual que `test/provision.sh`: `registro.sh` comprueba el registro de
# instalaciones y `provision.sh` una decisión del provisionador. Esto comprueba
# el TEARDOWN, que no usa ni lo uno ni lo otro.
#
# ## QUÉ SE COMPRUEBA Y QUÉ NO
#
# **Que el rechazo no borra**, que es la mitad que no verifica sola: un caso cuyo
# resultado esperado es «no hizo nada» sale verde también cuando el script está
# roto y no hace nada nunca. Por eso hay un CONTROL POSITIVO —la invocación sin
# opciones, que SÍ borra el directorio— y por eso la fixture se rehace antes de
# cada caso: sin él, «el directorio sigue ahí» no significaría nada.
#
# Lo que NO se comprueba aquí es el borrado de la BD: haría falta una base, y esta
# batería no tiene ninguna. La fixture no lleva `src/config.php` a propósito, así
# que el teardown llega al paso de la BD, no puede leer credenciales y lo omite
# con un aviso — que es justo el camino que deja el resto observable sin base.
#
# **AUTOCONTENIDA**: monta su proyecto de pega en un temporal y lo borra al salir.
# Sin contenedores, sin base de datos y sin red.
# =============================================================================
set -uo pipefail

T="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TD="$T/bin/test-env-teardown.sh"
[ -x "$TD" ] || { echo "ERROR: no encuentro el teardown en $TD" >&2; exit 1; }

BASE="$(mktemp -d "${TMPDIR:-/tmp}/fs-test-teardown-XXXXXX")"
trap 'rm -rf "$BASE"' EXIT

OK=0; FALLOS=0
ok()  { OK=$((OK+1));         printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
mal() { FALLOS=$((FALLOS+1)); printf '  \033[1;31m✗\033[0m %s\n' "$*"; }

PROY="$BASE/proy"
DIRENV="$PROY/test-env/facturascripts"

# Rehace el proyecto de pega desde cero. Se llama ANTES DE CADA CASO para que ninguno herede el
# estado del anterior: si el control positivo corriera primero y borrara el directorio, los casos
# de rechazo pasarían por el motivo equivocado.
fixture() {
    rm -rf "$PROY"
    mkdir -p "$DIRENV/vendor"
    : > "$DIRENV/HUELLA"
    cat > "$PROY/.fs-test-env.env" <<ENV
TESTENV_DIR="$DIRENV"
TEST_DB="fs_test_de_pega"
ENV
}
# Invoca el teardown sobre el proyecto de pega. NO_COLOR para poder buscar texto sin códigos ANSI.
corre() { NO_COLOR=1 FS_PROJECT_ROOT="$PROY" "$TD" "$@" 2>&1; }

printf '\n\033[1;36m— CONTROL POSITIVO: sin opciones, SÍ borra el directorio —\033[0m\n'
# Va primero porque es lo que da sentido a todo lo de abajo: sin esto, «el directorio sigue ahí»
# se cumpliría también con un script que no borra nunca.
fixture
[ -f "$DIRENV/HUELLA" ] && ok "la fixture existe antes" || mal "la fixture no se creó"
SAL="$(corre)"; RC=$?
[ "$RC" -eq 0 ] && ok "sale 0" || mal "falla sin opciones (rc $RC)"
[ -e "$DIRENV" ] && mal "no borró el directorio: la fixture NO es borrable y el resto no prueba nada" \
    || ok "y el directorio ya no está"
grep -qF 'omito el borrado de la BD' <<<"$SAL" && ok "…y avisa de que omite la BD (sin config no hay credenciales)" \
    || mal "no avisa de que se salta la BD"

printf '\n\033[1;36m— --keep-db se RETIRÓ: falla y NO borra —\033[0m\n'
fixture
SAL="$(corre --keep-db)"; RC=$?
[ "$RC" -ne 0 ] && ok "falla (rc $RC)" || mal "acepta --keep-db"
[ -f "$DIRENV/HUELLA" ] && ok "y NO borró nada: falla antes del rm -rf" || mal "borró el directorio pese a rechazar el flag"
grep -qF 'se retiró' <<<"$SAL" && ok "dice que se retiró" || mal "no dice qué pasó con el flag"
grep -qF -- '--recrear-bd' <<<"$SAL" && ok "…y nombra qué usar en su lugar" || mal "no da salida"
grep -qF 'NO ha hecho nada' <<<"$SAL" && ok "…y deja claro que esta invocación no hizo nada" \
    || mal "no aclara que no hizo nada: quien lo lea puede creer que sí borró"

printf '\n\033[1;36m— y cualquier otra opción, igual —\033[0m\n'
fixture
SAL="$(corre --keep-database)"; RC=$?
[ "$RC" -ne 0 ] && ok "un flag desconocido falla (rc $RC)" || mal "se ignora un flag desconocido"
grep -qF -- '--keep-database' <<<"$SAL" && ok "…y NOMBRA el que no entendió" || mal "no dice cuál era"
[ -f "$DIRENV/HUELLA" ] && ok "…y tampoco borró nada" || mal "borró pese a rechazar"

printf '\n\033[1;36m— la raíz del proyecto sale del DIRECTORIO ACTUAL, no de dónde está el arnés —\033[0m\n'
# El default era `$SCRIPT_DIR/../..`, que valía cuando el arnés vivía dentro del proyecto; desde la
# mudanza resuelve a la carpeta que contiene al arnés (`~/Dev/Tooling`), que no es un proyecto. Se
# comprueba SIN pasar FS_PROJECT_ROOT: si el default fuera el viejo, no encontraría esta fixture.
fixture
SAL="$(cd "$PROY" && NO_COLOR=1 "$TD" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "invocado desde la raíz del proyecto, sale 0" || mal "no funciona sin FS_PROJECT_ROOT (rc $RC)"
grep -qF "$DIRENV" <<<"$SAL" && ok "…y trabaja sobre el test-env DEL PROYECTO" \
    || mal "no encontró el .fs-test-env.env del proyecto: el default no es el directorio actual"
[ -e "$DIRENV" ] && mal "no borró el directorio del proyecto" || ok "…y lo borró"

printf '\n'
[ "$FALLOS" -eq 0 ] && { printf '\033[1;32m%s comprobaciones, todas en verde.\033[0m\n' "$OK"; exit 0; }
printf '\033[1;31m%s en verde, %s FALLIDAS.\033[0m\n' "$OK" "$FALLOS"; exit 1
