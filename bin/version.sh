#!/bin/bash
# Muestra la versión instalada del arnés (su fichero VERSION) y, si hay git + acceso al
# remoto, la compara con la del repositorio de origen.
#
# La versión es el "método de identificación" del tooling: sirve para saber si los
# scripts de test instalados están al día respecto a fs-test-env.
#
# El arnés se instala UNA vez y lo comparten los proyectos (en la flota,
# `~/Dev/Tooling/fs-test`, que es submódulo de Tooling); hasta la v3.0.0 era un
# submódulo `test-bin/` dentro de cada proyecto, y de ahí venían las órdenes de
# actualización que este script emitía y que ya no valen.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# La raíz del arnés: un nivel arriba de bin/. Esto sí puede derivarse de la posición del
# propio script, porque es SU propia carpeta, no la del proyecto que prueba.
SUBMODULE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION_FILE="$SUBMODULE_DIR/VERSION"
REMOTE_BRANCH="${1:-main}"

INSTALLED="$( [ -f "$VERSION_FILE" ] && tr -d '[:space:]' < "$VERSION_FILE" || echo '0.0.0' )"
echo "Entorno de test instalado: v$INSTALLED"

if ! command -v git >/dev/null 2>&1 || ! git -C "$SUBMODULE_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    echo "(sin git, o $SUBMODULE_DIR no es un repo: no comparo con el remoto)"
    exit 0
fi

if ! git -C "$SUBMODULE_DIR" fetch -q origin "$REMOTE_BRANCH" 2>/dev/null; then
    echo "(sin acceso al remoto: no comparo)"
    exit 0
fi

REMOTE="$(git -C "$SUBMODULE_DIR" show "origin/$REMOTE_BRANCH:VERSION" 2>/dev/null | tr -d '[:space:]')"
if [ -z "$REMOTE" ]; then
    echo "(el remoto no tiene fichero VERSION)"
    exit 0
fi
echo "Entorno de test remoto:    v$REMOTE"

if [ "$INSTALLED" = "$REMOTE" ]; then
    echo "=> Actualizado."
elif [ "$(printf '%s\n%s\n' "$INSTALLED" "$REMOTE" | sort -V | tail -1)" = "$REMOTE" ]; then
    # LAS ÓRDENES LLEVAN LA RUTA REAL DEL ARNÉS, NO UN NOMBRE DE CARPETA.
    # Emitían `git -C test-bin …`, que desde la v3.0.0 es un comando ROTO: el arnés ya no está
    # dentro del proyecto, así que `test-bin` no existe donde el usuario lo pegaría. Un script que
    # dicta un comando tiene que dictar uno que funcione desde donde se lee.
    echo "=> Hay una versión más reciente (v$REMOTE). Actualiza el arnés:"
    echo "     git -C $SUBMODULE_DIR fetch && git -C $SUBMODULE_DIR checkout $REMOTE_BRANCH && git -C $SUBMODULE_DIR pull"
    echo "   Y si está montado como submódulo (en la flota, de Tooling), registra el puntero allí:"
    echo "     git -C $(dirname "$SUBMODULE_DIR") add $(basename "$SUBMODULE_DIR")"
else
    echo "=> La instalada va por delante del remoto (v$INSTALLED > v$REMOTE)."
fi
