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
registro_compose() {  # <raíz> → imprime CLAVE=valor de lo derivable
    local raiz="$1" c
    c="$(find "$raiz" -maxdepth 3 \( -name 'podman-compose*.y*ml' -o -name 'docker-compose*.y*ml' \) -print -quit 2>/dev/null)"
    [ -n "$c" ] || return 0
    awk '
        /^  [a-zA-Z0-9_-]+:[[:space:]]*$/ { svc = $1; sub(":", "", svc) }
        /container_name:/ {
            nombre = $2
            gsub(/\$\{[^}]*\}/, "", nombre)          # `${STACK_SUFFIX:-}` fuera: es de la copia
            if (nombre ~ /-test$/) { print "TESTENV_SERVICE=" svc; print "TESTENV_CONTAINER=" nombre }
            if (nombre ~ /-db$/)   { print "TESTENV_DB_SERVICE=" svc }
        }
        /routers\.[a-zA-Z0-9_-]+-test\.rule=Host\(/ {
            if (!visto_router) {
                r = $0; sub(/^.*routers\./, "", r); sub(/\.rule.*$/, "", r); print "TESTENV_TRAEFIK_ROUTER=" r
                h = $0; sub(/^.*Host\(`/, "", h); sub(/`.*$/, "", h); gsub(/\$\{[^}]*\}/, "", h)
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
