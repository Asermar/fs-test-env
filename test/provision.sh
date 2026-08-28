#!/usr/bin/env bash
# =============================================================================
# Batería de la GUARDA DEL PROVISIONADOR: el entorno de test vive en una copia,
# no en el checkout principal.
#
#   test/provision.sh                 # desde la raíz del arnés
#   test/provision.sh /ruta/al/arnes  # o diciéndole dónde está
#
# ## POR QUÉ ES UN GUION APARTE Y NO UN BLOQUE DE `test/registro.sh`
#
# `registro.sh` comprueba el REGISTRO de instalaciones —herencia, anclas,
# derivación—; esto comprueba una decisión del PROVISIONADOR, que no lo usa. El
# único parecido es que las dos son baterías; meterlas juntas obligaría a que la
# del registro montara repos de git para nada.
#
# ## QUÉ SE COMPRUEBA Y QUÉ NO
#
# **La DECISIÓN de la guarda**, no la provisión entera: que en el principal se
# niega, que en un worktree NO se niega, y que un submódulo sigue contando como
# principal. Provisionar de verdad clona el core y crea una base, así que no cabe
# en una batería autocontenida — eso se verifica a mano, con `okoworktree`.
#
# Y **el PARSEO de opciones**, que sí cabe: que `--recrear-bd` se acepta y que lo
# desconocido se rechaza. Lo que NO cabe aquí es que el DROP ocurra de verdad —eso
# necesita una base—; se verifica a mano y queda dicho para que nadie lea esta
# batería como si acreditara el refresco.
#
# Que un worktree «pasa» se comprueba por lo que ocurre DESPUÉS: el provisionador
# se para en la comprobación siguiente (falta `.fs-test-env.env`), y eso solo
# puede pasar si la guarda lo dejó seguir.
#
# **AUTOCONTENIDA**: monta sus repos de pega en un temporal y lo borra al salir.
# Sin contenedores, sin base de datos y sin red.
# =============================================================================
set -uo pipefail

T="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PROV="$T/bin/test-env-provision.sh"
[ -x "$PROV" ] || { echo "ERROR: no encuentro el provisionador en $PROV" >&2; exit 1; }

BASE="$(mktemp -d "${TMPDIR:-/tmp}/fs-test-provision-XXXXXX")"
trap 'rm -rf "$BASE"' EXIT

