# Path maps for the engine build. Sourced by runtime/n/build.sh and qa/n/path-map-probe.sh once CACHE (the build
# cache) and ROOT (the checkout) are set; defines PREFIX_MAPS, OSO_PREFIX and wz_cross_file_with_maps.
#
# Nothing that ships may name the build machine, and the cache and the checkout live in the builder's home folder.
# Compilers record source paths in three places:
#   - __FILE__ (Wine's critical-section names and assertions) and debug info (DW_AT_comp_dir, file names):
#     -ffile-prefix-map and -fdebug-prefix-map, understood by Apple's clang, llvm-mingw's clang and mingw-w64 GCC.
#     The cache becomes /warzag-build, the checkout /warzag. A path through a symbolic link is recorded as spelled or
#     resolved (meson resolves its source and build directories), so when the cache or the checkout has a link in its
#     path (/tmp is /private/tmp) both spellings are mapped.
#   - the debug map of a Mach-O link (N_OSO, each object file's absolute path): -Wl,-oso_prefix makes those paths
#     relative to the cache; build.sh also strips the deps with strip -S.
#   - the Metal front end ignores both maps and records the absolute path of a named input file in the AIR module
#     (!air.source_file_name), so DXMT's airconv shaders are compiled from stdin (wz-n-dxmt-0001).
# The install stage then scans the stage with tools/release/forbidden-scan.py --personal.

# A directory with its symbolic links resolved, or as given if it does not exist (yet).
wz_physical_dir() { (CDPATH='' cd -- "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1"; }
WZ_CACHE_PHYSICAL="$(wz_physical_dir "$CACHE")"
WZ_ROOT_PHYSICAL="$(wz_physical_dir "$ROOT")"
# The values go into compiler flags (split on spaces), sed/awk replacements and meson's quoted array literals.
# Compilers record absolute paths, so a relative one would map nothing, and a map of / would rewrite every path, the
# SDK's included.
for wz_dir in "$CACHE" "$ROOT" "$WZ_CACHE_PHYSICAL" "$WZ_ROOT_PHYSICAL"; do
    case "$wz_dir" in
        */|*[[:space:]\'\"\\\&\|=]*) ;;
        /*) continue ;;
    esac
    echo "error: the build cache and the checkout must be absolute paths other than /, without a trailing /, spaces," \
        "quotes, backslashes, '&', '|' or '=' (got '$wz_dir')" >&2
    exit 1
done
unset wz_dir
PREFIX_MAPS="-ffile-prefix-map=$CACHE=/warzag-build -fdebug-prefix-map=$CACHE=/warzag-build"
[ "$WZ_CACHE_PHYSICAL" = "$CACHE" ] || PREFIX_MAPS="$PREFIX_MAPS -ffile-prefix-map=$WZ_CACHE_PHYSICAL=/warzag-build -fdebug-prefix-map=$WZ_CACHE_PHYSICAL=/warzag-build"
PREFIX_MAPS="$PREFIX_MAPS -ffile-prefix-map=$ROOT=/warzag -fdebug-prefix-map=$ROOT=/warzag"
[ "$WZ_ROOT_PHYSICAL" = "$ROOT" ] || PREFIX_MAPS="$PREFIX_MAPS -ffile-prefix-map=$WZ_ROOT_PHYSICAL=/warzag -fdebug-prefix-map=$WZ_ROOT_PHYSICAL=/warzag"
OSO_PREFIX="-Wl,-oso_prefix,$CACHE/"

# wz_cross_file_with_maps <meson cross file> <out>: a copy with PREFIX_MAPS appended to its c_args and cpp_args.
# DXMT's cross file sets those to ['-marm64x'], and a machine file's options win over CFLAGS from the environment,
# while -Dc_args (or a second --cross-file) would replace -marm64x instead of adding to it.
wz_cross_file_with_maps() {
    local items="" flag
    for flag in $PREFIX_MAPS; do items="$items, '$flag'"; done
    awk -v items="$items" '
        /^[[:space:]]*(c_args|cpp_args)[[:space:]]*=[[:space:]]*\[.*\][[:space:]]*$/ {
            sub(/\][[:space:]]*$/, items "]"); changed++ }
        { print }
        END { if (changed != 2) exit 3 }' "$1" > "$2" \
        || { echo "error: $1 has no one-line c_args and cpp_args arrays to add the path maps to" >&2; return 1; }
}
