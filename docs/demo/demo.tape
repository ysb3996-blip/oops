# Records docs/demo.gif. Run through docs/demo/record.sh, which prepares the
# demo home directory that this tape expects at /tmp/oops-demo/home.
Output docs/demo.gif

Set Shell bash
Set FontFamily "Menlo"
Set FontSize 22
Set Width 1000
Set Height 600
Set Padding 24
Set TypingSpeed 75ms
Set Theme { "background": "#2B2B2B", "foreground": "#FFFFFF", "cursor": "#FFFFFF", "green": "#9FE6A0", "red": "#FF8A80", "black": "#2B2B2B", "brightBlack": "#6B6B6B" }

Env HOME "/tmp/oops-demo/home"
Env OOPS_SESSION ""
Env OOPS_TTY ""
Env SHELL "/bin/bash"

Hide
# vhs starts bash without rc files, so the demo profile is loaded by hand.
# The oops snippet in it restarts the shell under `oops record`.
Type ". ~/.bash_profile" Enter
Sleep 2.5s
Type "cd ~/app && clear" Enter
Sleep 1s
Show

Type "ruby test_user.rb --seed 7" Sleep 500ms Enter
Sleep 2.5s
Type "oops" Sleep 500ms Enter
Sleep 2.5s
Type "# what oops put on the clipboard:" Sleep 500ms Enter
Sleep 800ms
Type "pbpaste" Sleep 500ms Enter
Sleep 4.5s

Type "clear" Enter
Sleep 500ms
Type "cat .env" Sleep 500ms Enter
Sleep 2.5s
Type "oops" Sleep 500ms Enter
Sleep 2.5s
Type "# what oops put on the clipboard:" Sleep 500ms Enter
Sleep 800ms
Type "pbpaste" Sleep 500ms Enter
Sleep 4.5s
