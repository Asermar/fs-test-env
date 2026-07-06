#!/bin/bash
# Muestra la versión instalada del entorno de test (fichero VERSION del submódulo) y,
# si hay git + acceso al remoto, la compara con la del repositorio de origen.
#
# La versión es el "método de identificación" del tooling: sirve para saber si los
# scripts de test instalados están al día respecto a fs-test-env.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBMODULE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION_FILE="$SUBMODULE_DIR/VERSION"
REMOTE_BRANCH="${1:-main}"

INSTALLED="$( [ -f "$VERSION_FILE" ] && tr -d '[:space:]' < "$VERSION_FILE" || echo '0.0.0' )"
echo "Entorno de test instalado: v$INSTALLED"

if ! command -v git >/dev/null 2>&1 || ! git -C "$SUBMODULE_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    echo "(sin git o test-bin no es un repo: no comparo con el remoto)"
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
    echo "=> Hay una versión más reciente (v$REMOTE). Actualiza el submódulo test-bin:"
    echo "     git -C test-bin fetch && git -C test-bin checkout $REMOTE_BRANCH && git -C test-bin pull"
    echo "     git add test-bin && git commit -m 'chore: actualiza test-bin a v$REMOTE'"
else
    echo "=> La instalada va por delante del remoto (v$INSTALLED > v$REMOTE)."
fi
