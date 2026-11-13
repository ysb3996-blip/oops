# oops: fish plugin file, for fisher (`fisher install ysb3996-blip/oops`) and
# other managers that copy conf.d files. Only this file is copied, so oops
# itself must be installed (the oops-cli gem, or Homebrew).
#
# conf.d files run before config.fish, which is where mise, rbenv, asdf and
# `brew shellenv` usually put oops's Ruby on PATH, so nothing is loaded now:
# the init snippet is loaded at the first prompt, when config.fish is done.
if status is-interactive; and not functions -q __oops_plugin_load
    function __oops_plugin_load --on-event fish_prompt
        functions -e __oops_plugin_load
        # An `oops init fish | source` line in config.fish already did it.
        functions -q __oops_preexec; or functions -q __oops_restart; and return
        if not command -q oops
            echo "oops: the oops command was not found; install the oops-cli gem or the Homebrew formula (recording disabled)" >&2
            return
        end
        set -l ghostty_loaded (functions -q __ghostty_setup; and echo 1)
        oops init fish | source
        # Handlers defined while fish_prompt is being handled fire only from
        # the next prompt, so run the ones this prompt needs now.
        functions -q __oops_restart; and __oops_restart
        if test -z "$ghostty_loaded"; and functions -q __ghostty_setup
            __ghostty_setup
        end
    end
end