OK=0; FALLOS=0
ok()  { OK=$((OK+1));         printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
mal() { FALLOS=$((FALLOS+1)); printf '  \033[1;31m✗\033[0m %s\n' "$*"; }
corre() { FS_PROJECT_ROOT="$1" "$PROV" "${@:2}" 2>&1; }

# --- los tres árboles de pega ------------------------------------------------------------------
# El PRINCIPAL, con un submódulo dentro: el submódulo es el caso que engaña, porque su `.git`
# también es un fichero.
git init -q "$BASE/hijo"; ( cd "$BASE/hijo" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m x )
git init -q "$BASE/principal"
( cd "$BASE/principal" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m x \
  && git -c protocol.file.allow=always -c user.email=t@t -c user.name=t submodule add -q "$BASE/hijo" sub >/dev/null 2>&1 \
  && git -c user.email=t@t -c user.name=t commit -q -m sub )
git -C "$BASE/principal" worktree add -q --detach "$BASE/copia" HEAD

printf '\n\033[1;36m— la señal distingue los tres árboles —\033[0m\n'
[ -f "$BASE/principal/sub/.git" ] && ok "el submódulo tiene el .git como FICHERO (el caso que engaña)" \
    || mal "la fixture no reproduce el caso del submódulo"
[ -f "$BASE/copia/.git" ] && ok "y el worktree también: el tipo de .git NO puede ser la señal" \
    || mal "el worktree no tiene .git como fichero"

printf '\n\033[1;36m— en el checkout PRINCIPAL se niega —\033[0m\n'
SAL="$(corre "$BASE/principal")"; RC=$?
[ "$RC" -ne 0 ] && ok "falla (rc $RC)" || mal "no se niega"
grep -qF 'checkout PRINCIPAL' <<<"$SAL" && ok "dice qué pasa" || mal "mensaje mudo"
grep -qF 'okoworktree add' <<<"$SAL" && ok "…y da la salida buena" || mal "no dice qué hacer"
grep -qF -- '--en-el-principal' <<<"$SAL" && ok "…y nombra el escape en el propio rechazo" || mal "escape no nombrado"
[ -d "$BASE/principal/test-env" ] && mal "creó test-env/ pese a negarse" || ok "y no creó nada"

printf '\n\033[1;36m— EL NEGATIVO: un submódulo del principal SIGUE siendo principal —\033[0m\n'
# Es el que habría fallado en silencio: acierta en la raíz y muerde en cada plugin.
SAL="$(corre "$BASE/principal/sub")"
grep -qF 'checkout PRINCIPAL' <<<"$SAL" && ok "no se toma por worktree" || mal "un submódulo pasa por worktree"

printf '\n\033[1;36m— LA PAREJA: en un WORKTREE la guarda no para —\033[0m\n'
# Si esto se rompe, se ha apagado el entorno de test de la casa entera.
SAL="$(corre "$BASE/copia")"
grep -qF 'checkout PRINCIPAL' <<<"$SAL" && mal "para un worktree legítimo" || ok "deja pasar el worktree"
grep -qF 'no parece un proyecto configurado' <<<"$SAL" && ok "…y sigue hasta la comprobación siguiente" \
    || mal "no llegó a la comprobación siguiente: no prueba que pasara la guarda"

printf '\n\033[1;36m— el escape es explícito y RUIDOSO —\033[0m\n'
SAL="$(corre "$BASE/principal" --en-el-principal)"
grep -qF 'checkout PRINCIPAL, y el entorno' <<<"$SAL" && mal "sigue rechazando con el flag" || ok "el flag deja pasar"
grep -qF 'AVISO: provisionando en el checkout PRINCIPAL' <<<"$SAL" && ok "…y AVISA cada vez que se usa" \
    || mal "el escape es silencioso"

printf '\n\033[1;36m— el PARSEO: --recrear-bd se acepta, lo desconocido se RECHAZA —\033[0m\n'
# Que `--recrear-bd` se acepta se comprueba por lo que ocurre DESPUÉS, igual que arriba con la
# guarda: el provisionador avanza hasta la comprobación siguiente (falta `.fs-test-env.env`), y a
# esa sólo se llega si el parseo lo dejó pasar.
SAL="$(corre "$BASE/copia" --recrear-bd)"
grep -qF 'no parece un proyecto configurado' <<<"$SAL" && ok "--recrear-bd pasa el parseo y sigue" \
    || mal "--recrear-bd no llega a la comprobación siguiente: el parseo lo paró"
grep -qF 'opción desconocida' <<<"$SAL" && mal "trata --recrear-bd como desconocido" || ok "…y no lo toma por desconocido"

# EL CASO QUE MOTIVA EL RECHAZO: un typo. Antes se IGNORABA en silencio —medido: rc y salida
# idénticos a no pasar nada—, así que la provisión seguía SIN refrescar la base y salía 0. Quien lo
# invocó creería tener una base limpia y tendría la de antes.
SAL="$(corre "$BASE/copia" --recrear-db)"; RC=$?
[ "$RC" -ne 0 ] && ok "un typo (--recrear-db) FALLA (rc $RC) en vez de ignorarse" || mal "un typo se ignora: refrescaría nada y saldría 0"
grep -qF -- '--recrear-db' <<<"$SAL" && ok "…y NOMBRA el flag que no entendió" || mal "no dice cuál era"
grep -qF -- '--recrear-bd' <<<"$SAL" && ok "…y enseña el que sí existe" || mal "no ofrece la opción buena"
[ -d "$BASE/copia/test-env" ] && mal "creó test-env/ pese a rechazar el flag" || ok "y no creó nada"

# El negativo del parseo: el flag legítimo de la guarda sigue funcionando (no se ha cerrado de más).
SAL="$(corre "$BASE/principal" --en-el-principal)"
grep -qF 'opción desconocida' <<<"$SAL" && mal "el parseo estricto se comió --en-el-principal" \
    || ok "y --en-el-principal sigue aceptándose"

printf '\n'
[ "$FALLOS" -eq 0 ] && { printf '\033[1;32m%s comprobaciones, todas en verde.\033[0m\n' "$OK"; exit 0; }
printf '\033[1;31m%s en verde, %s FALLIDAS.\033[0m\n' "$OK" "$FALLOS"; exit 1
