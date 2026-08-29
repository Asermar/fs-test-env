#!/usr/bin/env bash
# =============================================================================
# Batería de la GUARDA DEL ANCLA: el entorno de test vive en una copia, no en el
# checkout principal — y eso lo tienen que aplicar los TRES scripts que pueden
# montarlo: `test-env-provision.sh`, `init-project.sh` y `up.sh`.
#
#   test/provision.sh                 # desde la raíz del arnés
#   test/provision.sh /ruta/al/arnes  # o diciéndole dónde está
#
# ## POR QUÉ ES UN GUION APARTE Y NO UN BLOQUE DE `test/registro.sh`
#
# `registro.sh` comprueba el REGISTRO de instalaciones —herencia, anclas,
# derivación—; esto comprueba una DECISIÓN sobre el árbol de trabajo. El único
# parecido es que las dos son baterías; meterlas juntas obligaría a que la del
# registro montara repos de git para nada.
#
# Y por qué los tres scripts se prueban aquí y no en tres ficheros: la fixture
# cara son los tres árboles de git de abajo, y montarla otra vez para cada uno
# sería la misma segunda-verdad que la guarda evita en el código.
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
#
# ## LO QUE NO CUBRE, Y HAY QUE VERIFICAR A MANO
#
# De `up.sh` se comprueba aquí la guarda, la raíz y el mensaje; NO que arranque
# de verdad ni que su postcondición cace un arranque fallido, porque las dos
# cosas exigen un motor de contenedores. Se verifican contra una copia real —
# medido el 29-ago-2026: con el contenedor parado lo deja «running», y contra un
# contenedor que muere al arrancar sale rc 1 diciendo el estado. «Todo en verde»
# aquí no acredita que `up.sh` levante nada.
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
# Se comprueba la parte INVARIANTE del aviso, no la frase entera: desde que la guarda vive en
# `lib/ancla.sh` cada script dice qué está haciendo («provisionando el entorno de test», «generando
# la configuración»…), así que fijar el texto completo ataría la batería a uno de los tres.
grep -qF 'en el checkout PRINCIPAL con --en-el-principal' <<<"$SAL" && ok "…y AVISA cada vez que se usa" \
    || mal "el escape es silencioso"
grep -qF 'provisionando el entorno de test' <<<"$SAL" && ok "…diciendo QUÉ se está haciendo" \
    || mal "el aviso no dice qué acción es"

printf '\n\033[1;36m— init-project.sh: la MISMA guarda, en la puerta de la GENERACIÓN —\033[0m\n'
# Es la puerta por la que entró el caso del 29-ago-2026: generó el `.fs-test-env.env` y el
# `.fs-test-env/` en el principal de Mesa/FS sin protestar.
#
# El registro se desvía a temporales: esta batería NO puede tocar el registro versionado ni el
# fichero de máquina, y el control negativo de abajo SÍ escribe.
export REGISTRO_CONF="$BASE/registro.conf" REGISTRO_MAQUINA="$BASE/maquina.conf"
cp "$T/config/instalaciones.conf" "$REGISTRO_CONF"
INIT="$T/bin/init-project.sh"
corre_init() { FS_PROJECT_ROOT="$1" NO_COLOR=1 "$INIT" "${@:2}" </dev/null 2>&1; }

SAL="$(corre_init "$BASE/principal")"; RC=$?
[ "$RC" -ne 0 ] && ok "en el principal falla (rc $RC)" || mal "genera en el principal"
grep -qF 'checkout PRINCIPAL' <<<"$SAL" && ok "dice qué pasa" || mal "mensaje mudo"
grep -qF 'okoworktree add' <<<"$SAL" && ok "…y ofrece la salida EN EL MISMO mensaje" || mal "no dice qué hacer"
grep -qF -- '--en-el-principal' <<<"$SAL" && ok "…y nombra el escape" || mal "escape no nombrado"
grep -qF 'DAR DE ALTA EL ANCLA' <<<"$SAL" && ok "…y contempla el caso legítimo: el alta del ancla" \
    || mal "no dice cómo se da de alta un ancla, que es lo único que sí va en el principal"
# EL SIMÉTRICO: «se negó» no vale sin comprobar que no dejó nada escrito.
[ -e "$BASE/principal/.fs-test-env.env" ] && mal "escribió el .env pese a negarse" || ok "y NO escribió el .env"
[ -e "$BASE/principal/.fs-test-env" ]     && mal "creó .fs-test-env/ pese a negarse" || ok "…ni el .fs-test-env/"

