# ORIGIN — where extra/kallrecon/ comes from

Vendored from **Dere3046/KallRecon**  
<https://github.com/Dere3046/KallRecon> — "reconstruct kallsyms on ARM64 GKI,
depends only on `sprint_symbol`". Licensed GPL-2.0.

Upstream `lib/` maps to `extra/kallrecon/`:

| upstream | here |
|---|---|
| `lib/*.c`, `lib/*.h`, `lib/anchor.S` | `extra/kallrecon/` |

Not vendored: `lib/raana/` — KallRecon's optional runtime helper, not needed for
the layout probe these modules use.

The files are byte-for-byte identical to upstream `lib/`; verified against the
blob hashes of `core.c` and `discover.c`.

Used by `extra/cgrouplimits/` (pids/cpu) and `extra/devtmpfs/`, which call its
`kallrecon_klp()` function pointer to resolve symbols the vendor kernel does not
export.
