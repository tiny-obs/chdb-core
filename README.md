# chdb-core, `lite-shared` branch

A fork of [chdb-io/chdb-core](https://github.com/chdb-io/chdb-core) at tag `v26.9.0` that adds one build mode: a
small, Linux-only `libchdb.so` of the embedded ClickHouse engine, for use from Go.

- This fork: <https://github.com/tiny-obs/chdb-core>
- Go `database/sql` driver for this library: <https://github.com/tiny-obs/chdb-sql>
- Original project README: [README.upstream.md](./README.upstream.md). It still applies to the default builds; this
  branch does not change them.

## What changed

| File | Change |
|---|---|
| `chdb/build.sh` | New mode `CHDB_LITE_SHARED=1` (with `CHDB_LITE=1`): builds only `libchdb.so`, strips it, and prints `ldd` and the exported C API. Linux only. Applies the trims below, caps build jobs, and checks that the required submodules are present. |
| `chdb/lite_shared_submodules.sh` | New. Initialises the 43 submodules this build needs, shallow and at the pinned SHA. |
| `programs/local/CMakeLists.txt` | New option `CHDB_NO_ARROW` (default off): builds the core C API and embedded server with the source set of the wasm build, so Arrow and Parquet are not compiled. Fails if combined with `ENABLE_PYTHON`. |
| `programs/local/chdb.cpp`, `EmbeddedServer.cpp`, `LocalServer.cpp` | Arrow includes and registrations are guarded with `!defined(CHDB_NO_ARROW)`. |
| `README.md`, `README.upstream.md`, `setup.cfg`, `docs/PANDAS_COMPATIBILITY.md` | This file is new; the original README was renamed and the two references to it were updated. |
| `.gitignore` | Ignores `/local/` (private notes). |

Plain `CHDB_LITE=1` (the Python wheel) and the full build behave as before.

## What the lite build drops

- Arrow and Parquet formats, the Arrow stream table function and storage, the ADBC driver, and every `chdb_arrow_*`
  entry point (`CHDB_NO_ARROW`, `ENABLE_PARQUET=0`).
- Thrift, Brotli, RapidJSON, S3 and S3-backed disks, Protobuf formats, ORC.
- Everything `CHDB_LITE` already drops: HDFS, Kerberos, MySQL, Postgres, Azure, Kafka, ICU collation, the embedded
  JIT compiler, niche functions, some dictionary layouts, and the ASOF/SEMI/ANTI hash joins.

Kept: MergeTree, `DateTime64`, `LowCardinality`, the JSON formats `chdb-sql` uses, `simdjson`, jemalloc, and the
`remote()` and `remoteSecure()` table functions (not verified on this build, see Limitations). The JIT compiler is off, but
`contrib/llvm-project` is still needed for `libcxx`, `libunwind`, `libc` math and `compiler-rt`.

## Build

Requirements: Linux x86_64 with AVX2, about 7 GB of free disk (measured: 3.1 GB of submodules, 2.5 GB `buildlib/`, 0.7 GB ccache), 15 GB of RAM (the default job caps assume this),
and clang 21 with lld 21. On Ubuntu 26.04 these come from the distribution:

```
sudo apt-get install -y --no-install-recommends cmake ninja-build clang-21 lld-21 llvm-21 binutils build-essential ccache
```

On older distributions, get clang 21 from <https://apt.llvm.org>.

```
git clone https://github.com/tiny-obs/chdb-core && cd chdb-core && git checkout lite-shared
bash chdb/lite_shared_submodules.sh        # 43 of 156 submodules, about 3 GB
export CC=clang-21 CXX=clang++-21 CHDB_LITE=1 CHDB_LITE_SHARED=1 CHDB_VERSION=26.9.0
bash chdb/build.sh
```

Output: `libchdb.so` in the repository root; the unstripped link output stays in `buildlib/libchdb.so`.

- `chdb/lite_shared_submodules.sh` is idempotent. Three submodules are sparse, blobless checkouts:
  `contrib/llvm-project` (`libc`, `compiler-rt`, `third-party/siphash`, `libcxx`, `libcxxabi`, `libunwind`; about
  200 MB), `contrib/sysroot` (`README.md` and `linux-x86_64/`; the compile uses it as `--sysroot`), and
  `contrib/arrow` (`cpp/src/arrow/c/abi.h`, the one header `chdb-internal.h` includes).
- `CHDB_PARALLEL_COMPILE_JOBS` (default 6) and `CHDB_PARALLEL_LINK_JOBS` (default 1) cap the parallelism so that a
  15 GB host does not run out of memory. Raise them on a larger machine.
- Use a fresh `buildlib/`: a CMake cache from a full or Python-module configure does not mix with this one.
- With a cold ccache the build took about an hour of compile time on 8 cores.

## Result (measured 2026-10-13, Ubuntu 26.04, clang 21.1.8)

- Stripped `libchdb.so`: 177,906,464 bytes (170 MB). Compressed: 57 MB with gzip -9, 38 MB with xz -6. The
  unstripped link output is 251 MB. The "~50 MB" in the `CHDB_LITE` comments in `CMakeLists.txt` is a compressed
  wheel size.
- Build type `MinSizeRel`.
- `ldd`: `libc`, `libm`, `libpthread`, `librt`, `libdl` and the loader only. Highest versioned glibc symbol: 2.4.
- 54 exported symbols, all from the C API declared in `programs/local/chdb.h`, without the Arrow and ADBC entry
  points. The export map is filtered into `buildlib/libchdb_export_noarrow.map` because lld rejects names in a
  version script that do not exist.

## Use from Go

Load it with [chdb-go](https://github.com/chdb-io/chdb-go) (`chdb-purego`, no cgo) by setting the library path:

```
CHDB_LIB_PATH=/path/to/libchdb.so go test ./...
```

`chdb-purego` looks at `CHDB_LIB_PATH` first, then `libchdb.so` on `PATH`, then `/usr/local/lib/libchdb.so`; check
`/proc/self/maps` if you need to be sure which file was loaded.

The stock chdb-go `database/sql` driver does not work with this library: it needs Parquet and a single session. Use
[tiny-obs/chdb-sql](https://github.com/tiny-obs/chdb-sql) (module `github.com/tiny-obs/chdb-sql`, package
`chdbsql`) instead: one connection per pooled `driver.Conn`, results read as `JSONCompactEachRowWithNamesAndTypes`.

## Verification done

- `chdb-sql` test suite against the stripped library: 30 consecutive runs without failure.
- On a scratch directory, through `chdb-sql`: `CREATE TABLE` for a `logs` table
  (`DateTime64(3)`, `LowCardinality(String)`, `String`, `MergeTree ORDER BY ts`) and a `metrics` table; one batched
  `INSERT ... FORMAT JSONEachRow` of 1000 rows into each; `GROUP BY` and `toStartOfMinute` aggregates with the
  expected counts and sums; closing and reopening the data directory kept all rows; `TRUNCATE` and `DROP` worked.
- A read-only open of a copy of an existing data directory written by ClickHouse 26.9.x: 12 tables, same row counts.
- `Parquet` format and `s3()` return errors, as intended.

## Known issue: chdb-go v1.12.0 `Free` on an unfinished stream

`chdb-purego` `streamingResult.Free` (`streaming.go`) calls `chdbStreamCancelQuery(c.curConn, c.stream)`, but every
other call passes `c.curConn.internal_data`. libchdb therefore reads the connection cell as the connection, and
`chdb_stream_cancel_query` can lock a mutex in the wrong object: the process hangs, or rarely crashes with SIGSEGV.
It happens on any stream that has not reached its natural end (a failed query, or closing before the last row),
with this library and with the full prebuilt one (a `chdb-sql` test run hung in 6 of 8 runs with the lite library
and crashed in 1 of 8 with the prebuilt one). This is a chdb-go bug, not a libchdb bug. `chdb-sql` works around it
by not freeing unfinished streams; the small result handle leaks until the connection closes.

## Limitations

- `remote()` and `remoteSecure()` are not verified on this build. `remote()` was only exercised against the full
  prebuilt library.
- Needs a CPU with AVX2 (`-march=x86-64-v3`).
- Built and tested on Linux x86_64 only; `CHDB_LITE_SHARED=1` exits on other systems.
- Arrow, Parquet, ORC, S3 and Protobuf are not available, and `CHDB_NO_ARROW` cannot be combined with the Python
  module.