printf '\n\033[1;36m— EL CONTROL NEGATIVO: en un WORKTREE init-project NO se niega —\033[0m\n'
# Si esto se rompe, se ha apagado la configuración del entorno de toda la casa. Se comprueba por lo
# que ocurre DESPUÉS: llega a la precondición del TEST_DB, y sólo se llega ahí si la guarda dejó pasar.
SAL="$(corre_init "$BASE/copia")"
grep -qF 'checkout PRINCIPAL' <<<"$SAL" && mal "para un worktree legítimo" || ok "deja pasar el worktree"
grep -qF 'no puedo derivar el nombre de la base' <<<"$SAL" && ok "…y sigue hasta la comprobación siguiente" \
    || mal "no llegó a la comprobación siguiente: no prueba que pasara la guarda"

printf '\n\033[1;36m— init-project.sh: el escape, y el parseo —\033[0m\n'
SAL="$(corre_init "$BASE/principal" --en-el-principal)"
grep -qF 'checkout PRINCIPAL, y generar' <<<"$SAL" && mal "sigue rechazando con el flag" || ok "el flag deja pasar"
grep -qF 'en el checkout PRINCIPAL con --en-el-principal' <<<"$SAL" && ok "…y AVISA" || mal "el escape es silencioso"
SAL="$(corre_init "$BASE/principal" --en-el-princiapl)"; RC=$?
[ "$RC" -ne 0 ] && ok "un typo del escape FALLA (rc $RC) en vez de ignorarse" || mal "un typo se ignora: el rechazo se saltaría solo"

printf '\n\033[1;36m— up.sh: la MISMA guarda, en la puerta del CONTENEDOR —\033[0m\n'
# Es la puerta que más importa: lo que levanta es un contenedor que autoprovisiona.
UP="$T/bin/up.sh"
corre_up() { FS_PROJECT_ROOT="$1" NO_COLOR=1 "$UP" "${@:2}" 2>&1; }
SAL="$(corre_up "$BASE/principal")"; RC=$?
[ "$RC" -ne 0 ] && ok "en el principal falla (rc $RC)" || mal "levanta en el principal"
grep -qF 'checkout PRINCIPAL' <<<"$SAL" && ok "dice qué pasa" || mal "mensaje mudo"
grep -qF 'okoworktree add' <<<"$SAL" && ok "…y ofrece la salida" || mal "no dice qué hacer"
# Y que se niegue ANTES de tocar el motor: si hablara del compose es que siguió adelante.
grep -qF 'no se encuentra el fichero compose' <<<"$SAL" && mal "llegó a buscar el compose: la guarda va tarde" \
    || ok "…y se niega ANTES de tocar nada del motor"

printf '\n\033[1;36m— EL CONTROL NEGATIVO de up.sh: en un WORKTREE no se niega —\033[0m\n'
SAL="$(corre_up "$BASE/copia")"
grep -qF 'checkout PRINCIPAL' <<<"$SAL" && mal "para un worktree legítimo" || ok "deja pasar el worktree"
grep -qF 'no se encuentra el fichero compose' <<<"$SAL" && ok "…y sigue hasta la búsqueda del compose" \
    || mal "no llegó a buscar el compose: no prueba que pasara la guarda"
grep -qF "Raíz en la que he buscado: $BASE/copia" <<<"$SAL" && ok "…diciendo la RAÍZ en la que buscó" \
    || mal "no dice la raíz: un fallo de derivación se leería como falta de configuración"

printf '\n\033[1;36m— up.sh en una COPIA no crea el contenedor del ORIGINAL —\033[0m\n'
# El compose declara los container_name SIN sufijo: crearlo desde aquí levantaría el del original
# montando el árbol de la copia. Pasó, y dejó un huérfano ocupando el router del entorno principal.
mkdir -p "$BASE/copia/podman" && printf 'services:\n  t:\n    container_name: pega-test\n' > "$BASE/copia/podman/podman-compose.yaml"
SAL="$(TESTENV_CONTAINER=zz-no-existe-jamas corre_up "$BASE/copia")"; RC=$?
[ "$RC" -ne 0 ] && ok "no lo crea: falla (rc $RC)" || mal "crea el contenedor del original desde una copia"
grep -qF 'okoworktree up' <<<"$SAL" && ok "…y delega en quien sabe del overlay" || mal "no dice quién sí puede"
grep -qF 'del ORIGINAL' <<<"$SAL" && ok "…explicando por qué no lo hace él" || mal "no explica el riesgo"
rm -rf "$BASE/copia/podman"

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
