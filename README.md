# Godot docs-cache crash at exit: repro

Reproduces [godotengine/godot#122158](https://github.com/godotengine/godot/issues/122158):
a command-line editor run (`--headless --import`) crashes on exit, every
time, when the editor docs cache it finds (`editor_doc_cache-<major.minor>.res`
in the user cache folder) was written by a **different build of the same
minor version**: another patch release, another beta, or the .NET build
against the standard one.

The import itself finishes and saves everything. The crash comes during
`Main::cleanup()`: the cache's version hash does not match, so the editor
regenerates it, and a deferred `EditorHelp::load_script_doc_cache()` runs
after `EditorNode` and `EditorFileSystem` are freed. `is_cmdline_mode()`
fails on the null singleton, the editor says "Script documentation cache
not found" and `regenerate_script_doc_cache()` starts a thread on the freed
filesystem tree. The result is SIGSEGV or SIGABRT.

It happens once per machine per build change. The crashing run has already
saved the new build's cache, so the next run is clean. That is why it looks
intermittent: CI images, build servers and machines with more than one
Godot build installed hit it on the first run after a switch.

This repo's script and README were written with the help of an AI coding
assistant; the crash, the runs and the results were checked by running them.

## Quick start

```bash
git clone https://github.com/wickmoth/godot-docs-cache-repro.git
cd godot-docs-cache-repro
./run.sh
```

It downloads Godot 4.7.1 and 4.7.2 (about 300 MB) into the repo, runs 5
rounds and prints how many runs crashed. Expect `B with A's docs cache: 5/5`.
Nothing outside the repo folder is touched.

## What the script does

`run.sh` downloads two official Linux x86_64 builds into `./bin`, checks
them against the release's `SHA512-SUMS.txt`, and points all of Godot's
user folders (`XDG_DATA_HOME`, `XDG_CONFIG_HOME`, `XDG_CACHE_HOME`) at
`./godot-user`, so both builds share one cache folder inside this repo and
nothing in your home folder is read or written. Each round, with a fresh
`./godot-user`:

1. build A runs `--headless --import` on `./project` with no docs cache and
   writes its own `editor_doc_cache-4.x.res`;
2. `project/.godot` is removed and build B runs the same import against A's
   cache: **it crashes on exit**;
3. `project/.godot` is removed again and B runs once more, now with its
   own cache: clean.

Godot's self-contained mode (a `._sc_` file next to the binary) gives each
install a cache of its own, which hides the bug, so the script refuses to
run if one is there. The shared user folder is the point.

## Run it

Linux x86_64 only. Needs `bash`, `curl`, `sha512sum` and `unzip` (or
`python3`).

```bash
./run.sh                             # 5 rounds, 4.7.1-stable writes the cache, 4.7.2-stable crashes
./run.sh 5 4.8-beta2 4.8-beta3       # any two release tags of the same minor version
./run.sh 5 4.7.2-stable 4.7.1-stable # either direction
./run.sh 5 4.7.2-stable 4.7.2-stable-mono   # .NET build as B (needs a .NET SDK it can load; not part of the results below)
```

A version is a tag from
[godot-builds releases](https://github.com/godotengine/godot-builds/releases);
`-mono` picks the .NET build. Logs of every run are in `./out`
(`round-N-1-A.log`, `round-N-2-B.log`, `round-N-3-B-again.log`) and the
summary in `./out/report.txt`. `TIMEOUT=seconds` changes the per-run time
limit (default 600). Delete `./bin` when you are done (about 300 MB for two
builds).

There is no Windows script. Godot on Windows takes its user folders from
`APPDATA` and `LOCALAPPDATA` (`OS_Windows::get_config_path()` /
`get_cache_path()`), so the same steps should work there with those two
variables pointed at a shared folder, but this repo has only been run on
Linux.

## Expected output

From `results/4.7.1-to-4.7.2.txt` (NixOS 25.11, Linux 6.12, x86_64,
7 vCPUs, headless):

```
A: 4.7.1.stable.official.a13da4feb  (4.7.1-stable)
B: 4.7.2.stable.official.ed1daf0bf  (4.7.2-stable)
os: Linux 6.12.93 x86_64, NixOS 25.11 (Xantusia)
cpu: 7 x 11th Gen Intel(R) Core(TM) i7-11700K @ 3.60GHz
godot user folders: ./godot-user (XDG_DATA_HOME, XDG_CONFIG_HOME, XDG_CACHE_HOME)
rounds: 5

round 1: A (no cache) exit 0 | B (A's cache editor_doc_cache-4.7.res) exit 134 (CRASHED, signal 6) | B again exit 0
round 2: A (no cache) exit 0 | B (A's cache editor_doc_cache-4.7.res) exit 134 (CRASHED, signal 6) | B again exit 0
round 3: A (no cache) exit 0 | B (A's cache editor_doc_cache-4.7.res) exit 134 (CRASHED, signal 6) | B again exit 0
round 4: A (no cache) exit 0 | B (A's cache editor_doc_cache-4.7.res) exit 134 (CRASHED, signal 6) | B again exit 0
round 5: A (no cache) exit 0 | B (A's cache editor_doc_cache-4.7.res) exit 134 (CRASHED, signal 6) | B again exit 0

crashes / runs
  A with no docs cache:        0/5
  B with A's docs cache:       5/5
  B again, with its own cache: 0/5
logs: ./out
```

The end of B's log in step 2:

```
Script docs haven't been properly loaded or regenerated, so don't save them to disk.
EditorSettings: Save OK!
ERROR: Parameter "singleton" is null.
   at: is_cmdline_mode (editor/editor_node.cpp:6618)
```

followed by SIGABRT here; on other runs and machines it is
`Script documentation cache not found. Regenerating it...` and
`handle_crash: Program crashed with signal 11`.

## Results

| A (writes the cache) | B (runs against it) | B crashes | B again crashes |
|---|---|---|---|
| 4.7.1.stable.official | 4.7.2.stable.official | 5/5 | 0/5 |
| 4.7.2.stable.official | 4.7.1.stable.official | 5/5 | 0/5 |
| 4.8.beta2.official | 4.8.beta3.official | 5/5 | 0/5 |

Build A, starting with no docs cache, crashed 0 times in 15 runs. The full
output of each is in `results/`.
