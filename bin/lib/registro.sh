#!/bin/bash
# =============================================================================
# El registro de instalaciones del arnés: de dónde sale cada valor.
#
# NO es ejecutable: se usa con `source`.
#
# ## POR QUÉ EXISTE
#
# `.fs-test-env.env` estaba **versionado en el repo de cada cliente** con rutas
# absolutas de una máquina dentro. Dos consecuencias, y la segunda es la cara:
#
#   - es la trampa que el `CLAUDE.md` global documenta de la mudanza de `~/Dev`:
#     un fichero por entorno versionado apunta a rutas que dejan de existir;
#   - y `okoworktree` tenía que **reescribirlo** al hacer una copia para que la
#     copia no acabara escribiendo en la base de test del original. O sea que el
#     aislamiento funcionaba por PARCHE. Con un `git worktree` a pelo, sin
#     `okoworktree`, la copia escribe en la base del original **en silencio**.
#
# Aquí el aislamiento pasa a ser una propiedad del diseño: `TEST_DB` se **deriva**
# de `FS_DB_NAME` de la propia instalación, así que una copia con su base ya tiene
# su base de test sin que nadie reescriba nada.
#
# ## LAS TRES CLASES, y de dónde sale cada una
#
#   (A) DE LA MÁQUINA, no inferible  → `~/.config/tooling/fs-test_maquina.conf`
#       `TESTENV_REPO_PATH`, `TESTENV_DIR`, `FS_TEST_DIR`, `TESTENV_RUN_USER`.
#       Rutas absolutas de UN equipo: no van a ningún repo.
#   (B) DERIVABLE de lo ya versionado → se calcula, no se guarda
#       `TEST_DB` de `src/config.php`; contenedor, host, router, URL y nombres de
#       servicio, del compose. Guardarlos sería una segunda verdad.
#   (C) DEL PRODUCTO                 → `config/instalaciones.conf`, versionado
#
# ## EL ID ES DE INSTALACIÓN, NO DE MÁQUINA
#
# Un worktree es una instalación más: `mesa-fs` y `mesa-fs-wt-rutas` conviven en
# el mismo equipo y necesitan bases distintas. Por eso el índice no puede ser el
# hostname. El id se deriva de la ruta bajo la raíz de repos.
# =============================================================================

REGISTRO_DIR="${REGISTRO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
REGISTRO_CONF="${REGISTRO_CONF:-$REGISTRO_DIR/config/instalaciones.conf}"
# Convención de la casa para lo que una herramienta deja fuera del repo:
# `${XDG_CONFIG_HOME:-~/.config}/tooling/<tool>_<cosa>`.
REGISTRO_MAQUINA="${REGISTRO_MAQUINA:-${XDG_CONFIG_HOME:-$HOME/.config}/tooling/fs-test_maquina.conf}"
REGISTRO_DEV_ROOT="${REGISTRO_DEV_ROOT:-$HOME/Dev}"

