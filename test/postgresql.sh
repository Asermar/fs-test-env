#!/usr/bin/env bash
# =============================================================================
# Batería del motor POSTGRESQL: bin/pg-esquema.php, el que construye el esquema de cada escenario.
#
#   FS_TEST_PG_ENV=<TESTENV_DIR de PostgreSQL provisionado> test/postgresql.sh
#
# ## LO QUE COMPRUEBA, y por qué cada cosa
#
#   0. la provisión quita del bootstrap de phpunit-webrunner.xml (test-plugins.php) la línea que imprime
#      FS_DB_PASS, y deja una que sólo la usa; y si la batería se corta con el volcado dentro, lo restaura
#      (0b); y si no puede respaldarlo, no lo toca (0c).
#   1. CONTROL POSITIVO: sólo el core construye, con 0 FK tras la pasada 1 y más de 0 tras la 2.
#   2. LA GUARDA DEL TRUCO de las FK: si los scripts generados dejan de apagar las claves ajenas (es lo
#      que pasaría si el core dejara de mirar `db_foreign_keys` antes que FS_DB_FOREIGN_KEYS), la pasada
#      1 crea FK y pg-esquema tiene que decirlo con nombre. Se provoca neutralizando el interruptor.
#   3. NO INVENTA ROJOS: un plugin compatible (FS_TEST_PG_LIMPIO, def. Verifactu) sale limpio.
#   4. UN ROJO DICE DE DÓNDE VIENE: uno incompatible (FS_TEST_PG_ROTO, def. OpenServBus) sale con su
#      plugin, su tabla y el motivo del servidor.
#   5. PUNTO DE PARTIDA LIMPIO: tras un escenario roto, «sólo el core» vuelve a dar exactamente las
#      mismas tablas y FK, y ningún plugin activo.
#   7. UN INIT QUE FALLA SE ATRIBUYE A SU PLUGIN: un plugin de prueba (PruebaInitFalla, creado aquí y
#      borrado al terminar) cuyo Init lanza en PostgreSQL da ok:false con su nombre, no «esquema completo»;
#      y si en vez de lanzar sale con un código distinto de 0, también. Y su salida no estorba: si escribe
#      sin salto de línea antes de fallar, el FAIL se reconoce igual; si imprime un resumen falso del
#      warm-up, no suplanta al de verdad.
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

echo "== 0. la provisión quita del bootstrap del runner la línea que imprime FS_DB_PASS, y sólo ésa"
# phpunit-webrunner.xml carga Test/test-plugins.php, no Test/bootstrap.php: se le añaden un volcado de la
# clave con otra etiqueta y un uso de la constante que NO la imprime, y se reprovisiona de verdad, en el
# contenedor. El volcado tiene que irse y el otro uso quedarse (borrarlo rompería el bootstrap).
#
# EL CERROJO: se toma antes de tocar test-plugins.php, para que ninguna ejecución arranque con el volcado
# dentro. Pero la provisión lo toma ella misma con flock -n y se NIEGA si está tomado, así que se suelta
# justo antes de lanzarla: queda la ventana que tarda podman exec en llegar a su flock. Y si en esa ventana
# arrancara una ejecución, el runner redacta la clave de su salida igual. El respaldo se restaura desde
# un trap, también si la batería se corta.
TP="$D/Test/test-plugins.php"; TP_RESPALDO="$(mktemp)"
exec 8>"$(dirname "$D")/.webrunner.lock"
flock -w 300 8 || no_comprobado "el entorno está en uso (cerrojo ocupado más de 300 s)."
# El respaldo se hace ANTES de armar el trap, y si falla se para: si no, el trap restauraría un respaldo
# vacío encima de test-plugins.php.
cp "$TP" "$TP_RESPALDO" || no_comprobado "no pude respaldar $TP; no lo toco."
trap 'cp "$TP_RESPALDO" "$TP"; rm -f "$TP_RESPALDO"' EXIT
printf '%s\n' "echo \"\\n\" . 'Clave: ' . FS_DB_PASS;" "\$usaClaveSinImprimir = strlen(FS_DB_PASS);" >> "$TP"
flock -u 8; exec 8>&-
podman exec -i -w "$RAIZ" -e FS_PROJECT_ROOT="$RAIZ" -e NO_COLOR=1 "$CONT" \
    "$ARNES/bin/test-env-provision.sh" --motor postgresql >/dev/null 2>&1; rc_prov=$?
if [ "$rc_prov" = 0 ] && ! grep -q "'Clave: '" "$TP" && grep -qxF '$usaClaveSinImprimir = strlen(FS_DB_PASS);' "$TP" \
   && [ "$(grep -vxF '$usaClaveSinImprimir = strlen(FS_DB_PASS);' "$TP" | cmp - "$TP_RESPALDO" >/dev/null && echo igual)" = igual ]; then
    ok "reprovisionar quita la línea que imprime la clave, deja la que sólo la usa, y nada más cambia"
