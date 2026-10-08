#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
WPE="$ROOT/wpe.sh"

bash -n "$WPE"

# The help menu must include every command in the header.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/bin/linux-wallpaperengine"
chmod +x "$tmp/bin/linux-wallpaperengine"
help=$(PATH="$tmp/bin:$PATH" "$WPE" invalid 2>&1 || true)
for command in list apply stop disable enable toggle restore restack; do
  grep -Fq "wpe.sh $command" <<<"$help"
done

export XDG_STATE_HOME="$tmp/state"
export XDG_CONFIG_HOME="$tmp/config"
export HOME="$tmp/home"
mkdir -p "$HOME"

source <(sed '/^if ! command -v linux-wallpaperengine/,$d' "$WPE")

# Unit-test state transitions without starting a real renderer.
stop_all() { :; }
launch() { :; }
wait_healthy() { return 0; }
connected_monitors() { printf '%s\n' DP-1; }

project="$tmp/project"
mkdir -p "$project"
printf '{"title":"Test wallpaper","type":"video","file":"test.mp4"}\n' > "$project/project.json"
touch "$project/test.mp4"

printf '{"DP-1":"%s"}\n' "$project" | write_state
cmd_disable >/dev/null
test -f "$DISABLED_FILE"
test "$(cat "$STATE_FILE")" = "{\"DP-1\":\"$project\"}"

list=$(PATH="$tmp/bin:$PATH" "$WPE" list)
jq -e '.disabled == true' <<<"$list" >/dev/null

cmd_enable >/dev/null
test ! -e "$DISABLED_FILE"
cmd_disable >/dev/null
cmd_toggle >/dev/null
test ! -e "$DISABLED_FILE"
cmd_toggle >/dev/null
test -f "$DISABLED_FILE"

# Selecting a wallpaper in the picker while disabled must re-enable WPE.
cmd_apply "$project" DP-1
test ! -e "$DISABLED_FILE"
jq -e --arg dir "$project" '."DP-1" == $dir' "$STATE_FILE" >/dev/null

printf 'wpe-toggle-tests: PASS\n'
