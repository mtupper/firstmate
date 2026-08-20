#!/usr/bin/env bash
# End-to-end reproduction of the captain's reported defect and its fix.
#
# Shape: a real directory `dgh/` with a compatibility symlink `dev-github -> dgh`
# beside it, exactly like the captain's home. firstmate is entered through the
# ALIAS spelling, and a task is spawned with the relative `projects/demo`
# argument. The durable record under state/<id>.meta is then printed verbatim.
set -u
ROOT_REPO=${1:?worktree path}
cd "$ROOT_REPO" || exit 1
# shellcheck source=/dev/null
. "$ROOT_REPO/tests/lib.sh"

SPAWN="$ROOT_REPO/bin/fm-spawn.sh"
TMP=$(fm_test_tmproot fm-evidence-path-spelling)
TMP=$(cd "$TMP" && pwd -P)

# The captain's home shape: real dgh/, compatibility alias dev-github -> dgh.
CAPTAIN="$TMP/captain"
mkdir -p "$CAPTAIN/dgh"
ln -s dgh "$CAPTAIN/dev-github"

HOME_REAL="$CAPTAIN/dgh/firstmate"
HOME_ALIAS="$CAPTAIN/dev-github/firstmate"
PROJ_REAL="$HOME_REAL/projects/demo"

fakebin=$(fm_fakebin "$TMP/fake")
cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;; esac
case "${1:-}" in display-message) printf 'firstmate\n'; exit 0 ;; esac
exit 0
SH
chmod +x "$fakebin/tmux"
fm_fake_exit0 "$fakebin" treehouse

mkdir -p "$HOME_REAL/data" "$HOME_REAL/projects" "$HOME_REAL/state" "$HOME_REAL/config"
printf 'codex\n' > "$HOME_REAL/config/crew-harness"
fm_git_worktree "$PROJ_REAL" "$TMP/wt" evidence-wt
touch "$HOME_REAL/state/.last-watcher-beat"

spawn_through_alias() {  # <task-id>
  local id=$1
  mkdir -p "$HOME_REAL/data/$id"
  printf 'brief for %s\n' "$id" > "$HOME_REAL/data/$id/brief.md"
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_ALIAS" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_PANE_PATH="$TMP/wt" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "projects/demo" --mode no-mistakes --yolo off >/dev/null 2>&1
}

banner() { printf '\n=== %s ===\n' "$1"; }

banner "the captain's home shape"
ls -l "$CAPTAIN" | sed "s#$TMP#\$TMP#g"
printf '\nfirstmate is entered through the ALIAS spelling:\n  FM_HOME=%s\n' \
  "$(printf '%s' "$HOME_ALIAS" | sed "s#$TMP#\$TMP#")"
printf '  spawn argument: projects/demo\n'

# --- BEFORE: the one-line write-site fix reverted --------------------------
LINE=$(grep -n 'PROJ_ABS="\$(cd "\$(resolve_project_dir_arg "\$PROJ")" && pwd -P)"' "$SPAWN" | cut -d: -f1)
cp "$SPAWN" "$TMP/fm-spawn.sh.keep"
restore() { cp "$TMP/fm-spawn.sh.keep" "$SPAWN"; }
trap restore EXIT
sed -i '' "${LINE}s/pwd -P/pwd/" "$SPAWN"
banner "BEFORE the fix (bin/fm-spawn.sh line $LINE reverted to a logical \`pwd\`)"
spawn_through_alias evidence-before
printf 'durable record state/evidence-before.meta:\n'
grep -E '^(id|project|worktree)=' "$HOME_REAL/state/evidence-before.meta" | sed "s#$TMP#\$TMP#g"
BEFORE_PROJECT=$(sed -n 's/^project=//p' "$HOME_REAL/state/evidence-before.meta")
printf '\n  -> project= holds the ALIAS spelling "dev-github". This is the defect:\n'
printf '     a session entered through dgh/ writes and reads a different string\n'
printf '     for the same directory, so the two cannot see each other.\n'
restore
trap - EXIT

# --- AFTER: the change as committed ----------------------------------------
banner "AFTER the fix (bin/fm-spawn.sh as committed)"
spawn_through_alias evidence-after
printf 'durable record state/evidence-after.meta:\n'
grep -E '^(id|project|worktree)=' "$HOME_REAL/state/evidence-after.meta" | sed "s#$TMP#\$TMP#g"
AFTER_PROJECT=$(sed -n 's/^project=//p' "$HOME_REAL/state/evidence-after.meta")
printf '\n  -> project= holds the resolved physical path "dgh". One directory,\n'
printf '     one spelling, whichever way firstmate was entered.\n'

banner "acceptance criterion 3: the old alias record is still readable"
# shellcheck source=/dev/null
. "$ROOT_REPO/bin/fm-wake-lib.sh"
printf 'record written before the change:  %s\n' "$(printf '%s' "$BEFORE_PROJECT" | sed "s#$TMP#\$TMP#")"
printf 'live physical spelling:            %s\n' "$(printf '%s' "$AFTER_PROJECT" | sed "s#$TMP#\$TMP#")"
if [ -d "$BEFORE_PROJECT" ]; then
  printf 'the alias record still names a real directory:      yes\n'
else
  printf 'the alias record still names a real directory:      NO\n'
fi
if fm_same_path "$BEFORE_PROJECT" "$AFTER_PROJECT"; then
  printf 'fm_same_path(old record, live path):                match\n'
else
  printf 'fm_same_path(old record, live path):                MISMATCH\n'
fi
mkdir -p "$CAPTAIN/dgl"
if fm_same_path "$CAPTAIN/dgh" "$CAPTAIN/dgl"; then
  printf 'two genuinely different real directories compare equal:  YES (wrong)\n'
else
  printf 'two genuinely different real directories stay distinct:  confirmed\n'
fi
printf '\n  -> a fleet already running under the old spelling keeps matching;\n'
printf '     nothing on disk needed rewriting.\n\n'
