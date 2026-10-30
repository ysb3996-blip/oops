require_relative "clipboard"

module Oops
  # `oops doctor`: one `label: value` line per check (spec 7.8). Best effort:
  # it never raises, whatever state the environment is in.
  module Doctor
    module_function

    def report(env:, config:, sessions_dir:, tty:, which: Clipboard::DEFAULT_WHICH)
      lines = []
      lines.concat(recording_lines(env, tty))
      lines << shell_line(env)
      lines << clipboard_line(config, env, which)
      lines << "config: #{config_line(env, config)}"
      lines << sessions_line(sessions_dir)
      lines << "ruby: #{RUBY_VERSION} (#{RUBY_PLATFORM})"
      lines.concat(warnings(env))
      "#{lines.join("\n")}\n"
    end

    def recording_lines(env, tty)
      session = env["OOPS_SESSION"].to_s
      return ["recording: no"] if session.empty?

      lines = []
      state = File.file?(session) ? session : "#{session} - log file missing"
      lines << "recording: yes (#{state})"
      lines << terminal_line(env["OOPS_TTY"].to_s, tty.to_s)
      status = read_status(session)
      lines << "log writable: #{status == 'ok' ? 'yes' : 'no'} (#{status.empty? ? 'no status file' : status})"
      lines << "paused: #{File.exist?("#{session}.paused") ? 'yes' : 'no'}"
      lines
    end

    def terminal_line(recorded, here)
      return "this terminal: recorded" if !here.empty? && recorded == here

      "this terminal: not the recorded tty (this: #{here.empty? ? 'unknown' : here}, " \
        "recorded: #{recorded.empty? ? 'unknown' : recorded})"
    end

    def read_status(session)
      File.read("#{session}.status").strip
    rescue SystemCallError, IOError
      ""
    end

    def shell_line(env)
      shell = File.basename(env["SHELL"].to_s)
      shell = "unknown" if shell.empty?
      version = shell_version(env)
      hooks = env["__OOPS_SEQ"].to_s.empty? ? "missing" : "installed"
      "shell: #{[shell, version].compact.join(' ')}, hooks: #{hooks}"
    end

    def shell_version(env)
      env["ZSH_VERSION"] || env["BASH_VERSION"]
    end

    def clipboard_line(config, env, which)
      backend = Clipboard.detect(config.clipboard, env: env, which: which)
      "clipboard: #{backend.name}"
    rescue StandardError => e
      "clipboard: unknown (#{e.message})"
    end

    def config_line(env, config)
      path = Paths.config_file(env: env)
      state = if config.warnings.any? then config.warnings.join("; ")
              elsif File.file?(path) then "ok"
              else "missing"
              end
      "#{path} (#{state})"
    rescue StandardError => e
      "unknown (#{e.message})"
    end

    # Counts the session logs themselves, not their .status/.paused files.
    def sessions_line(dir)
      return "sessions: 0 logs, 0.0 MB" unless File.directory?(dir)

      logs = Dir.children(dir).map { |n| File.join(dir, n) }.select { |f| f.end_with?(".jsonl") && File.file?(f) }
      bytes = logs.sum { |f| File.size(f) }
      "sessions: #{logs.size} #{logs.size == 1 ? 'log' : 'logs'}, #{format('%.1f', bytes / 1_048_576.0)} MB"
    rescue SystemCallError
      "sessions: unreadable"
    end

    def warnings(env)
      env["SHELL"].to_s.end_with?("bash") ? bash_warnings(env) : []
    rescue StandardError
      []
    end

    def bash_warnings(env)
      home = env["HOME"].to_s.empty? ? Dir.home : env["HOME"]
      rc = File.join(home, ".bashrc")
      return [] unless File.file?(rc)

      lines = after_init_line(File.read(rc).force_encoding(Encoding::UTF_8).scrub)
      out = []
      if lines.any? { |l| sets_debug_trap?(l) }
        out << "warning: ~/.bashrc sets a DEBUG trap, which can replace the oops hook; " \
               "set it before the oops init line or chain it"
      end
      if lines.any? { |l| l.match?(/\A(export\s+)?PROMPT_COMMAND=["']?(?!.*PROMPT_COMMAND)/) }
        out << "warning: ~/.bashrc assigns PROMPT_COMMAND without appending; " \
               "this can drop the oops hook if it runs after the oops init line"
      end
      out
    rescue SystemCallError, IOError
      []
    end

    # The rc lines after the `oops init bash` line, without comments. Settings
    # made before that line are taken over by the snippet, so only later ones
    # can drop the hooks; without an init line there is nothing to check.
    def after_init_line(text)
      lines = text.lines.map { |l| l.strip.sub(/(?:\A|\s+)#.*\z/, "") }
      init = lines.index { |l| l.match?(/oops['"]?\s+init\s+bash\b/) }
      init ? lines.drop(init + 1) : []
    end

    # `trap ... DEBUG` that sets a trap; `trap - DEBUG` (reset), `trap -p`
    # and `trap -l` do not.
    def sets_debug_trap?(line)
      args = line[/\Atrap\s+(.*)/, 1]
      return false if args.nil? || args.match?(/\A-(?:[pl]\b|\s|\z)/)

      args.match?(/\bDEBUG\b/)
    end
  end
end
