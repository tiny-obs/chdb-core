#!/bin/bash
# Initialise only the submodules that `CHDB_LITE=1 CHDB_LITE_SHARED=1 bash chdb/build.sh` needs
# (43 of 156), shallow and at the SHA pinned by this checkout. Idempotent; safe to re-run.
#
#   bash chdb/lite_shared_submodules.sh
#
# Three of them are sparse, blobless checkouts instead of full clones:
#   contrib/llvm-project  libc, compiler-rt, third-party/siphash, libcxx, libcxxabi, libunwind (about 200 MB)
#   contrib/sysroot       README.md and linux-x86_64/ (the compile uses it as --sysroot)
#   contrib/arrow         cpp/src/arrow/c/abi.h only (the one header chdb-internal.h includes)

set -euo pipefail

cd "$( dirname "${BASH_SOURCE[0]}" )/.."

PLAIN="
SHA3IUF StringZilla abseil-cpp boost c-ares cctz clickstack crc32c croaring double-conversion fast_float fmtlib
jemalloc libarchive libdivide librseq libuv libxml2 lz4 magic_enum miniselect morton-nd nlohmann-json openssl re2
replxx silk simdjson snappy sparsehash-c11 sql-console utf8proc wyhash xsimd xxHash xz zlib-ng zmij zstd zxc
"

pinned_sha() { git ls-tree HEAD -- "$1" | awk '{print $3}'; }

# Check out <path> at its pinned SHA: shallow, and sparse + blobless when sparse patterns are given.
# usage: checkout_pinned <path> <cone|nocone> [sparse pattern...]
checkout_pinned() {
    local path=$1 mode=$2; shift 2
    local sha url
    sha=$(pinned_sha "${path}")
    git submodule init -- "${path}" > /dev/null
    url=$(git config "submodule.${path}.url")

    if [ -e "${path}/.git" ]; then
        if [ "$(git -C "${path}" rev-parse HEAD)" = "${sha}" ]; then
            echo "ok       ${path} (already at ${sha:0:12})"
        else
            git -C "${path}" fetch -q --depth 1 origin "${sha}"
            git -C "${path}" checkout -q --detach "${sha}"
            echo "fixed    ${path} -> ${sha:0:12}"
        fi
        return
    fi

    # Fresh sparse checkout: fetch exactly the pinned commit without blobs, set the patterns, then check out,
    # so only the wanted files are downloaded.
    git init -q "${path}"
    git -C "${path}" remote add origin "${url}"
    git -C "${path}" config extensions.partialClone origin
    git -C "${path}" fetch -q --depth 1 --filter=blob:none origin "${sha}"
    if [ "${mode}" = "cone" ]; then
        git -C "${path}" sparse-checkout set --cone "$@"
    else
        git -C "${path}" sparse-checkout set --no-cone "$@"
    fi
    git -C "${path}" checkout -q --detach "${sha}"
    git submodule absorbgitdirs -- "${path}"
    echo "cloned   ${path} at ${sha:0:12} (sparse)"
}

# Plain shallow submodules (clone in parallel), then pin check: --depth 1 can leave a submodule at the upstream
# branch tip instead of the pinned SHA.
paths=()
for p in ${PLAIN}; do paths+=("contrib/${p}"); done
git submodule update --init --depth 1 --jobs 8 -- "${paths[@]}"
for p in "${paths[@]}"; do
    checkout_pinned "${p}" cone
done

checkout_pinned contrib/llvm-project cone compiler-rt libc libcxx libcxxabi libunwind third-party/siphash
checkout_pinned contrib/sysroot nocone /README.md /linux-x86_64/
checkout_pinned contrib/arrow nocone /cpp/src/arrow/c/abi.h

echo
git submodule status | awk '{ c = substr($1, 1, 1); n[c == "-" ? "not initialised" : (c == "+" ? "NOT at pinned SHA" : "initialised")]++ }
    END { for (k in n) printf "%-20s %d\n", k, n[k] }'
