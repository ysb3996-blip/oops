# oops: fish hooks. Put this line in ~/.config/fish/config.fish, after
# whatever puts oops's Ruby on PATH and as early as possible after that:
#
#   oops init fish | source
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
# get recorded on their own, and `exec fish` on the same tty is not recorded
# twice. Markers go straight to the terminal device, so a redirected stdout
# never receives them.
# This file is read from a pipe (`| source`), so stdin is not the terminal:
# the checks look at stdout and stderr instead.
if status is-interactive; and test -t 1; and test -t 2; and not set -q OOPS_DISABLE
    and set -g __oops_tty (tty <&2 2>/dev/null)
    set -g __oops_bin __OOPS_BIN__
    if test "$OOPS_TTY" != "$__oops_tty"
        # A failed exec ends fish, so check first; without the binary the
        # shell simply runs unrecorded.
        if command -q $__oops_bin
            set -g __oops_login
            status is-login; and set __oops_login --login
            # Ghostty injects its shell integration through XDG_DATA_DIRS and
            # removes the injection again, so the restarted shell would not
            # get it. Note whether this one has it (its setup function waits
            # for the first prompt), so the restarted shell can load it again.
            set -g __oops_ghostty
            functions -q __ghostty_setup; and set __oops_ghostty 1
            # Restart at the first prompt, not now: `fish -i -c cmd` and
            # `fish -i script.fish` count as interactive here but never show a
            # prompt, so they run their command unrecorded instead of losing it.
            function __oops_restart --on-event fish_prompt
                functions -e __oops_restart
                if test -n "$__oops_ghostty"
                    set -gx __OOPS_GHOSTTY 1
                else
                    set -e __OOPS_GHOSTTY
                end
                exec $__oops_bin record -- (status fish-path) $__oops_login
            end
        else
            echo "oops: cannot run $__oops_bin; recording disabled" >&2
        end
    else
        function __oops_b64
            printf '%s' $argv[1] | base64 | tr -d '\n'
        end

        # $argv[1] is the whole command line, several lines for a block. Very
        # long lines are cut so the marker stays small. A line of spaces runs
        # nothing, and the other shells make no record for it either.
        function __oops_preexec --on-event fish_preexec
            string trim -- $argv[1] | string length -q; or return
            set -gx __OOPS_SEQ (math $__OOPS_SEQ + 1)
            set -g __oops_open $__OOPS_SEQ
            set -l cmd (string sub -l 8192 -- $argv[1] | string collect)
            printf '\e_oops;start;%s;%s;%s;%s\e\\' $__OOPS_SEQ (date +%s) \
                (__oops_b64 $PWD) (__oops_b64 "$cmd") 2>/dev/null >$__oops_tty
        end

        # $status must be read before anything else runs.
        function __oops_postexec --on-event fish_postexec
            set -l exit_status $status
            if test -n "$__oops_open"
                printf '\e_oops;end;%s;%s\e\\' $__oops_open $exit_status 2>/dev/null >$__oops_tty
                set -g __oops_open
            end
        end

        # Once per shell process; sourcing config.fish again must not redo this.
        if not set -q __oops_hooked
            set -g __oops_hooked 1
            set -g __oops_open
            string match -qr '^[0-9]+$' -- "$__OOPS_SEQ"; or set -gx __OOPS_SEQ 0
            # Same pid as the shell that set __OOPS_PID: this shell replaced it
            # with `exec`, so that command (still open in the relay) is done.
            if test "$__OOPS_PID" = "$fish_pid"; and test "$__OOPS_SEQ" != 0
                printf '\e_oops;end;%s;%s\e\\' $__OOPS_SEQ 0 2>/dev/null >$__oops_tty
            end
            # Exported so a nested shell on this tty continues the numbering.
            set -gx __OOPS_SEQ $__OOPS_SEQ
            set -gx __OOPS_PID $fish_pid
            # $version is not exported; oops doctor reads this one.
            set -gx __OOPS_SHELL_VERSION $version
        end

        # The shell this one replaced had Ghostty's integration (see above);
        # load it here too, as Ghostty documents for a manual setup.
        set -l ghostty "$GHOSTTY_RESOURCES_DIR/shell-integration/fish/vendor_conf.d/ghostty-shell-integration.fish"
        if set -q __OOPS_GHOSTTY; and test -n "$GHOSTTY_RESOURCES_DIR"; and test -r $ghostty
            and not functions -q __ghostty_setup
            source $ghostty
        end
    end
end