# --- el id de una instalación -----------------------------------------------
# `~/Dev/Mesa/FS` → `mesa-fs` · `~/Dev/Mesa/FS-wt-rutas` → `mesa-fs-wt-rutas`.
# Fuera de la raíz de repos cae al basename, que sigue siendo estable.
registro_id_de() {
    local raiz="${1:?falta la raíz del proyecto}" rel
    [ -n "${FS_TEST_ID:-}" ] && { printf '%s\n' "$FS_TEST_ID"; return 0; }
    raiz="$(cd "$raiz" 2>/dev/null && pwd)" || return 1
    case "$raiz/" in
        "$REGISTRO_DEV_ROOT"/*) rel="${raiz#"$REGISTRO_DEV_ROOT"/}" ;;
        *) rel="$(basename "$raiz")" ;;
    esac
    printf '%s\n' "$rel" | tr 'A-Z/_' 'a-z--' | tr -cd 'a-z0-9-\n'
}

# --- leer un fichero de bloques `[id]` --------------------------------------
# clave del bloque pedido, o vacío. Es el formato del precedente
# (`fs-remote-mcp/scripts/despliegues.conf`): `clave = valor`, alineado o no.
registro_lee() {  # registro_lee <fichero> <id> <clave>
    local f="$1" id="$2" clave="$3"
    [ -f "$f" ] || return 0
    awk -v id="[$id]" -v k="$clave" '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*\[/ { dentro = ($0 ~ "^[[:space:]]*\\" id "[[:space:]]*$"); next }
        dentro && $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
            sub("^[[:space:]]*" k "[[:space:]]*=[[:space:]]*", "")
            sub("[[:space:]]+$", "")
            print; exit
        }' "$f"
}

registro_ids() {  # todos los ids declarados en un fichero
    local f="$1"
    [ -f "$f" ] || return 0
    sed -n 's/^[[:space:]]*\[\([^]]*\)\][[:space:]]*$/\1/p' "$f"
}

registro_existe() { [ -n "$(registro_lee "$1" "$2" descripcion)$(registro_lee "$1" "$2" core_repo)" ]; }

# --- UNA COPIA HEREDA LA CONFIGURACIÓN DE PRODUCTO DE SU INSTALACIÓN PADRE ---------------------
#
# Desde que el entorno de test deja de vivir en el checkout principal, el consumidor normal de este
# registro es una COPIA: `okoworktree` crea `<repo>-wt-<nombre>` y provisiona ahí. Sin herencia, esa
# copia no tiene bloque, se toma por instalación nueva y el generador cae en el camino interactivo —
# nueve preguntas— que es inservible desde un `okoworktree add`, que es no interactivo por diseño.
#
# HEREDA SOLO LA CLASE (C), la del producto. Las rutas absolutas son (A) y siguen viniendo del
# fichero de máquina: heredar una ruta sería devolver el defecto que este registro vino a quitar —
# una copia apuntando al árbol del original. Y lo derivable (B) se sigue derivando de la propia
# copia, que es lo que le da SU base de datos.
#
# EL CORTE ES POR EL PRIMER `-wt-`, y el caso que lo decide es el worktree ANIDADO. `okoworktree`
# nombra la copia `<repo>-wt-<nombre>` y el `<nombre>` lo elige quien la crea, así que una copia de
# una copia es `mesa-fs-wt-a-wt-b`. Por el primero da `mesa-fs`, que SÍ está registrada; por el
# último daría `mesa-fs-wt-a`, que no lo está —las copias no se dan de alta— y haría falta recursión
# para llegar al mismo sitio. El primero acierta en los dos niveles sin nada más.
registro_padre_de() {  # <id> → el id base, o vacío si no es una copia
    local id="$1"
    case "$id" in *-wt-*) printf '%s\n' "${id%%-wt-*}" ;; *) return 1 ;; esac
}

# El id del que hay que leer la clase (C): el propio, si tiene bloque; si no y es una copia cuyo
# PADRE sí lo tiene, el del padre. Si no, nada — y entonces es una instalación nueva de verdad.
#
# Se niega a inventarse un padre: una copia cuyo `<base>` no está registrado se trata como NUEVA. Un
# fallback que coge el padre equivocado es peor que preguntar.
registro_origen_de() {  # <fichero> <id> → id del que leer (C), o vacío
    local f="$1" id="$2" padre
    registro_existe "$f" "$id" && { printf '%s\n' "$id"; return 0; }
    padre="$(registro_padre_de "$id")" || return 1
    registro_existe "$f" "$padre" && { printf '%s\n' "$padre"; return 0; }
    return 1
}

# --- (B) derivar de lo que ya está versionado --------------------------------
# La base de trabajo la dice `src/config.php`, que es el único sitio donde vive.
registro_db_trabajo() {  # <raíz> <FS_CORE_DIR>
    local raiz="$1" coredir="${2:-src}" cfg="$1/${2:-src}/config.php"
    [ -f "$cfg" ] || return 0
    php -r "require '$cfg'; echo defined('FS_DB_NAME') ? FS_DB_NAME : '';" 2>/dev/null
}

# `<base de trabajo>_test`. Derivarla es lo que aísla un worktree SIN parche:
# la copia tiene su propia `FS_DB_NAME`, así que tiene su propia base de test.
registro_db_test() { local w; w="$(registro_db_trabajo "$@")"; [ -n "$w" ] && printf '%s_test\n' "$w"; }

# Del compose: el servicio de test es el que tiene un `container_name` acabado en
# `-test`; de su etiqueta de traefik salen el router y el host.
#
# ## EL SEGUNDO ARGUMENTO ES LA IDENTIDAD DE LA COPIA, y su ausencia era un defecto
#
# El compose de un cliente declara sus nombres con el sufijo del stack DENTRO
# (`lcp-fs${STACK_SUFFIX:-}-test`), porque es la única forma de que una copia levante contenedores
# con nombre propio: `podman-compose` interpola valores, así que ahí sí entra.
#
# Aquí se **BORRABA** esa interpolación en vez de sustituirla, con el comentario «es de la copia»
# como si eso lo resolviera alguien. No lo resolvía nadie: en una copia salían los nombres del
# ORIGINAL. Medido el 30-ago-2026 sobre una copia real de un cliente — contenedor, host, URL y
# router, los cuatro del árbol original.
#
# Y NO CAUSABA DAÑO POR UNA RAZÓN QUE NO ES UNA SALVAGUARDA: `okoworktree` reescribe esos cuatro
# valores justo después de llamar a este generador. O sea que el aislamiento dependía del **orden de
# llamada**, no de la herramienta que escribe el fichero. Quien siguiera a mano el mensaje de un
# fallo —que es lo que el arnés invita a hacer— y provisionara a continuación, provisionaba contra el
# entorno de pruebas del ORIGINAL.
#
# EL SUFIJO SE RECIBE, NO SE DERIVA AQUÍ. Lo deriva quien llama, con `ancla_es_worktree` y
# `ancla_sufijo_copia` de `lib/ancla.sh`, que es la señal que la casa ya eligió y tiene su porqué
# escrito. Así este fichero no gana una dependencia de esa librería y el test puede pedirle las dos
# respuestas —con sufijo y sin él— sin montar un worktree para cada una.
#
# EL GUION VA DENTRO DEL VALOR, igual que en `STACK_SUFFIX`: el compose escribe
# `lcp-fs${STACK_SUFFIX:-}-test`, así que lo que se sustituye es `-<sufijo>` y no `<sufijo>`. Es la
# misma convención que `Scripts/lib/okoworktree/kinds/facturascripts.sh` declara al generar el `.env`
# de la copia, y desviarse de ella daría un nombre que no existe en ningún sitio.
#
# VACÍO = COMO ANTES, byte a byte: fuera de una copia no hay sufijo que poner, y borrar la
# interpolación es entonces la respuesta correcta.
registro_compose() {  # <raíz> [<valor de STACK_SUFFIX>] → imprime CLAVE=valor de lo derivable
    local raiz="$1" suf="${2:-}" c
    c="$(find "$raiz" -maxdepth 3 \( -name 'podman-compose*.y*ml' -o -name 'docker-compose*.y*ml' \) -print -quit 2>/dev/null)"
    [ -n "$c" ] || return 0
    awk -v suf="$suf" '
        # Un `&` en el reemplazo de `sub`/`gsub` significa «lo que casó», así que un sufijo con `&`
        # insertaría el nombre entero. Se neutraliza una vez, aquí, y no en los tres usos de abajo.
        BEGIN { gsub(/&/, "\\&", suf) }
        /^  [a-zA-Z0-9_-]+:[[:space:]]*$/ { svc = $1; sub(":", "", svc) }
        /container_name:/ {
            nombre = $2
            gsub(/\$\{[^}]*\}/, suf, nombre)         # la identidad de ESTA copia, no la del ancla
            if (nombre ~ /-test$/) { print "TESTENV_SERVICE=" svc; print "TESTENV_CONTAINER=" nombre }
            if (nombre ~ /-db$/)   { print "TESTENV_DB_SERVICE=" svc }
        }
        /routers\.[a-zA-Z0-9_-]+-test\.rule=Host\(/ {
            if (!visto_router) {
                r = $0; sub(/^.*routers\./, "", r); sub(/\.rule.*$/, "", r)
                # EL ROUTER NO SE ARREGLA POR INTERPOLACIÓN, y hay que decir por qué: su nombre es la
                # CLAVE de la etiqueta, y `podman-compose` 1.0.6 interpola valores y `container_name`
                # pero NUNCA claves. Así que en el compose es literal —`propkey-test`— y la
                # sustitución de arriba no lo alcanza: se sufija aparte.
                #
                # Y hace falta, no es simetría: dos copias que declaren el mismo router se anulan
                # MUTUAMENTE en traefik y de paso tumban al original, que es la primera trampa que el
                # `CLAUDE.md` global tiene escrita sobre dos copias del mismo stack.
                #
                # A una copia enrutada por `okoworktree` la sirve su file provider, con un nombre que
                # okoworktree elige; esto gobierna el `service.yaml` que se renderiza aquí, que es lo
                # que pega quien monta el servicio a mano.
                if (suf != "") sub(/-test$/, suf "-test", r)
                print "TESTENV_TRAEFIK_ROUTER=" r
                h = $0; sub(/^.*Host\(`/, "", h); sub(/`.*$/, "", h); gsub(/\$\{[^}]*\}/, suf, h)
                print "TESTENV_HOST=" h; print "TEST_WEB_URL=https://" h
                visto_router = 1
            }
        }' "$c"
}

# --- LA GUARDA, y son DOS comprobaciones porque una sola no basta ------------
# La del provisionador («TEST_DB no puede ser la de trabajo») ya existía y se
# reusa. Pero lo aprendido el 26-ago-2026 es que **no protege del caso caro**:
# apuntar a la base de test del ORIGINAL, que es otra base y pasa la primera.
# Por eso la segunda: que no coincida con la de otra instalación registrada.
registro_guarda_db() {  # <raíz> <id> <test_db> <FS_CORE_DIR> → 0 si es seguro
    local raiz="$1" id="$2" test_db="$3" coredir="${4:-src}" trabajo otro otra_raiz otra_db
    [ -n "$test_db" ] || { echo "ERROR: TEST_DB vacía; no se escribe nada." >&2; return 1; }
    trabajo="$(registro_db_trabajo "$raiz" "$coredir")"
    if [ -n "$trabajo" ] && [ "$test_db" = "$trabajo" ]; then
        echo "ERROR: la BD de pruebas no puede ser la de trabajo ('$trabajo')." >&2
        echo "  No se escribe nada. Revisa FS_DB_NAME en $coredir/config.php." >&2
        return 1
    fi
    # …y que no sea la de OTRA instalación conocida. Las rutas de las demás salen
    # del fichero de máquina, que es el único que las sabe.
    while IFS= read -r otro; do
        [ -n "$otro" ] && [ "$otro" != "$id" ] || continue
        otra_raiz="$(registro_lee "$REGISTRO_MAQUINA" "$otro" repo_path)"
        [ -n "$otra_raiz" ] && [ -d "$otra_raiz" ] || continue
        otra_db="$(registro_db_test "$otra_raiz" "$(registro_lee "$REGISTRO_MAQUINA" "$otro" core_dir)")"
        if [ -n "$otra_db" ] && [ "$otra_db" = "$test_db" ]; then
            echo "ERROR: '$test_db' ya es la BD de pruebas de la instalación '$otro'." >&2
            echo "  ($otra_raiz)" >&2
            echo "  Dos instalaciones compartiendo base de test se contaminan sin avisar:" >&2
            echo "  ya pasó una vez y puso en rojo los tests de otro equipo. No se escribe nada." >&2
            return 1
        fi
    done < <(registro_ids "$REGISTRO_MAQUINA")
    return 0
}

# --- (A) el fichero de máquina: escribir una entrada -------------------------
# Se reescribe el bloque entero del id, conservando el resto del fichero.
registro_maquina_guarda() {  # <id> <clave=valor>...
    local id="$1"; shift
    local f="$REGISTRO_MAQUINA" tmp
    mkdir -p "$(dirname "$f")"
    if [ ! -f "$f" ]; then
        cat > "$f" <<'CAB'
# =============================================================================
# Lo que el entorno de pruebas sabe de ESTA máquina y de nadie más.
#
# NO SE VERSIONA y no debe: son rutas absolutas de este equipo. Lo que es del
# producto vive en `fs-test/config/instalaciones.conf`, y lo derivable no se
# guarda en ninguno de los dos.
#
# Lo escribe `fs-test/bin/init-project.sh`. Un bloque `[<id>]` por instalación,
# y un worktree es una instalación más.
# =============================================================================
CAB
    fi
    tmp="$(mktemp)"
    awk -v id="[$id]" 'BEGIN{dentro=0}
        /^[[:space:]]*\[/ { dentro = ($0 ~ "^[[:space:]]*\\" id "[[:space:]]*$") }
        !dentro { print }' "$f" > "$tmp"
    printf '\n[%s]\n' "$id" >> "$tmp"
    local kv
    for kv in "$@"; do printf '%-12s = %s\n' "${kv%%=*}" "${kv#*=}" >> "$tmp"; done
    mv "$tmp" "$f"
    chmod 600 "$f"
}

# --- (A ter) el fichero de máquina: QUIÉN es la instalación de esta ruta -----
# Devuelve el id del bloque cuyo `repo_path` es exactamente esa ruta, o vacío.
#
# Existe para que quien retira una copia NO tenga que derivar el id: derivarlo obliga a repetir la
# regla de `registro_id_de` —con su override `FS_TEST_ID` y su `REGISTRO_DEV_ROOT`— fuera de este
# repo, y una segunda copia de esa regla se desincroniza en silencio y acaba borrando el bloque
# equivocado. Aquí se pregunta por un dato que el que retira YA tiene: el directorio.
#
# Y de paso hace ESTRUCTURAL una guarda que si no habría que escribir: sólo puede encontrarse el
# bloque que apunta al directorio que se está retirando, así que **el ancla del proyecto —cuyo
# `repo_path` es la raíz principal, no la copia— no puede salir nunca por aquí**. La raíz principal
# no se puede quitar por este camino, y no porque se compare su nombre con algo.
registro_maquina_id_por_ruta() {  # <ruta>
    local ruta="${1:?falta la ruta}" f="$REGISTRO_MAQUINA"
    [ -f "$f" ] || return 1
    ruta="$(cd "$ruta" 2>/dev/null && pwd)" || ruta="$1"
    awk -v ruta="$ruta" '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*\[/ { id = $0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", id); next }
        /^[[:space:]]*repo_path[[:space:]]*=/ {
            v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); gsub(/[[:space:]]*$/, "", v)
            if (v == ruta && id != "") { print id; exit }
        }' "$f"
}

# --- (A bis) el fichero de máquina: DAR DE BAJA una entrada ------------------
# Simétrica de `guarda`: quita el bloque entero del id y deja el resto del fichero intacto — mismo
# `awk`, sin el añadido final.
#
# Existe porque NO existía, y se notaba: la entrada la escribe `init-project.sh` al configurar una
# copia, y al retirarla no la borraba nadie. Medido el 30-ago-2026: cuatro bloques huérfanos de
# copias retiradas días antes, uno de ellos de una copia borrada esa misma tarde.
#
# **Devuelve 1 si el id no estaba**, y esa distinción es el motivo de que se pueda comprobar: un
# borrado que dice lo mismo cuando quita algo y cuando no había nada es indistinguible de uno roto.
registro_maquina_borra() {  # <id>
    local id="${1:?falta el id}" f="$REGISTRO_MAQUINA" tmp
    [ -f "$f" ] || return 1
    grep -qE "^[[:space:]]*\[$id\][[:space:]]*$" "$f" || return 1
    tmp="$(mktemp)"
    awk -v id="[$id]" 'BEGIN{dentro=0}
        /^[[:space:]]*\[/ { dentro = ($0 ~ "^[[:space:]]*\\" id "[[:space:]]*$") }
        !dentro { print }' "$f" > "$tmp"
    mv "$tmp" "$f"
    chmod 600 "$f"
}
