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
      lines.concat(warnings(env, config))
      "#{lines.join("\n")}\n"
    end

    def recording_lines(env, tty)
      session = env["OOPS_SESSION"].to_s
      return ["recording: no"] if session.empty?

      lines = []
      state = File.file?(session) ? session : "#{session} - log file missing"
      lines << "recording: yes (#{state})"
      here = !tty.to_s.empty? && env["OOPS_TTY"].to_s == tty.to_s
      lines << "this terminal: #{here ? 'recorded' : 'not the recorded tty'}"
      status = read_status(session)
      lines << "log writable: #{status == 'ok' ? 'yes' : 'no'} (#{status.empty? ? 'no status file' : status})"
      lines << "paused: #{File.exist?("#{session}.paused") ? 'yes' : 'no'}"
      lines
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

    def sessions_line(dir)
      files = Dir.glob(File.join(dir, "*")).select { |f| File.file?(f) }
      bytes = files.sum { |f| File.size(f) }
      "sessions: #{files.size} files, #{format('%.1f', bytes / 1_048_576.0)} MB"
    rescue SystemCallError
      "sessions: unreadable"
    end

    def warnings(env, config)
      out = []
      if config.clipboard == "true"
        out << "warning: config clipboard is \"true\", which runs `sh -c true` and copies nothing; " \
               "use \"auto\" or a clipboard command"
      end
      out.concat(bash_warnings(env)) if env["SHELL"].to_s.end_with?("bash")
      out
    rescue StandardError
      out || []
    end

    def bash_warnings(env)
      home = env["HOME"].to_s.empty? ? Dir.home : env["HOME"]
      rc = File.join(home, ".bashrc")
      return [] unless File.file?(rc)

      text = File.read(rc).force_encoding(Encoding::UTF_8).scrub
      lines = text.lines.map(&:strip).reject { |l| l.start_with?("#") }
      out = []
      if lines.any? { |l| l.match?(/\Atrap\b.*\bDEBUG\b/) }
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
  end
end
