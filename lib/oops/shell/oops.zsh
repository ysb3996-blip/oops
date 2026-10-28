# oops: zsh hooks. Put this line at the top of ~/.zshrc:
#
#   eval "$(oops init zsh)"
#
# On a terminal that is not recorded yet, the shell is started again under
# `oops record` (a pty relay). Inside the recorded shell the hooks write
# invisible APC markers around every command:
#
#   ESC _ oops;start;<seq>;<epoch>;<base64 cwd>;<base64 cmd> ESC \
#   ESC _ oops;end;<seq>;<exit> ESC \
#
# "Recorded" means $OOPS_TTY (set by the relay) names this very terminal, so
# shells started from a recorded one on another tty (tmux, GUI terminals)
# get recorded on their own, and `exec zsh` on the same tty is not recorded
# twice. Markers go straight to the terminal device, so a redirected stdout
# never receives them.
# `zsh -ic 'cmd'` and `zsh -i script` are left alone so the command runs.
if [[ -o interactive && -t 0 && -t 1 && -n "${TTY:-}" && -z "${OOPS_DISABLE:-}" &&
      -z "${ZSH_EXECUTION_STRING:-}" && -z "${ZSH_SCRIPT:-}" ]]; then
  __oops_bin=__OOPS_BIN__
  if [[ "${OOPS_TTY:-}" != "$TTY" ]]; then
    # A failed exec ends zsh, so check first; without the binary the shell
    # simply runs unrecorded.
    if command -v "$__oops_bin" >/dev/null 2>&1; then
      exec "$__oops_bin" record -- "${${ZSH_ARGZERO#-}:-zsh}"
    else
      print -ru2 -- "oops: cannot run $__oops_bin; recording disabled"
    fi
  else
    zmodload zsh/datetime 2>/dev/null
    autoload -Uz add-zsh-hook

    # The ";" before "}" keeps this valid with IGNORE_CLOSE_BRACES.
    __oops_b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

    # $1 is the line as typed (empty if history is off; $3 is the full text
    # that runs). Very long lines are cut so the marker stays small.
    __oops_preexec() {
      emulate -L zsh
      local cmd=${1:-$3}
      __OOPS_SEQ=$(( __OOPS_SEQ + 1 ))
      __oops_open=$__OOPS_SEQ
      printf '\033_oops;start;%s;%s;%s;%s\033\\' "$__OOPS_SEQ" "${EPOCHSECONDS:-$(date +%s)}" \
        "$(__oops_b64 "$PWD")" "$(__oops_b64 "${cmd[1,8192]}")" 2>/dev/null >"$TTY"
    }

    # $? must be read before anything else runs; it is handed back unchanged.
    __oops_precmd() {
      local exit_status=$?
      emulate -L zsh
      if [[ -n "$__oops_open" ]]; then
        printf '\033_oops;end;%s;%s\033\\' "$__oops_open" "$exit_status" 2>/dev/null >"$TTY"
        __oops_open=
      fi
      return $exit_status
    }

    # Once per shell process; sourcing ~/.zshrc again must not redo this.
    if [[ -z "${__oops_hooked:-}" ]]; then
      __oops_hooked=1
      __oops_open=
      case "${__OOPS_SEQ:-}" in ('' | *[!0-9]*) __OOPS_SEQ=0 ;; esac
      # Same pid as the shell that set __OOPS_PID: this shell replaced it
      # with `exec`, so that command (still open in the relay) is done.
      if [[ "${__OOPS_PID:-}" == "$$" && "$__OOPS_SEQ" != 0 ]]; then
        printf '\033_oops;end;%s;%s\033\\' "$__OOPS_SEQ" 0 2>/dev/null >"$TTY"
      fi
      # Exported so a nested shell on this tty continues the numbering.
      export __OOPS_SEQ
      export __OOPS_PID=$$
    fi
    add-zsh-hook preexec __oops_preexec
    add-zsh-hook precmd __oops_precmd
  fi
fi
