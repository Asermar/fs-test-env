#!/bin/bash
# Helpers para elegir la referencia del core de FacturaScripts (rama o tag de versión).
# Se hace `source` desde setup-test-env.sh y test-env-provision.sh.
# Requiere las variables CORE_ROOT (core instalado) y CORE_REPO (repo de origen).
#
# En el repo de FacturaScripts las versiones son TAGS con prefijo 'v' que coinciden con
# Kernel::version() (p.ej. 2026.3 -> tag v2026.3).

# Versión de FacturaScripts instalada, leída del core SIN arrancar el framework
# (extrae el literal de Kernel::version()). Devuelve p.ej. "2026.3" o nada.
fs_installed_version() {
    local kernel="${CORE_ROOT:-}/Core/Kernel.php"
    [ -f "$kernel" ] || return 1
    awk '/function[ \t]+version[ \t]*\(/{f=1} f&&/return/{gsub(/[^0-9.]/,""); if($0!=""){print; exit}}' "$kernel"
}

# Referencia por defecto: el tag de la versión instalada (v<version>) si existe en el
# origen; si no (o sin git/red), "master".
fs_default_ref() {
    local ver
    ver="$(fs_installed_version 2>/dev/null || true)"
    if [ -n "$ver" ] && command -v git >/dev/null 2>&1; then
        if git ls-remote --tags "$CORE_REPO" "v$ver" 2>/dev/null | grep -q .; then
            echo "v$ver"
            return 0
        fi
    fi
    echo "master"
}

# Hasta 5 tags de versión más recientes del origen (orden de versión descendente).
fs_recent_tags() {
    command -v git >/dev/null 2>&1 || return 0
    git ls-remote --tags --sort=-v:refname "$CORE_REPO" 2>/dev/null \
        | awk '{print $2}' \
        | sed 's#refs/tags/##; s/\^{}//' \
        | grep -E '^v?[0-9]' \
        | awk '!seen[$0]++' \
        | head -5
}
