#!/usr/bin/env bash
# =============================================================================
# Batería del motor POSTGRESQL: bin/pg-esquema.php, el que construye el esquema de cada escenario.
#
#   FS_TEST_PG_ENV=<TESTENV_DIR de PostgreSQL provisionado> test/postgresql.sh
#
# ## LO QUE COMPRUEBA, y por qué cada cosa
#
#   1. CONTROL POSITIVO: sólo el core construye, con 0 FK tras la pasada 1 y más de 0 tras la 2.
#   2. LA GUARDA DEL TRUCO de las FK: si los scripts generados dejan de apagar las claves ajenas (es lo
#      que pasaría si el core dejara de mirar `db_foreign_keys` antes que FS_DB_FOREIGN_KEYS), la pasada
#      1 crea FK y pg-esquema tiene que decirlo con nombre. Se provoca neutralizando el interruptor.
#   3. NO INVENTA ROJOS: un plugin compatible (FS_TEST_PG_LIMPIO, def. Verifactu) sale limpio.
#   4. UN ROJO DICE DE DÓNDE VIENE: uno incompatible (FS_TEST_PG_ROTO, def. OpenServBus) sale con su
#      plugin, su tabla y el motivo del servidor.
#   5. PUNTO DE PARTIDA LIMPIO: tras un escenario roto, «sólo el core» vuelve a dar exactamente las
#      mismas tablas y FK, y ningún plugin activo.
#   6. EL NEGATIVO DEL AISLAMIENTO en sus tres estados: aislado, no se pudo comprobar (centinela que no
#      existe) y no aislado (CONNECT concedido a propósito, y retirado al terminar).
#
# ## NO ES AUTOCONTENIDA, a diferencia de las otras
#
# Necesita el PostgreSQL de test (fstest-pg) y un entorno de PostgreSQL provisionado con su core: no hay
# forma de comprobar el esquema real sin ellos. Si falta algo, sale con 2 diciendo «NO COMPROBADO», que
# no es un verde. Toma el mismo cerrojo que el runner, y deja el entorno en «sólo el core».
#
# pg-esquema.php se ejecuta DENTRO del contenedor de test de la copia, que es donde lo ejecuta el
# runner: medido, el PHP del host no tiene `soap` y Verifactu (require_php = soap) no se activaría ahí,
# así que la misma orden desde el host daría un rojo que el runner nunca da.
# =============================================================================
set -uo pipefail

ARNES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ESQUEMA="$ARNES/bin/pg-esquema.php"
D="${FS_TEST_PG_ENV:-}"
LIMPIO="${FS_TEST_PG_LIMPIO:-Verifactu}"
ROTO="${FS_TEST_PG_ROTO:-OpenServBus}"

