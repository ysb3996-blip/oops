# oops: bash hooks (bash 3.2 or later). Put this line in ~/.bashrc (or
# ~/.bash_profile, if that is where your settings live), after whatever puts
# oops's Ruby on PATH and as early as possible after that:
#
#   eval "$(oops init bash)"
#
# On a terminal that is not recorded yet, the shell is started again under
# `oops record` (a pty relay). Inside the recorded shell the hooks write
# invisible APC markers around every command line:
#
#   ESC _ oops;start;<seq>;<epoch>;<base64 cwd>;<base64 cmd> ESC \
#   ESC _ oops;end;<seq>;<exit> ESC \
#
# "Recorded" means $OOPS_TTY (set by the relay) names this very terminal, so
# shells started from a recorded one on another tty (tmux, GUI terminals)
# get recorded on their own, and `exec bash` on the same tty is not recorded
# twice. Markers go straight to the terminal device: inside `{ ...; } >file`
# the DEBUG trap runs with stdout redirected.
#
# The preexec hook uses the bash-preexec technique (DEBUG trap armed by the
# last PROMPT_COMMAND entry), inlined and reduced to what oops needs.
if [[ $- == *i* ]] && [ -t 0 ] && [ -t 1 ] && [ -z "${OOPS_DISABLE:-}" ] &&
  [ -z "${BASH_EXECUTION_STRING:-}" ]; then
  __oops_bin=__OOPS_BIN__
  __oops_tty=$(tty 2>/dev/null || :)

  # True when bash was started to run a script (`bash -i script`). bash 4+
  # already has the script in $0 while the rc file runs; bash 3.2 still has
  # "bash" there, so look at the shell's own argv.
  __oops_runs_script() {
    local args word skip= after_dashes= found= noglob=
    case ${0##*/} in
      bash | -bash | sh | -sh) ;;
      *) if [ -f "$0" ] && ! [ "$0" -ef "$BASH" ]; then return 0; fi ;;
    esac
    args=$(ps -ww -o args= -p $$ 2>/dev/null) || return 1
    case $args in
      "$0 "*) args=${args#"$0 "} ;;
      *) return 1 ;;
    esac
    case $- in *f*) noglob=1 ;; esac
    set -f
    for word in $args; do
      if [ -n "$after_dashes" ]; then
        found=1
        break
      elif [ -n "$skip" ]; then
        skip=
        continue
      fi
      case $word in
        --rcfile | --init-file | -o | +o | -O | +O) skip=1 ;;
        --) after_dashes=1 ;;
        -* | +*) ;;
        *)
          found=1
          break
          ;;
      esac
    done
    [ -n "$noglob" ] || set +f
    [ -n "$found" ]
  }

  # Without a tty name (tty(1) failed) this terminal cannot be told apart
  # from a recorded one, so the shell is left alone: no restart, no hooks.
  if [ -n "$__oops_tty" ] && [ "${OOPS_TTY:-}" != "$__oops_tty" ]; then
    if __oops_runs_script; then
      : # not a prompt to record; run the script as asked
    elif command -v "$__oops_bin" >/dev/null 2>&1; then
      # execfail: if the exec fails anyway, keep this shell running.
      __oops_execfail=$(shopt -p execfail || :)
      shopt -s execfail
      if shopt -q login_shell; then
        exec "$__oops_bin" record -- "$BASH" -l
      else
        exec "$__oops_bin" record -- "$BASH"
      fi
      eval "$__oops_execfail"
      unset __oops_execfail
    else
      echo "oops: cannot run $__oops_bin; recording disabled" >&2
    fi
  elif [ -n "$__oops_tty" ]; then
    # Our PROMPT_COMMAND entries. Each keeps $? and $_ for the entries after
    # it: a hook returns the status, and `&& __oops_ok "$_"` (run only when
    # it is 0) puts $_ back. A non-zero status inside an && list does not
    # trigger `set -e`.
    __oops_e_pre='__oops_precmd "$_" && __oops_ok "$_"'
    __oops_e_pass='__oops_pass "$_" && __oops_ok "$_"'
    __oops_e_arm='__oops_arm'
    # The DEBUG trap is read and set here, not inside __oops_install: in a
    # function the DEBUG trap reads as unset, and bash puts back the one the
    # function started with when it returns.
    __oops_e_install='__oops_install "$(trap -p DEBUG)" && __oops_ok; [ -z "${__oops_trap:-}" ] || trap -- "$__oops_trap" DEBUG'

    __oops_ok() { return 0; }
    __oops_b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

    # $1: $BASH_COMMAND, the first simple command of the line. The full line
    # is the newest history entry, but only if the history grew since the
    # prompt; otherwise the line was not saved (HISTCONTROL, HISTIGNORE,
    # history off) and the entry belongs to an older command.
    __oops_preexec() {
      local line num
      line=$(HISTTIMEFORMAT='' builtin history 1)
      num=${line#"${line%%[0-9]*}"}
      num=${num%%[!0-9]*}
      if [ -n "$num" ] && [ "$num" != "$__oops_hist" ]; then
        line=${line#*[0-9][* ] }
      else
        line=$1
      fi
      __OOPS_SEQ=$((__OOPS_SEQ + 1))
      __oops_open=$__OOPS_SEQ
      printf '\033_oops;start;%s;%s;%s;%s\033\\' "$__OOPS_SEQ" "$(date +%s)" \
        "$(__oops_b64 "$PWD")" "$(__oops_b64 "${line:0:8192}")" 2>/dev/null >"$__oops_tty" || :
    }

    # The DEBUG trap runs before every simple command; only the first one
    # after a prompt starts a record. $1 is handed back as the status (for a
    # chained trap) and $2 restores $_, which calling a function overwrites.
    # READLINE_LINE is set while a `bind -x` widget (fzf, atuin) runs; such
    # commands are not the user's line. bash 3.2 does not set it, so there a
    # widget's command takes the record of the line typed after it.
    __oops_debug() {
      if [ -n "$__oops_armed" ] && [ -z "${COMP_LINE:-}" ] && [ -z "${READLINE_LINE+x}" ] &&
        [ "${BASH_SUBSHELL:-0}" = 0 ]; then
        case $BASH_COMMAND in
          __oops_precmd*) ;; # empty line: the prompt is drawn again
          *)
            case $__oops_tail in
              *"$BASH_COMMAND"*) ;; # entries after a rewrap, see __oops_wrap
              *)
                __oops_armed=
                __oops_tail=
                __oops_preexec "$BASH_COMMAND"
                ;;
            esac
            ;;
        esac
      fi
      return "$1"
    }

    # First PROMPT_COMMAND entry: $? must be read before anything else runs.
    __oops_precmd() {
      local exit_status=$?
      __oops_armed=
      if [ -n "$__oops_open" ]; then
        printf '\033_oops;end;%s;%s\033\\' "$__oops_open" "$exit_status" 2>/dev/null >"$__oops_tty" || :
        __oops_open=
      fi
      __oops_status=$exit_status
      return "$exit_status"
    }

    # Stands in for an entry of ours that is no longer in its place.
    __oops_pass() { return "${__oops_status:-0}"; }

    __oops_pc_is_array() {
      case $(declare -p PROMPT_COMMAND 2>/dev/null) in
        'declare -a'*) return 0 ;;
      esac
      return 1
    }

    # True when __oops_precmd is the first entry and __oops_arm the last.
    __oops_wrapped() {
      local nl=$'\n' i last=
      case ${PROMPT_COMMAND:-} in
        "$__oops_e_pre$nl"*"$nl$__oops_e_arm") return 0 ;;
      esac
      __oops_pc_is_array || return 1
      case ${PROMPT_COMMAND:-} in "$__oops_e_pre$nl"*) ;; *) return 1 ;; esac
      for i in "${!PROMPT_COMMAND[@]}"; do last=$i; done
      [ "${PROMPT_COMMAND[$last]}" = "$__oops_e_arm" ]
    }

    # Puts __oops_precmd first and __oops_arm last in PROMPT_COMMAND (an
    # array in bash 5.1+); our entries found elsewhere become __oops_pass, so
    # text around them stays valid. $1 is the entry running now: the entries
    # after it still run in this prompt, before __oops_arm, so their text is
    # kept in __oops_tail and skipped by the DEBUG trap.
    __oops_wrap() {
      local cur=$1 nl=$'\n' sep=$' \t\n;' i elem first= seen= tail=
      if __oops_pc_is_array; then
        for i in "${!PROMPT_COMMAND[@]}"; do
          [ -n "$first" ] || first=$i
          elem=${PROMPT_COMMAND[$i]}
          if [ -n "$seen" ]; then
            tail="$tail$nl$elem"
          else
            case $elem in *"$cur"*) seen=1 tail=${elem#*"$cur"} ;; esac
          fi
          elem=${elem//"$__oops_e_install"/"$__oops_e_pass"}
          elem=${elem//"$__oops_e_pre"/"$__oops_e_pass"}
          PROMPT_COMMAND[$i]=${elem//"$__oops_e_arm"/"$__oops_e_pass"}
        done
        PROMPT_COMMAND[$first]="$__oops_e_pre$nl${PROMPT_COMMAND[$first]}"
        PROMPT_COMMAND+=("$__oops_e_arm")
      else
        elem=${PROMPT_COMMAND:-}
        case $elem in *"$cur"*) tail=${elem#*"$cur"} ;; esac
        elem=${elem//"$__oops_e_install"/"$__oops_e_pass"}
        elem=${elem//"$__oops_e_pre"/"$__oops_e_pass"}
        elem=${elem//"$__oops_e_arm"/"$__oops_e_pass"}
        PROMPT_COMMAND="$__oops_e_pre$nl$elem$nl$__oops_e_arm"
      fi
      case $tail in *[!"$sep"]*) __oops_tail=$tail ;; *) __oops_tail= ;; esac
    }

    __oops_history_number() {
      local line
      line=$(HISTTIMEFORMAT='' builtin history 1)
      line=${line#"${line%%[0-9]*}"}
      __oops_hist=${line%%[!0-9]*}
    }

    # Last PROMPT_COMMAND entry: the next simple command is the user's. A
    # sourced rc file may have put entries before or after ours; wrap again.
    __oops_arm() {
      __oops_tail=
      __oops_wrapped || __oops_wrap "$__oops_e_arm"
      __oops_history_number
      __oops_armed=1
      return 0
    }

    # Runs at the first prompt, after the rest of the rc file, so hooks and
    # DEBUG traps set up later in it are kept. $1: `trap -p DEBUG`.
    __oops_install() {
      local prev=$1
      __oops_wrap "$__oops_e_install"
      case $prev in
        *__oops_debug*) __oops_trap= ;;
        '') __oops_trap='__oops_debug 0 "$_"' ;;
        *)
          eval "set -- $prev"
          __oops_trap="__oops_debug \"\$?\" \"\$_\" && __oops_ok \"\$_\"; $3"
          ;;
      esac
      __oops_history_number
      __oops_armed=1
      return 0
    }

    # Once per shell process; sourcing ~/.bashrc again must not redo this.
    if [ -z "${__oops_hooked:-}" ]; then
      __oops_hooked=1
      __oops_open=
      __oops_armed=
      __oops_tail=
      __oops_hist=
      __oops_trap=
      case ${__OOPS_SEQ:-} in '' | *[!0-9]*) __OOPS_SEQ=0 ;; esac
      # Same pid as the shell that set __OOPS_PID: this shell replaced it
      # with `exec`, so that command (still open in the relay) is done.
      if [ "${__OOPS_PID:-}" = "$$" ] && [ "$__OOPS_SEQ" != 0 ]; then
        printf '\033_oops;end;%s;%s\033\\' "$__OOPS_SEQ" 0 2>/dev/null >"$__oops_tty" || :
      fi
      # Exported so a nested shell on this tty continues the numbering.
      export __OOPS_SEQ
      export __OOPS_PID=$$
    fi
    # Again after a sourced rc file replaced PROMPT_COMMAND.
    case ${PROMPT_COMMAND:-} in
      *__oops_precmd* | *__oops_install*) ;;
      *) PROMPT_COMMAND="${PROMPT_COMMAND:-}"$'\n'"$__oops_e_install" ;;
    esac
  fi
  unset -f __oops_runs_script
fi
