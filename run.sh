#!/usr/bin/env bash
# Reproduces https://github.com/godotengine/godot/issues/122158: a headless
# editor run crashes at exit when the editor docs cache it finds was written
# by a different Godot build of the same minor version.
#
#   ./run.sh [ROUNDS] [VERSION_A] [VERSION_B]
#
# ROUNDS     rounds to run (default 5)
# VERSION_A  the build that writes the docs cache first (default 4.7.1-stable)
# VERSION_B  the build run against A's cache (default 4.7.2-stable)
#
# A version is a Godot release tag such as 4.7.2-stable or 4.8-beta3. Add
# -mono for the .NET build (4.7.2-stable-mono; needs the .NET SDK installed).
# The official Linux x86_64 builds are downloaded into ./bin and checked
# against the release's SHA512-SUMS.txt.
#
# Every Godot user folder (data, config, cache) points into ./godot-user, a
# fresh one each round, so nothing in your home folder is read or written.
set -u

here=$(cd "$(dirname "$0")" && pwd)
rounds=${1:-5}
ver_a=${2:-4.7.1-stable}
ver_b=${3:-4.7.2-stable}
bin=$here/bin
user=$here/godot-user
out=$here/out
project=$here/project
timeout_s=${TIMEOUT:-600}

die() { echo "error: $*" >&2; exit 2; }

[ "$(uname -s)" = Linux ] || die "this script is for Linux"
[ "$(uname -m)" = x86_64 ] || die "this script downloads the x86_64 builds"
command -v curl > /dev/null || die "curl is needed"
command -v sha512sum > /dev/null || die "sha512sum is needed"
if command -v unzip > /dev/null; then
  extract() { unzip -q -o "$1" -d "$2"; }
elif command -v python3 > /dev/null; then
  extract() { python3 -I -m zipfile -e "$1" "$2"; }
else
  die "unzip (or python3) is needed"
fi

# install VERSION: downloads and checks the build, prints the binary's path
install() {
  local spec=$1 tag zip exe dir sums url
  case "$spec" in
    *-mono)
      tag=${spec%-mono}
      zip=Godot_v${tag}_mono_linux_x86_64.zip
      exe=Godot_v${tag}_mono_linux_x86_64/Godot_v${tag}_mono_linux.x86_64 ;;
    *)
      tag=$spec
      zip=Godot_v${tag}_linux.x86_64.zip
      exe=Godot_v${tag}_linux.x86_64 ;;
  esac
  dir=$bin/$spec
  if [ -x "$dir/$exe" ]; then echo "$dir/$exe"; return 0; fi
  mkdir -p "$dir"
  url=https://github.com/godotengine/godot-builds/releases/download/$tag
  sums=$bin/$tag-SHA512-SUMS.txt
  if [ ! -s "$sums" ]; then
    curl -fsSL -o "$sums" "$url/SHA512-SUMS.txt" || die "no SHA512-SUMS.txt for $tag (is it a release tag?)"
  fi
  echo "downloading $zip" >&2
  curl -fSL --progress-bar -o "$bin/$zip" "$url/$zip" || die "download failed: $url/$zip"
  local want got
  want=$(awk -v f="$zip" '$2 == f { print $1 }' "$sums")
  got=$(sha512sum "$bin/$zip" | cut -d' ' -f1)
  [ -n "$want" ] || die "$zip is not listed in $tag's SHA512-SUMS.txt"
  [ "$want" = "$got" ] || { rm -f "$bin/$zip"; die "checksum mismatch for $zip"; }
  echo "checksum ok: $zip" >&2
  extract "$bin/$zip" "$dir" || die "could not extract $zip"
  rm -f "$bin/$zip"
  chmod +x "$dir/$exe"
  echo "$dir/$exe"
}

godot_a=$(install "$ver_a") || exit 2
godot_b=$(install "$ver_b") || exit 2
for g in "$godot_a" "$godot_b"; do
  # self-contained mode would give each build a cache of its own
  [ -e "$(dirname "$g")/._sc_" ] && die "remove $(dirname "$g")/._sc_ (self-contained mode hides the bug)"
done

export XDG_DATA_HOME=$user/data XDG_CONFIG_HOME=$user/config XDG_CACHE_HOME=$user/cache

rm -rf "$out"
mkdir -p "$out"
report=$out/report.txt

# run NAME BINARY: one headless import of a project with no .godot folder
run() {
  local name=$1 godot=$2 code
  rm -rf "$project/.godot"
  timeout "$timeout_s" "$godot" --headless --verbose --path "$project" --import > "$out/$name.log" 2>&1
  code=$?
  echo "$code"
}

# describe CODE LOG
describe() {
  local code=$1 log=$2
  if [ "$code" = 124 ]; then echo "exit 124 (timed out)"
  elif [ "$code" -ge 128 ]; then echo "exit $code (CRASHED, signal $((code - 128)))"
  elif grep -q "Program crashed" "$log"; then echo "exit $code (CRASHED)"
  else echo "exit $code"
  fi
}

crashed() { [ "$1" -ge 128 ] && [ "$1" != 124 ] || grep -q "Program crashed" "$2"; }

{
  echo "A: $("$godot_a" --version 2>/dev/null | tail -n 1)  ($ver_a)"
  echo "B: $("$godot_b" --version 2>/dev/null | tail -n 1)  ($ver_b)"
  echo "os: $(uname -srm)$( [ -r /etc/os-release ] && . /etc/os-release && echo ", $PRETTY_NAME")"
  echo "cpu: $(nproc) x $(awk -F': ' '/model name/ { print $2; exit }' /proc/cpuinfo)"
  echo "godot user folders: ./godot-user (XDG_DATA_HOME, XDG_CONFIG_HOME, XDG_CACHE_HOME)"
  echo "rounds: $rounds"
  echo
} | tee "$report"

hit_a=0 hit_b1=0 hit_b2=0
i=1
while [ "$i" -le "$rounds" ]; do
  rm -rf "$user"
  mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"

  # 1. A starts with no docs cache and writes its own
  a=$(run "round-$i-1-A" "$godot_a")
  crashed "$a" "$out/round-$i-1-A.log" && hit_a=$((hit_a + 1))
  cache=$(cd "$XDG_CACHE_HOME/godot" 2>/dev/null && ls editor_doc_cache-*.res 2>/dev/null | tr '\n' ' ')

  # 2. B finds A's docs cache, rejects it and regenerates it
  b1=$(run "round-$i-2-B" "$godot_b")
  crashed "$b1" "$out/round-$i-2-B.log" && hit_b1=$((hit_b1 + 1))

  # 3. B again, now with its own docs cache
  b2=$(run "round-$i-3-B-again" "$godot_b")
  crashed "$b2" "$out/round-$i-3-B-again.log" && hit_b2=$((hit_b2 + 1))

  printf 'round %d: A (no cache) %s | B (A'"'"'s cache %s) %s | B again %s\n' "$i" \
    "$(describe "$a" "$out/round-$i-1-A.log")" "${cache% }" \
    "$(describe "$b1" "$out/round-$i-2-B.log")" "$(describe "$b2" "$out/round-$i-3-B-again.log")" | tee -a "$report"
  i=$((i + 1))
done

rm -rf "$user" "$project/.godot"

{
  echo
  echo "crashes / runs"
  echo "  A with no docs cache:        $hit_a/$rounds"
  echo "  B with A's docs cache:       $hit_b1/$rounds"
  echo "  B again, with its own cache: $hit_b2/$rounds"
  echo "logs: ./out"
} | tee -a "$report"
