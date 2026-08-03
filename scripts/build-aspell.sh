#!/usr/bin/env bash
set -euo pipefail

to_unix_path() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) cygpath -u "$1" ;;
    esac
}

archive=$(to_unix_path "${RECOLL_ASPELL_SOURCE_TARBALL:?}")
build_root=$(to_unix_path "${RECOLL_ASPELL_BUILD_ROOT:?}")
prefix=$(to_unix_path "${RECOLL_ASPELL_PREFIX:?}")

mkdir -p "$build_root" "$prefix"
tar -xzf "$archive" -C "$build_root"
source_dir=$(find "$build_root" -mindepth 1 -maxdepth 1 -type d -name 'aspell-0.60.7' -print -quit)
test -n "$source_dir"

cd "$source_dir"
# Aspell 0.60.7 uses asc_isalpha() in file_util.cpp but omits the matching
# header. Current MinGW compilers do not expose that declaration indirectly.
if ! grep -q '^#include "asc_ctype.hpp"$' common/file_util.cpp; then
    sed -i '/^#include "file_util.hpp"$/a #include "asc_ctype.hpp"' common/file_util.cpp
fi
# The Windows runner exports Git for Windows' shell with a path containing a
# space. Autoconf would otherwise bake `C:/Program Files/Git/.../sh.exe` into
# the Makefiles, where MSYS2 cannot execute it as an unquoted recipe command.
export SHELL=/usr/bin/sh
export CONFIG_SHELL=/usr/bin/sh
./configure \
    --prefix="$prefix" \
    --enable-win32-relocatable \
    --enable-compile-in-filters \
    --enable-32-bit-hash-fun \
    --disable-nls \
    --disable-curses
make -j2 SHELL=/usr/bin/sh
make install SHELL=/usr/bin/sh

# Aspell is built with MinGW while Recoll itself is built with MSVC. Keep the
# MinGW runtime beside Aspell so the package stays self-contained and the DLLs
# cannot collide with the Qt/MSVC runtime at the package root.
for dll in libgcc_s_seh-1.dll libstdc++-6.dll libwinpthread-1.dll; do
    test -f "/mingw64/bin/$dll"
    cp "/mingw64/bin/$dll" "$prefix/bin/"
done

test -f "$prefix/bin/aspell.exe"
