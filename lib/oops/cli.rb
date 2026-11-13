require "optparse"

module Oops
  module CLI
    # Raised for a usage error; the message is printed after "oops: " and the
    # exit code is 2.
    class UsageError < StandardError; end

    # Raised when the command cannot do its job; exit code 1.
    class Failure < StandardError; end

    NO_CLIPBOARD = "no clipboard tool found (tried pbcopy, wl-copy, xclip, xsel, clip.exe, OSC 52).".freeze
    POSITIVE_INTEGER = /\A\d+\z/
    CopyTarget = Data.define(:count, :failed_only, :pick)
    COUNT_REPEATED = "specify the command count only once (N or -n)".freeze

    # --json has its own shape, so the Markdown formatting options make no
    # sense with it. --gist sends the text somewhere other than -p and --json
    # do, and anyone with a secret gist's URL can read it, so it never carries
    # unmasked secrets.
    CONFLICTS = { json: %i[github time output_only], gist: %i[show_secrets print json] }.freeze
    private_constant :CopyTarget, :COUNT_REPEATED, :CONFLICTS

    def self.run(argv, env: ENV, stdin: $stdin, stdout: $stdout, stderr: $stderr)
      App.new(env: env, stdin: stdin, stdout: stdout, stderr: stderr).run(argv)
    end

    # One run of the oops command. It holds the environment and the standard
    # streams, so the subcommands take only their own arguments.
    class App
      def initialize(env:, stdin:, stdout:, stderr:)
        @env = env
        @stdin = stdin
        @stdout = stdout
        @stderr = stderr
      end

      def run(argv)
        case argv.first
        when "record" then return record(argv.drop(1))
        when "init" then return init(argv.drop(1))
        when "doctor" then return doctor(argv.drop(1))
        when "pause", "resume" then return toggle(argv.first, argv.drop(1))
        when "status" then return status(argv.drop(1))
        when "clear" then return clear(argv.drop(1))
        end

        options = { github: false, show_secrets: false, time: false, output_only: false, print: false,
                    json: false, gist: false }
        count = nil
        parser = OptionParser.new do |o|
          o.banner = "Usage: oops [N | err | pick] [-n N] [options]\n       " \
                     "oops init <shell> | pause | resume | status | clear [--all] | doctor"
          o.on("-n N", "Copy the last N commands (with err, last N failures; with pick, list N)") do |v|
            raise UsageError, COUNT_REPEATED if count

            count = positive(v, "-n")
          end
          o.on("--github", "Format for a GitHub issue or PR comment") { options[:github] = true }
          o.on("--time", "Add the time each command started") { options[:time] = true }
          o.on("--output-only", "Leave out the command line, keep the output") { options[:output_only] = true }
          o.on("--show-secrets", "Do not mask secrets or apply the replace table") { options[:show_secrets] = true }
          o.on("-p", "--print", "Write the text to stdout instead of the clipboard") { options[:print] = true }
          o.on("--json", "Write the commands as JSON to stdout") { options[:json] = true }
          o.on("--gist", "Upload as a secret gist (needs gh) and copy its URL") { options[:gist] = true }
          o.on("-v", "--version", "Print version and exit") do
            stdout.puts "oops #{VERSION}"
            return 0
          end
          o.on("-h", "--help", "Print this help and exit") do
            stdout.puts o
            return 0
          end
        end
        copy_target = target(parser.parse(argv), count: count)
        check_conflicts(options)
        copy(copy_target, options)
      rescue OptionParser::ParseError, UsageError => e
        stderr.puts "oops: #{e.message}"
        2
      rescue Failure => e
        stderr.puts "oops: #{e.message}"
        1
      end

      private

      attr_reader :env, :stdin, :stdout, :stderr

      def positive(value, name)
        raise UsageError, "#{name} must be a positive integer" unless value.match?(POSITIVE_INTEGER) && value.to_i >= 1

        value.to_i
      end

      def check_conflicts(options)
        CONFLICTS.each do |option, others|
          next unless options[option]

          conflict = others.find { |key| options[key] }
          raise UsageError, "--#{option} cannot be combined with #{flag(conflict)}" if conflict
        end
      end

      def flag(key) = "--#{key.to_s.tr('_', '-')}"

      # Count comes from either a positional N or -n N. "err" filters the
      # selection to failed commands; without a count, one command is copied.
      # "pick" lists the last count commands (Picker::COUNT by default) and
      # copies the ones the user chooses.
      def target(args, count:)
        raise UsageError, "unexpected argument: #{args[1]}" if args.size > 1

        arg = args.first
        return CopyTarget.new(count: count || Picker::COUNT, failed_only: false, pick: true) if arg == "pick"
        return CopyTarget.new(count: count || 1, failed_only: arg == "err", pick: false) if arg.nil? || arg == "err"

        raise UsageError, "unknown command: #{arg}" unless arg.match?(/\A[+-]?\d/)
        raise UsageError, COUNT_REPEATED if count

        CopyTarget.new(count: positive(arg, "N"), failed_only: false, pick: false)
      end

      def copy(target, options)
        log = recording_log
        raise Failure, "recording is paused. Run  oops resume  first." if log.paused?

        config = Config.load(env: env)
        config.warnings.each { |w| stderr.puts "oops: warning: #{w}" }
        records = log.last(target.count, failed_only: target.failed_only)
        raise Failure, (target.failed_only ? "no failed command found." : "no command found yet.") if records.empty?

        home = env["HOME"].to_s.empty? ? Dir.home : env["HOME"]
        records = pick(records, config: config, home: home, show_secrets: options[:show_secrets]) if target.pick
        formatter = Formatter.new(config: config, home: home, **options.except(:print, :json, :gist))
        if options[:json]
          stdout.write formatter.json(records)
          return 0
        end

        result = formatter.format(records)
        return gist(result, config: config) if options[:gist]

        if options[:print]
          stdout.write result.text
          return 0
        end

        backend = Clipboard.detect(config.clipboard, env: env)
        raise Failure, NO_CLIPBOARD if backend.nil?

        begin
          backend.copy(result.text)
        rescue Clipboard::Error => e
          raise Failure, e.message
        end
        stdout.puts "copied: $ #{report_command(result.command_line)} (#{report_counts(result)})"
        0
      end

      # `oops pick`: the list and the prompt go to stderr, so `oops pick -p`
      # and `--json` keep stdout for the copied text. The answer is read from
      # stdin, which also lets a script pipe the numbers in.
      def pick(records, config:, home:, show_secrets:)
        lister = Formatter.new(config: config, home: home, show_secrets: show_secrets)
        stderr.puts Picker.menu(records, lister)
        stderr.print "pick> "
        stderr.flush
        answer = stdin.gets
        # A terminal echoes the answer and its newline; piped input does not.
        stderr.puts unless stdin.tty?
        records.values_at(*Picker.parse(answer, records.size).map { |n| n - 1 })
      rescue Picker::Invalid => e
        raise Failure, e.message
      end

      # The gist is made before the clipboard is tried, so a missing or failing
      # clipboard only costs a warning: the URL is on stdout either way.
      def gist(result, config:)
        url = begin
          Gist.create(result.text, description: "oops: $ #{report_command(result.command_line)}", env: env)
        rescue Gist::Error => e
          raise Failure, e.message
        end
        stdout.puts "gist: #{url} (#{report_counts(result)})"
        begin
          backend = Clipboard.detect(config.clipboard, env: env)
          raise Clipboard::Error, NO_CLIPBOARD if backend.nil?

          backend.copy(url)
        rescue Clipboard::Error => e
          stderr.puts "oops: warning: the URL was not copied: #{e.message}"
        end
        0
      end

      def report_command(command_line)
        first, rest = command_line.to_s.split("\n", 2)
        rest ? "#{first} ..." : first.to_s
      end

      def report_counts(result)
        counts = "#{result.lines} lines"
        result.masked_count.positive? ? "#{counts}, #{result.masked_count} secrets masked" : counts
      end

      # The session log of the recorder this shell runs under. Raises Failure
      # when there is none.
      def recording_log
        path = env["OOPS_SESSION"].to_s
        return SessionLog.new(path) if !path.empty? && File.file?(path)

        line, rc = case env["SHELL"].to_s
                   when /bash\z/ then [%(eval "$(oops init bash)"), "~/.bashrc"]
                   when /fish\z/ then ["oops init fish | source", "~/.config/fish/config.fish"]
                   else [%(eval "$(oops init zsh)"), "~/.zshrc"]
                   end
        raise Failure, "not recording in this shell. Add  #{line}  " \
                       "to #{rc} (after whatever puts oops's Ruby on PATH, as early as possible) " \
                       "and open a new tab."
      end

      # `oops pause` / `oops resume`: the marker goes through the pty to the
      # recorder; the flag file tells `oops` (and `doctor`) the state. The
      # recorder only obeys a marker that agrees with the flag file, so the
      # file changes first.
      def toggle(name, args)
        raise UsageError, "usage: oops #{name}" unless args.empty?

        log = recording_log
        if name == "pause"
          log.pause!
          write_marker(Marker.pause)
        else
          log.resume!
          write_marker(Marker.resume)
        end
        0
      end

      # Like the shell hooks, write straight to the recorded terminal: with
      # stdout redirected (`oops pause >/dev/null`) the recorder would never see
      # the marker although the flag file already says "paused". Without a
      # terminal that can be opened, stdout is used.
      def write_marker(marker)
        tty = env["OOPS_TTY"].to_s
        unless tty.empty?
          begin
            return File.open(tty, File::WRONLY | File::NOCTTY) { |io| io.write(marker) }
          rescue SystemCallError, IOError
            nil
          end
        end
        stdout.write marker
        stdout.flush
      end

      # `oops status`: one word on stdout. "recording" exits 0; "paused" and
      # "off" (this shell is not recorded, or its log is gone) exit 1 without a
      # message, so a prompt can call it.
      def status(args)
        unless args.empty?
          stderr.puts "oops: usage: oops status"
          return 2
        end

        path = env["OOPS_SESSION"].to_s
        word = if path.empty? || !File.file?(path) then "off"
               elsif SessionLog.new(path).paused? then "paused"
               else "recording"
               end
        stdout.puts word
        word == "recording" ? 0 : 1
      end

      # `oops clear [--all]`: deletes the logs of closed tabs; with --all, also
      # empties this tab's log. Logs of other open tabs are never touched.
      def clear(args)
        raise UsageError, "usage: oops clear [--all]" unless args.empty? || args == ["--all"]

        log = recording_log if args == ["--all"]
        begin
          removed = SessionLog.clear!(Paths.sessions_dir(env: env))
          stdout.puts "removed #{removed} #{removed == 1 ? 'log' : 'logs'} of closed tabs"
          return 0 unless log

          log.empty!
        rescue SystemCallError => e
          raise Failure, "could not delete the logs: #{e.message}"
        end
        stdout.puts "emptied this tab's log"
        0
      end

      # `oops doctor`: diagnostics on stdout; always exits 0.
      def doctor(args)
        raise UsageError, "usage: oops doctor" unless args.empty?

        config = Config.load(env: env)
        tty = Tty.name(stdin)
        stdout.write Doctor.report(env: env, config: config, sessions_dir: Paths.sessions_dir(env: env), tty: tty)
        0
      rescue StandardError => e
        raise if e.is_a?(UsageError)

        stdout.puts "doctor: #{e.message}"
        0
      end

      # `oops record [--] <shell> [args...]`
      def record(args)
        args = args.drop(1) if args.first == "--"
        Recorder.new(args, env: env, stdin: stdin, stdout: stdout, stderr: stderr).run
      end

      # `oops init zsh|bash|fish`: prints the snippet for `eval "$(oops init zsh)"`.
      def init(args)
        supported = ShellInit::SHELLS.join(", ")
        if args.size != 1
          stderr.puts "oops: usage: oops init <shell> (supported: #{supported})"
          return 2
        end
        unless ShellInit::SHELLS.include?(args.first)
          stderr.puts "oops: unsupported shell: #{args.first} (supported: #{supported})"
          return 2
        end
        stdout.write ShellInit.snippet(args.first, bin: File.expand_path($PROGRAM_NAME))
        0
      end
    end
    private_constant :App
  end
end