else
    mal "tras reprovisionar (rc $rc_prov), test-plugins.php no quedó como debía (volcado dentro, uso borrado o más cambios)"
fi
cp "$TP_RESPALDO" "$TP"; rm -f "$TP_RESPALDO"; trap - EXIT

echo "== 0b. si la batería se corta con el volcado ya inyectado, test-plugins.php vuelve a estar como antes"
# Una copia de esta batería (en un mktemp, con su ARNES fijado) que muere por SIGTERM justo tras inyectar.
# Antes de ejecutarla se comprueba que el corte está: si no, sería la batería entera.
# cortada <destino> [<respaldo>]: esa copia; con <respaldo>, el suyo es ése en vez de un mktemp. Sale 1 si
# no pudo hacer los cambios: entonces la copia sería la batería entera y no mediría nada.
cortada() {
    local tp_linea='TP="$D/Test/test-plugins.php"; TP_RESPALDO="$(mktemp)"'
    L='printf '"'"'%s\n'"'"' "echo \"\\n\" . '"'"'Clave: '"'"' . FS_DB_PASS;" "\$usaClaveSinImprimir = strlen(FS_DB_PASS);" >> "$TP"' \
    A="$ARNES" T="$tp_linea" R="${2:-}" awk '$0 == ENVIRON["L"] { print; print "kill -TERM $$"; next }
        ENVIRON["R"] != "" && $0 == ENVIRON["T"] { print "TP=\"$D/Test/test-plugins.php\"; TP_RESPALDO=\047" ENVIRON["R"] "\047"; next }
        /^ARNES=/ && !h { print "ARNES=\047" ENVIRON["A"] "\047"; h = 1; next } { print }' "${BASH_SOURCE[0]}" > "$1"
    grep -qxF 'kill -TERM $$' "$1" && grep -qxF "ARNES='$ARNES'" "$1" \
        && { [ -z "${2:-}" ] || grep -qxF "TP=\"\$D/Test/test-plugins.php\"; TP_RESPALDO='$2'" "$1"; }
}
TP_ANTES="$(mktemp)"; cp "$TP" "$TP_ANTES"; corte="$(mktemp)"
if cortada "$corte"; then
    bash "$corte" >/dev/null 2>&1; rc_corte=$?
else
    rc_corte=no-cortada
fi
rm -f "$corte"
if [ "$rc_corte" = 143 ] && cmp -s "$TP" "$TP_ANTES"; then
    ok "cortada tras inyectar (rc 143), el trap deja test-plugins.php como estaba"
else
    mal "una pasada cortada no restauró test-plugins.php o no midió (copia rc=$rc_corte)"
    cp "$TP_ANTES" "$TP"
fi

echo "== 0c. si el respaldo falla, se para sin tocar test-plugins.php"
# La copia usa como respaldo un fichero vacío de sólo lectura: el cp falla. Tiene que salir con 2 (NO
# COMPROBADO) y dejar test-plugins.php igual; si armara el trap antes, lo pisaría con el respaldo vacío.
cp "$TP" "$TP_ANTES"; corte="$(mktemp)"; ro="$(mktemp)"; chmod 444 "$ro"
if cortada "$corte" "$ro"; then
    bash "$corte" >/dev/null 2>&1; rc_corte=$?
else
    rc_corte=no-cortada
fi
rm -f "$corte" "$ro"
if [ "$rc_corte" = 2 ] && cmp -s "$TP" "$TP_ANTES"; then
    ok "con el respaldo imposible sale con 2 y test-plugins.php sigue igual"
else
    mal "con el respaldo imposible no paró o tocó test-plugins.php (copia rc=$rc_corte)"
    cp "$TP_ANTES" "$TP"
fi
rm -f "$TP_ANTES"

# El mismo cerrojo que el runner y la provisión: esto reescribe el esquema del entorno.
exec 9>"$(dirname "$D")/.webrunner.lock"
flock -w 300 9 || no_comprobado "el entorno está en uso (cerrojo ocupado más de 300 s)."

