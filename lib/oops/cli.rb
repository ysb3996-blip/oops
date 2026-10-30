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

    def self.run(argv, env: ENV, stdin: $stdin, stdout: $stdout, stderr: $stderr)
      case argv.first
      when "record" then return record(argv.drop(1), env: env, stdin: stdin, stdout: stdout, stderr: stderr)
      when "init" then return init(argv.drop(1), stdout: stdout, stderr: stderr)
      when "doctor" then return doctor(argv.drop(1), env: env, stdin: stdin, stdout: stdout)
      when "pause", "resume" then return toggle(argv.first, argv.drop(1), env: env, stdout: stdout)
      end

      options = { head: nil, tail: nil, github: false, show_secrets: false }
      parser = OptionParser.new do |o|
        o.banner = "Usage: oops [N | err] [options]\n       oops init <shell> | pause | resume | doctor"
        o.on("--github", "Format for a GitHub issue or PR comment") { options[:github] = true }
        o.on("--tail N", "Keep only the last N output lines") { |v| options[:tail] = positive(v, "--tail") }
        o.on("--head N", "Keep only the first N output lines") { |v| options[:head] = positive(v, "--head") }
        o.on("--show-secrets", "Do not mask secrets or apply the replace table") { options[:show_secrets] = true }
        o.on("-v", "--version", "Print version and exit") do
          stdout.puts "oops #{VERSION}"
          return 0
        end
        o.on("-h", "--help", "Print this help and exit") do
          stdout.puts o
          return 0
        end
      end
      copy(target(parser.parse(argv)), options, env: env, stdout: stdout, stderr: stderr)
    rescue OptionParser::ParseError, UsageError => e
      stderr.puts "oops: #{e.message}"
      2
    rescue Failure => e
      stderr.puts "oops: #{e.message}"
      1
    end

    def self.positive(value, name)
      raise UsageError, "#{name} must be a positive integer" unless value.match?(POSITIVE_INTEGER) && value.to_i >= 1

      value.to_i
    end

    # Positional arguments: none (the last command), N (the last N commands)
    # or "err" (the last failed command). Returns 1, N or :err.
    def self.target(args)
      raise UsageError, "unexpected argument: #{args[1]}" if args.size > 1

      arg = args.first
      return 1 if arg.nil?
      return :err if arg == "err"
      return positive(arg, "N") if arg.match?(/\A[+-]?\d/)

      raise UsageError, "unknown command: #{arg}"
    end

    def self.copy(target, options, env:, stdout:, stderr:)
      log = recording_log(env)
      raise Failure, "recording is paused. Run  oops resume  first." if log.paused?

      config = Config.load(env: env)
      config.warnings.each { |w| stderr.puts "oops: warning: #{w}" }
      records = target == :err ? [log.last_failed].compact : log.last(target)
      raise Failure, (target == :err ? "no failed command found." : "no command found yet.") if records.empty?

      home = env["HOME"].to_s.empty? ? Dir.home : env["HOME"]
      result = Formatter.new(config: config, home: home, **options).format(records)
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

    def self.report_command(command_line)
      first, rest = command_line.to_s.split("\n", 2)
      rest ? "#{first} ..." : first.to_s
    end

    def self.report_counts(result)
      counts = "#{result.lines} lines"
      result.masked_count.positive? ? "#{counts}, #{result.masked_count} secrets masked" : counts
    end

    # The session log of the recorder this shell runs under. Raises Failure
    # when there is none.
    def self.recording_log(env)
      path = env["OOPS_SESSION"].to_s
      return SessionLog.new(path) if !path.empty? && File.file?(path)

      shell, rc = env["SHELL"].to_s.end_with?("bash") ? %w[bash ~/.bashrc] : %w[zsh ~/.zshrc]
      raise Failure, "not recording in this shell. Add  eval \"$(oops init #{shell})\"  " \
                     "to the top of #{rc} and open a new tab."
    end

    # `oops pause` / `oops resume`: the marker goes through the pty to the
    # recorder; the flag file tells `oops` (and `doctor`) the state.
    def self.toggle(name, args, env:, stdout:)
      raise UsageError, "usage: oops #{name}" unless args.empty?

      log = recording_log(env)
      if name == "pause"
        stdout.write Marker.pause
        log.pause!
      else
        log.resume!
        stdout.write Marker.resume
      end
      stdout.flush
      0
    end

    # `oops doctor`: diagnostics on stdout; always exits 0.
    def self.doctor(args, env:, stdin:, stdout:)
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
    def self.record(args, env:, stdin:, stdout:, stderr:)
      args = args.drop(1) if args.first == "--"
      Recorder.new(args, env: env, stdin: stdin, stdout: stdout, stderr: stderr).run
    end

    # `oops init zsh|bash`: prints the snippet for `eval "$(oops init zsh)"`.
    def self.init(args, stdout:, stderr:)
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

    private_class_method :positive, :target, :copy, :report_command, :report_counts, :recording_log, :toggle, :doctor
  end
end
