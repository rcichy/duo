# Duo is switched on per slot: one git checkout under DUO_HOME, or a multi-repo slot (a directory under DUO_HOME,
# not in git itself, that holds one checkout per repo). Two clones of the same repo are two slots, so each can run
# its own task with or without the review loop. A session belongs to the slot it was started in, even after Claude
# cd's into a sibling repo or into one checkout of a multi-repo slot.
# Every caller must resolve a directory to the same slot: the hooks start from CLAUDE_PROJECT_DIR, but /duo-on,
# /duo-off and /btw run duo-mode.sh as an ordinary Bash command, which does not get CLAUDE_PROJECT_DIR and starts
# from wherever Claude has cd'd to.
# Slot files live in DUO_HOME/.claude/<kind>.d/, outside the checkout, so they never show up in a reviewed diff.
# Sourced by common.sh and duo-mode.sh; defines functions only.

# duo_slot_root <dir> <home> -> the slot containing <dir>: the nearest multi-repo slot above it, else the checkout
# containing it, else <dir> itself. DUO_HOME is never a multi-repo slot, although it holds checkouts too.
duo_slot_root() {
  local root c
  root=$(cd "$1" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null) || root="$1"
  c="$root"
  while case "$c/" in "$2"/?*) true ;; *) false ;; esac; do
    if ! git -C "$c" rev-parse --git-dir >/dev/null 2>&1 && compgen -G "$c/*/.git" >/dev/null; then
      printf '%s' "$c"; return 0
    fi
    c=$(dirname "$c")
  done
  printf '%s' "$root"
}

# duo_slot_file <home> <root> <kind> -> "<home>/.claude/<kind>.d/<slot>"; fails when <root> is not under <home>
#   kind: duo.on (the slot's on switch) | duo-aside (one-turn /btw flag)
duo_slot_file() {
  local home="$1" root="$2" kind="$3" rel
  case "$root/" in "$home"/*) ;; *) return 1 ;; esac
  rel="${root#"$home"}"; rel="${rel#/}"
  [ -n "$rel" ] || rel="_home"          # a session started in DUO_HOME itself
  printf '%s/.claude/%s.d/%s' "$home" "$kind" "${rel//\//__}"
}