OK=0 FALLOS=0 SIN=0
ok()  { OK=$((OK+1));         printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
mal() { FALLOS=$((FALLOS+1)); printf '  \033[1;31m✗\033[0m %s\n' "$*"; }
sin() { SIN=$((SIN+1));       printf '  \033[1;33m?\033[0m %s\n' "$*"; }
no_comprobado() { echo "NO COMPROBADO: $*" >&2; exit 2; }

[ -n "$D" ] || no_comprobado "define FS_TEST_PG_ENV con el TESTENV_DIR de PostgreSQL de una copia."
[ -f "$D/config.php" ] && grep -q "'FS_DB_TYPE', 'postgresql'" "$D/config.php" \
    || no_comprobado "'$D' no es un entorno de PostgreSQL provisionado."
php -m | grep -qx pgsql || no_comprobado "este PHP no tiene pgsql."
podman container exists fstest-pg || no_comprobado "no existe fstest-pg (bin/pg-up.sh)."
ROL="$(php -r "require '$D/config.php'; echo FS_DB_USER;")"
RAIZ="$(cd "$D/../.." && pwd)"
CONT="$(sed -n 's/^TESTENV_CONTAINER="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$RAIZ/.fs-test-env.env" 2>/dev/null | tail -1)"
[ -n "$CONT" ] && podman container exists "$CONT" || no_comprobado "no encuentro el contenedor de test de '$RAIZ' (TESTENV_CONTAINER)."
podman exec "$CONT" test -f "$ESQUEMA" || no_comprobado "el contenedor '$CONT' no monta este arnés ($ARNES): probaría otro código."


# El mismo cerrojo que el runner y la provisión: esto reescribe el esquema del entorno.
exec 9>"$(dirname "$D")/.webrunner.lock"
flock -w 300 9 || no_comprobado "el entorno está en uso (cerrojo ocupado más de 300 s)."

LISTA="$D/Test/Plugins/install-plugins.txt"
RESPALDO="$(mktemp -d)"
cp "$D/warmup-schema.php" "$D/Test/install-plugins.php" "$RESPALDO/"
recoger() {
    cp "$RESPALDO/warmup-schema.php" "$D/warmup-schema.php"
    cp "$RESPALDO/install-plugins.php" "$D/Test/install-plugins.php"
    rm -rf -- "$RESPALDO"
    podman exec fstest-pg psql -U postgres -qc "REVOKE CONNECT ON DATABASE fstest_centinela FROM \"$ROL\"" >/dev/null 2>&1 || true
    : > "$LISTA"; podman exec -w "$D" "$CONT" php "$ESQUEMA" "$D" >/dev/null 2>&1 || true
}
trap recoger EXIT

# corre <lista> [VAR=valor…]: lanza pg-esquema --json con ese escenario y deja el JSON en $J.
corre() {
    printf '%s' "$1" > "$LISTA"; shift
    local e=() v
    for v in "$@"; do e+=(-e "$v"); done
    J="$(podman exec -w "$D" "${e[@]}" "$CONT" php "$ESQUEMA" "$D" --json 2>/dev/null | tail -1)"
}
campo() { printf '%s' "$J" | php -r '$d = json_decode(stream_get_contents(STDIN), true); $v = $d; foreach (explode(".", $argv[1]) as $k) { $v = is_array($v) ? ($v[$k] ?? null) : null; } echo is_bool($v) ? ($v ? "true" : "false") : (is_array($v) ? json_encode($v, JSON_UNESCAPED_UNICODE) : (string) $v);' "$1"; }

echo "== 1. control positivo: sólo el core"
corre ''
TABLAS_CORE="$(campo tablas)"; FK_CORE="$(campo fk)"
if [ "$(campo ok)" = true ] && [ "$(campo guarda.fk_tras_pasada_1)" = 0 ] && [ "${FK_CORE:-0}" -gt 0 ]; then
    ok "sólo el core: $TABLAS_CORE tablas, $FK_CORE FK; 0 FK tras la pasada sin ellas"
else
    mal "sólo el core no construye como debe: $J"
fi

echo "== 2. la guarda de las FK, con el interruptor neutralizado"
sed -i "s/define('db_foreign_keys', false);/\/* neutralizado por test\/postgresql.sh *\//" "$D/warmup-schema.php" "$D/Test/install-plugins.php"
corre ''
if [ "$(campo ok)" = false ] && printf '%s' "$(campo guarda.error)" | grep -q "ya no respeta"; then
    ok "sin el interruptor, la guarda lo dice: $(campo guarda.fk_tras_pasada_1) FK tras la pasada 1"
else
    mal "la guarda no saltó con el interruptor neutralizado: $J"
fi
cp "$RESPALDO/warmup-schema.php" "$D/warmup-schema.php"; cp "$RESPALDO/install-plugins.php" "$D/Test/install-plugins.php"

echo "== 3. no inventa rojos: $LIMPIO solo"
if [ -d "$D/Plugins/$LIMPIO" ]; then
    corre "$LIMPIO"
    if [ "$(campo ok)" = true ] && [ "$(campo errores)" = '[]' ]; then
        ok "$LIMPIO solo sale limpio: $(campo tablas) tablas, $(campo fk) FK"
    else
        mal "$LIMPIO solo da rojo: $(campo errores)"
    fi
else
    sin "no comprobado: este entorno no tiene el plugin $LIMPIO (FS_TEST_PG_LIMPIO)"
fi

echo "== 4. un rojo dice de dónde viene: $ROTO solo"
if [ -d "$D/Plugins/$ROTO" ]; then
    corre "$ROTO"
    atribuidos="$(printf '%s' "$J" | php -r '$d = json_decode(stream_get_contents(STDIN), true); $n = 0; foreach ($d["errores"] ?? [] as $e) { if ($e["plugin"] === $argv[1] && $e["tabla"] !== "" && strpos($e["motivo"], "servidor:") !== false) { $n++; } } echo $n;' "$ROTO")"
    if [ "$(campo ok)" = false ] && [ "${atribuidos:-0}" -gt 0 ]; then
        ok "$ROTO solo: rojo con plugin, tabla y motivo del servidor en $atribuidos error(es)"
    else
        mal "$ROTO solo: el rojo no se atribuye: $(campo errores)"
    fi
else
    sin "no comprobado: este entorno no tiene el plugin $ROTO (FS_TEST_PG_ROTO)"
fi

echo "== 5. punto de partida limpio tras un escenario roto"
# Y en el DISCO: MyFiles/ y Dinamic/ tienen que ser los del escenario, no restos del anterior. El core
# regenera Dinamic y la sincronización reescribe plugins.json, así que eso no se ve en las tablas: se
# deja un resto marcado en cada uno y tiene que desaparecer.
touch "$D/MyFiles/.resto-de-otro-escenario" "$D/Dinamic/.resto-de-otro-escenario" 2>/dev/null
corre ''
restos=0
for f in "$D/MyFiles/.resto-de-otro-escenario" "$D/Dinamic/.resto-de-otro-escenario"; do
    [ -e "$f" ] && restos=$((restos+1))
done
activos="$(php -r '$f = $argv[1] . "/MyFiles/plugins.json"; $p = is_file($f) ? json_decode((string) file_get_contents($f), true) : []; echo count(array_filter((array) $p, fn ($x) => !empty($x["enabled"])));' "$D")"
if [ "$(campo tablas)" = "$TABLAS_CORE" ] && [ "$(campo fk)" = "$FK_CORE" ] && [ "$activos" = 0 ] && [ "$restos" = 0 ]; then
    ok "vuelve a $TABLAS_CORE tablas y $FK_CORE FK, sin plugins activos ni restos en MyFiles/ y Dinamic/"
else
    mal "no vuelve a «sólo el core»: $(campo tablas) tablas (esperadas $TABLAS_CORE), $(campo fk) FK (esperadas $FK_CORE), $activos plugin(s) activo(s), $restos resto(s) en el disco"
fi

echo "== 6. el negativo del aislamiento"
corre ''
[ "$(campo aislamiento)" = aislado ] && ok "aislado: el rol no conecta a la centinela" || mal "debía decir aislado: $J"
corre '' TESTENV_PG_CENTINELA="fstest_no_existe_$$"
if [ "$(campo ok)" = false ] && printf '%s' "$(campo aislamiento)" | grep -q "^no se pudo comprobar"; then
    ok "sin centinela: «no se pudo comprobar», y no construye"
else
    mal "sin centinela debía decir «no se pudo comprobar»: $J"
fi
podman exec fstest-pg psql -U postgres -qc "GRANT CONNECT ON DATABASE fstest_centinela TO \"$ROL\"" >/dev/null
corre ''
if [ "$(campo ok)" = false ] && printf '%s' "$(campo aislamiento)" | grep -q "^no aislado"; then
    ok "con CONNECT a la centinela: «no aislado», y no construye"
else
    mal "con CONNECT a la centinela debía decir «no aislado»: $J"
fi
podman exec fstest-pg psql -U postgres -qc "REVOKE CONNECT ON DATABASE fstest_centinela FROM \"$ROL\"" >/dev/null

echo
if [ "$FALLOS" -gt 0 ]; then
    printf '%s comprobaciones, \033[1;31m%s en rojo\033[0m.\n' "$((OK+FALLOS))" "$FALLOS"
    exit 1
fi
printf '%s comprobaciones, todas en verde' "$OK"
[ "$SIN" -gt 0 ] && printf ' (y %s sin comprobar, dicho arriba)' "$SIN"
printf '.\n'
