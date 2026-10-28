# oops: bash hooks (bash 3.2 or later). Put this line at the top of ~/.bashrc
# (or ~/.bash_profile, if that is where your settings live):
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
if [[ $- == *i* ]] && [ -t 0 ] && [ -t 1 ] && [ -z "${OOPS_DISABLE:-}" ]; then
  __oops_bin=__OOPS_BIN__
  __oops_tty=$(tty 2>/dev/null)
  if [ "${OOPS_TTY:-}" != "$__oops_tty" ]; then
    if command -v "$__oops_bin" >/dev/null 2>&1; then
      # execfail: if the exec fails anyway, keep this shell running.
      __oops_execfail=$(shopt -p execfail)
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
    __oops_b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

    # $1: $BASH_COMMAND, the first simple command of the line. The full line
    # comes from the history; when the history did not grow (HISTCONTROL,
    # HISTIGNORE, history off) the last entry is only used if it still
    # contains $1, e.g. a repeated line under ignoredups.
    __oops_preexec() {
      local line num
      line=$(HISTTIMEFORMAT='' builtin history 1)
      num=${line#"${line%%[0-9]*}"}
      num=${num%%[!0-9]*}
      line=${line#*[0-9][* ] }
      if [ "$num" = "$__oops_hist" ]; then
        case $line in
          *"$1"*) ;;
          *) line=$1 ;;
        esac
      fi
      __oops_hist=$num
      __OOPS_SEQ=$((__OOPS_SEQ + 1))
      __oops_open=$__OOPS_SEQ
      printf '\033_oops;start;%s;%s;%s;%s\033\\' "$__OOPS_SEQ" "$(date +%s)" \
        "$(__oops_b64 "$PWD")" "$(__oops_b64 "${line:0:8192}")" 2>/dev/null >"$__oops_tty"
    }

    # The DEBUG trap runs before every simple command; only the first one
    # after a prompt starts a record. $1 is handed back as the status (for a
    # chained trap) and $2 restores $_, which calling a function overwrites.
    __oops_debug() {
      if [ -n "$__oops_armed" ] && [ -z "${COMP_LINE:-}" ] && [ "${BASH_SUBSHELL:-0}" = 0 ]; then
        case $BASH_COMMAND in
          __oops_precmd) ;; # empty line: the prompt is drawn again
          *)
            case $__oops_tail in
              *"$BASH_COMMAND"*) ;; # rest of the first prompt, see __oops_install
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
        printf '\033_oops;end;%s;%s\033\\' "$__oops_open" "$exit_status" 2>/dev/null >"$__oops_tty"
        __oops_open=
      fi
      __oops_status=$exit_status
      return "$exit_status"
    }

    # Hands the command's status on to the PROMPT_COMMAND entries after it.
    __oops_pass() { return "${__oops_status:-0}"; }

    # Last PROMPT_COMMAND entry: the next simple command is the user's.
    __oops_arm() {
      __oops_armed=1
      __oops_tail=
      return "${__oops_status:-0}"
    }

    # Runs at the first prompt, after the rest of the rc file, so hooks and
    # DEBUG traps set up later in it are kept: our entries go around the
    # PROMPT_COMMAND of that moment and an existing DEBUG trap is chained.
    # The entries after ours still run in this first prompt, before
    # __oops_arm exists, so their text is kept in __oops_tail and skipped.
    # The trap is read and set by the PROMPT_COMMAND entry, not in here:
    # inside a function the DEBUG trap reads as unset, and bash puts back the
    # one the function started with when it returns. $1: `trap -p DEBUG`.
    __oops_install_entry='__oops_install "$(trap -p DEBUG)"; [ -z "$__oops_trap" ] || trap -- "$__oops_trap" DEBUG'
    __oops_install() {
      local exit_status=$? nl=$'\n' sep=$' \t\n;' head tail prev=$1
      head=$PROMPT_COMMAND
      tail=
      case $PROMPT_COMMAND in
        *"$__oops_install_entry"*)
          head=${PROMPT_COMMAND%%"$__oops_install_entry"*}
          tail=${PROMPT_COMMAND#*"$__oops_install_entry"}
          ;;
      esac
      # Our entry becomes __oops_pass, so text around it stays valid.
      if [ "${#PROMPT_COMMAND[@]}" -gt 1 ]; then
        __oops_tail="$tail$nl${PROMPT_COMMAND[*]:1}"
        PROMPT_COMMAND[0]="__oops_precmd$nl${head}__oops_pass$tail"
        PROMPT_COMMAND+=(__oops_arm)
      else
        __oops_tail=$tail
        PROMPT_COMMAND="__oops_precmd$nl${head}__oops_pass$tail${nl}__oops_arm"
      fi
      case $__oops_tail in *[!"$sep"]*) ;; *) __oops_tail= ;; esac
      case $prev in
        *__oops_debug*) __oops_trap= ;;
        '') __oops_trap='__oops_debug 0 "$_"' ;;
        *)
          eval "set -- $prev"
          __oops_trap="__oops_debug \"\$?\" \"\$_\"; $3"
          ;;
      esac
      __oops_hist=$(HISTTIMEFORMAT='' builtin history 1)
      __oops_hist=${__oops_hist#"${__oops_hist%%[0-9]*}"}
      __oops_hist=${__oops_hist%%[!0-9]*}
      __oops_status=$exit_status
      __oops_armed=1
      return "$exit_status"
    }

    # Once per shell process; sourcing ~/.bashrc again must not redo this.
    if [ -z "${__oops_hooked:-}" ]; then
      __oops_hooked=1
      __oops_open=
      __oops_armed=
      case ${__OOPS_SEQ:-} in '' | *[!0-9]*) __OOPS_SEQ=0 ;; esac
      # Same pid as the shell that set __OOPS_PID: this shell replaced it
      # with `exec`, so that command (still open in the relay) is done.
      if [ "${__OOPS_PID:-}" = "$$" ] && [ "$__OOPS_SEQ" != 0 ]; then
        printf '\033_oops;end;%s;%s\033\\' "$__OOPS_SEQ" 0 2>/dev/null >"$__oops_tty"
      fi
      # Exported so a nested shell on this tty continues the numbering.
      export __OOPS_SEQ
      export __OOPS_PID=$$
      __oops_tail=
    fi
    # Again after a sourced rc file replaced PROMPT_COMMAND.
    case ${PROMPT_COMMAND:-} in
      *__oops_precmd* | *__oops_install*) ;;
      *) PROMPT_COMMAND="${PROMPT_COMMAND:-}"$'\n'"$__oops_install_entry" ;;
    esac
  fi
fi
