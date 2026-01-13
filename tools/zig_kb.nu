#!/usr/bin/env nu
let kb = (pwd | path join "zig-kb")
mkdir $kb | ignore

let zig_where = (do -i { ^where.exe zig } | str trim)
let zig_version = (do -i { ^zig version } | str trim)
let zig_env_raw = (do -i { ^zig env } | str trim)

let zig_exe = ($zig_env_raw | parse -r '.*\.zig_exe\s*=\s*"(?P<path>[^"]+)".*' | get 0.path)
let lib_dir = ($zig_env_raw | parse -r '.*\.lib_dir\s*=\s*"(?P<path>[^"]+)".*' | get 0.path)
let std_dir = ($zig_env_raw | parse -r '.*\.std_dir\s*=\s*"(?P<path>[^"]+)".*' | get 0.path)

let std_checks = [
  "json.zig" "json" "http.zig" "http" "http/Client.zig" "Uri.zig" "net.zig" "io.zig" "fs.zig" "crypto.zig" "base64.zig" "time.zig" "Thread.zig" "process.zig"
] | each {|p| { path: $p, exists: (([$std_dir $p] | path join) | path exists) }}

let dl_index = (http get https://ziglang.org/download/index.json)
let v0152 = ($dl_index | get "0.15.2"? | default {})

# Skip GitHub API (rate-limited); note manually
let utcp_file_note = "GitHub API rate-limited; manually check: lib/std/http, lib/std/json, lib/std/net, lib/std/Uri for changes in 0.15.1..0.15.2"

# build simple markdown files
["# Zig installation + stdlib access" ""
 "## Zig on PATH" ("```text" + (char nl) + $zig_where + (char nl) + "```") ""
 "## Zig version" ("```text" + (char nl) + $zig_version + (char nl) + "```") ""
 ("zig_exe: " + $zig_exe) ("lib_dir: " + $lib_dir) ("std_dir: " + $std_dir) ""
 "Run: zig std"
] | str join (char nl) | save -f ($kb | path join "zig-install.md")

["# Stdlib map" "" ("std_dir: " + $std_dir) "" "| path | exists |" "|---|---|"
 ($std_checks | each {|r| ("| " + $r.path + " | " + ($r.exists | into string) + " |")} | str join (char nl))
] | str join (char nl) | save -f ($kb | path join "stdlib-map.md")

["# Zig 0.15.2 deltas" "" $utcp_file_note
 "" "Use std.json, std.http.Client, std.net for UTCP."
] | str join (char nl) | save -f ($kb | path join "zig-0.15-utcp-deltas.md")

let scoop_st = (do -i { ^scoop status } | str trim)
let cargo_li = (do -i { ^cargo install --list } | str trim)
["# Tools" "" "scoop:" $scoop_st "" "cargo:" $cargo_li
] | str join (char nl) | save -f ($kb | path join "tooling.md")

("Wrote KB to: " + $kb)
