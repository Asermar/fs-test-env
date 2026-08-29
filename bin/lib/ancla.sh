#!/bin/bash
# =============================================================================
# EL ENTORNO DE TEST VIVE EN UNA COPIA, NO EN EL CHECKOUT PRINCIPAL.
#
# NO es ejecutable: se usa con `source`.
#
# ## POR QUÉ ESTÁ AQUÍ Y NO COPIADO EN CADA SCRIPT
#
# Decisión de Alexis (27-ago-2026): con desarrollo basado en worktrees el entorno vive en la copia,
# y **la existencia de la copia es su declaración de propiedad** — si la copia existe tiene dueño;
# si no existe, el entorno es basura. Los entornos de los principales se retiraron ese día.
#
# La decisión tiene **tres puertas en el arnés** —generar la configuración, levantar el contenedor y
# provisionar— y hasta el 29-ago sólo estaba cerrada la tercera: medido, la guarda aparecía 10 veces
# en `test-env-provision.sh` y CERO en `init-project.sh` y en `up.sh`. Por la primera entró un caso
# real: `init-project.sh` corrió contra el principal de Mesa/FS y generó el `.fs-test-env.env` y el
# `.fs-test-env/` sin protestar.
#
# Con tres puertas, tres copias del mismo bloque no son «copiar lo que ya existe»: son tres verdades
# sobre lo mismo que acabarán divergiendo, y la que se quede atrás dejará pasar justo lo que las
# otras rechazan. Así que la señal y el mensaje viven aquí, y los tres scripts los usan.
#
# ## LA SEÑAL, y NO es la que parece
#
#     git rev-parse --absolute-git-dir              vs.  --path-format=absolute --git-common-dir
#     iguales → checkout PRINCIPAL                        distintos → WORKTREE
#
# **«El `.git` es un fichero» NO sirve**, y el error habría sido invisible donde importa: en un
# SUBMÓDULO el `.git` también es un fichero. Medido sobre los cuatro casos reales de esta casa —
# `Mesa/FS` (directorio), `Mesa/FS/src/Plugins/OkoTranslate` (fichero), `Tooling/fs-test` (fichero)
# y un worktree (fichero)—: con el tipo de `.git`, los dos submódulos saldrían «worktree». Y los
# clientes son superproyectos llenos de submódulos, así que habría acertado en la raíz y mordido en
# cada plugin.
#
# ## POR QUÉ LA SEÑAL DE GIT Y NO EL ID `-wt-` DEL REGISTRO
#
# Porque el id es un NOMBRE, y un nombre falla en las dos direcciones. Medido:
#
#   - un worktree creado a mano SIN la convención (`FS-arreglourgente`) → git dice worktree, el id
#     dice «no es copia»: con el id se RECHAZARÍA trabajo legítimo;
#   - una carpeta llamada `FS-wt-falso` que es un repo normal → git dice principal, el id dice «es
#     copia»: con el id se DEJARÍA PASAR justo lo que hay que impedir.
#
# La regla habla del ÁRBOL DE TRABAJO, no de cómo se llame. Así que la señal es la de git, y el
# registro entra sólo para lo que sí sabe: la FRASE que declara qué es un ancla.
#
# ## EL ESCAPE ES UN FLAG, NO UNA VARIABLE, y a propósito
#
# Un rechazo sin salida acaba bloqueando algo legítimo. Pero una variable de entorno se exporta una
# vez y se olvida —en un perfil, en un compose— y a partir de ahí el rechazo no rechaza nada, en
# silencio. Un flag tiene que escribirse en CADA invocación, así que queda a la vista en el
# historial, en el script que lo llame y en el botón que lo dispare.
# =============================================================================

# ancla_es_principal <raíz> → 0 si esa raíz es un checkout PRINCIPAL.
#
# Devuelve 1 también cuando la raíz NO es un repo de git: sin repo no hay principal que proteger, y
# es lo que mantiene la guarda fuera del camino de las fixtures de las baterías, que son directorios
# sueltos. Que un no-repo pase no es un agujero: los tres scripts fallan después por otras razones.
ancla_es_principal() {
    local raiz="${1:?falta la raíz del proyecto}" dir comun
    dir="$(git -C "$raiz" rev-parse --absolute-git-dir 2>/dev/null || true)"
    comun="$(git -C "$raiz" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    [ -n "$dir" ] && [ "$dir" = "$comun" ]
}

# ancla_frase <id> → la descripción del bloque del registro, o vacío si no lo hay.
#
# Es la frase que se cita al rechazar. Vive en el registro y no aquí a propósito: lo que un ancla ES
# lo declara el registro —«El checkout principal NO monta entorno de test; el desarrollo va en
# worktrees»—, y repetirla en el código sería otra vez dos verdades sobre lo mismo.
ancla_frase() {
    local id="${1:-}"
    [ -n "$id" ] || return 0
    registro_lee "$REGISTRO_CONF" "$id" descripcion 2>/dev/null || true
}

# ancla_niega <raíz> <id> <lo que este script iba a hacer> <cómo se invoca el escape>
#
# Imprime el rechazo por stderr. NO sale: el que sale es quien la llama, para que el `exit` esté a la
# vista en el script que decide.
#
# EL MENSAJE OFRECE LA SALIDA, y ésa es su razón de ser. Quien llega aquí no está haciendo el tonto:
# viene de OkoFlow pidiendo tests en verde para cerrar una rama. Una negativa a secas lo deja igual
# de atascado que antes —es literalmente lo que le faltó al codificador que se topó con esto—, así
# que la orden que sí funciona va EN LA MISMA PANTALLA que la negativa, no en una documentación.
ancla_niega() {
    local raiz="$1" id="$2" accion="$3" escape="$4" frase
    frase="$(ancla_frase "$id")"
    {
        printf 'ERROR: «%s» es el checkout PRINCIPAL, y %s no va aquí.\n\n' "$raiz" "$accion"
        if [ -n "$frase" ]; then
            printf '  Lo dice el registro, en la entrada [%s] de config/instalaciones.conf:\n\n' "$id"
            printf '      «%s»\n\n' "$frase"
        else
            printf '  Con desarrollo por worktrees el entorno vive en la COPIA, y la existencia de la copia es\n'
            printf '  su declaración de propiedad: si la copia existe tiene dueño, y si no existe el entorno es\n'
            printf '  basura. Montarlo en el principal devuelve algo que nadie reclama y que nadie retira.\n\n'
        fi
        printf '  Crea la copia y trabaja ahí — esto es lo que quieres si vienes a dejar los tests en verde\n'
        printf '  para cerrar una rama:\n\n'
        printf '      okoworktree add <nombre> --db-mode fresh\n\n'
        printf '  Eso levanta su stack y provisiona su entorno de test, con SU base de datos.\n\n'
        printf '  Si de verdad hace falta aquí —y conviene decir por qué antes de hacerlo— el escape es\n'
        printf '  explícito y hay que escribirlo en cada invocación:\n\n'
        printf '      %s\n\n' "$escape"
        printf '  Es un flag y no una variable de entorno a propósito: una variable se exporta una vez y se\n'
        printf '  olvida, y a partir de ahí este rechazo dejaría de rechazar sin que nadie lo notara.\n'
    } >&2
}

# ancla_avisa_escape <raíz> <qué se está haciendo>
# El escape es RUIDOSO: se usa, pero no en silencio.
ancla_avisa_escape() {
    ancla_es_principal "$1" && \
        echo "AVISO: $2 en el checkout PRINCIPAL con --en-el-principal. Queda sin dueño." >&2
    return 0
}