LISTA="$D/Test/Plugins/install-plugins.txt"
RESPALDO="$(mktemp -d)"
cp "$D/warmup-schema.php" "$D/Test/install-plugins.php" "$RESPALDO/"
PRUEBA="$D/Plugins/PruebaInitFalla"
recoger() {
    rm -rf -- "$PRUEBA"
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

echo "== 2b. scripts generados pisados por los del core: lo dice, no culpa al core"
# Lo que pasaba tras un `okoworktree up` que volvía a montar el andamiaje: install-plugins.php sin el
# interruptor. Se simula quitándole las líneas de FS_TEST_SIN_FK.
grep -v FS_TEST_SIN_FK "$RESPALDO/install-plugins.php" > "$D/Test/install-plugins.php"
corre ''
if [ "$(campo ok)" = false ] && printf '%s' "$(campo error)" | grep -q "le falta FS_TEST_SIN_FK" \
   && ! printf '%s' "$J" | grep -q "ya no respeta"; then
    ok "sin el interruptor en los scripts: pide reprovisionar, no culpa al core"
else
    mal "sin el interruptor en los scripts debía pedir reprovisionar: $J"
fi
cp "$RESPALDO/install-plugins.php" "$D/Test/install-plugins.php"

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

echo "== 7. un Init que falla en PostgreSQL se atribuye a su plugin"
mkdir -p "$PRUEBA"
cat > "$PRUEBA/facturascripts.ini" <<'INI'
name = 'PruebaInitFalla'
description = 'Plugin de prueba de test/postgresql.sh: su Init falla en PostgreSQL. Se borra al terminar.'
version = 1
min_version = 2025
INI
cat > "$PRUEBA/Init.php" <<'PHP'
<?php
namespace FacturaScripts\Plugins\PruebaInitFalla;

class Init extends \FacturaScripts\Core\Template\InitClass
{
    public function init(): void
    {
        if (strtolower((string) FS_DB_TYPE) !== 'postgresql') {
            return;
        }
        if (getenv('PRUEBA_INIT_MODO') === 'sale') {
            exit(7);
        }
        if (getenv('PRUEBA_INIT_MODO') === 'imprime') {
            echo "   Tablas verificadas/creadas. OK=7 FAIL=3\n";
            return;
        }
        if (getenv('PRUEBA_INIT_MODO') === 'pega') {
            echo 'salida del plugin sin salto de linea';
        }
        throw new \RuntimeException('fallo de prueba del Init en PostgreSQL');
    }

    public function update(): void
    {
    }

    public function uninstall(): void
    {
    }
}
PHP
corre PruebaInitFalla
lanza="$(printf '%s' "$J" | php -r '$d = json_decode(stream_get_contents(STDIN), true); $n = 0; foreach ($d["errores"] ?? [] as $e) { if ($e["plugin"] === "PruebaInitFalla" && strpos($e["motivo"], "fallo de prueba del Init") !== false) { $n++; } } echo $n;')"
if [ "$(campo ok)" = false ] && [ "${lanza:-0}" -gt 0 ]; then
    ok "el Init que lanza: ok:false, atribuido a PruebaInitFalla con su motivo"
else
    mal "el Init que lanza no se atribuye (o sale «esquema completo»): $J"
fi
corre PruebaInitFalla PRUEBA_INIT_MODO=sale
if [ "$(campo ok)" = false ] && printf '%s' "$(campo errores)" | grep -q "salió con 7"; then
    ok "el warm-up que sale con 7: ok:false, «salió con 7»"
else
    mal "un warm-up que sale con 7 no se cuenta como error: $J"
fi
corre PruebaInitFalla PRUEBA_INIT_MODO=pega
pegado="$(printf '%s' "$J" | php -r '$d = json_decode(stream_get_contents(STDIN), true); $n = 0; foreach ($d["errores"] ?? [] as $e) { if ($e["plugin"] === "PruebaInitFalla" && strpos($e["motivo"], "fallo de prueba del Init") !== false) { $n++; } } echo $n;')"
if [ "$(campo ok)" = false ] && [ "${pegado:-0}" -gt 0 ]; then
    ok "un Init que escribe sin salto de línea y lanza: el FAIL no se le pega, y se atribuye"
else
    mal "con salida sin salto delante, el FAIL no se reconoce: $J"
fi
corre PruebaInitFalla PRUEBA_INIT_MODO=imprime
if [ "$(campo ok)" = true ] && [ "$(campo errores)" = '[]' ]; then
    ok "un plugin que imprime un resumen falso «OK=7 FAIL=3» no lo suplanta: se lee el del warm-up"
else
    mal "un resumen falso impreso por un plugin suplanta al del warm-up: $J"
fi
rm -rf -- "$PRUEBA"

echo
if [ "$FALLOS" -gt 0 ]; then
    printf '%s comprobaciones, \033[1;31m%s en rojo\033[0m.\n' "$((OK+FALLOS))" "$FALLOS"
    exit 1
fi
printf '%s comprobaciones, todas en verde' "$OK"
[ "$SIN" -gt 0 ] && printf ' (y %s sin comprobar, dicho arriba)' "$SIN"
printf '.\n'
