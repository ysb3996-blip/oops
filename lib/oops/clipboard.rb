require "tempfile"

module Oops
  # Clipboard backends and detection of the best one for this environment.
  module Clipboard
    class Error < StandardError; end

    # Seconds to wait for a clipboard command before giving up.
    TIMEOUT = 5
    # The wait polls for the command's exit: it starts with short sleeps (the
    # command usually finishes within a few milliseconds) and doubles up to
    # POLL_MAX.
    POLL_MIN = 0.001
    POLL_MAX = 0.01
    # Bytes of a failing command's stderr kept in the error message.
    MAX_STDERR = 2048

    # Shared process handling: text goes in through a temp file on stdin and
    # output goes to temp files, so a daemonized child (xclip, wl-copy) that
    # keeps inheriting those descriptors can never block us. We only wait for
    # the direct child; on a timeout its whole process group is killed.
    module Runner
      module_function

      def run(label, argv, text, timeout: TIMEOUT)
        Tempfile.create("oops-in", binmode: true) do |input|
          Tempfile.create("oops-err", binmode: true) do |err|
            input.write(text)
            input.flush
            input.rewind
            status = spawn_and_wait(label, argv, input, err, timeout)
            next if status.success?

            raise Error, "#{label} failed (#{describe(status)}): #{read_head(err)}"
          end
        end
      rescue SystemCallError, IOError => e
        raise Error, "#{label}: #{e.message}"
      end

      def spawn_and_wait(label, argv, input, err, timeout)
        pid = Process.spawn(*argv, in: input, out: File::NULL, err: err, pgroup: true)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        delay = POLL_MIN
        loop do
          _, status = Process.wait2(pid, Process::WNOHANG)
          return status if status

          if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
            kill_group(pid)
            raise Error, "#{label} timed out after #{timeout}s"
          end
          sleep delay
          delay = [delay * 2, POLL_MAX].min
        end
      end

      # The child leads its own process group, so this also ends anything it
      # started that is still running.
      def kill_group(pid)
        begin
          Process.kill("KILL", -pid)
        rescue SystemCallError
          Process.kill("KILL", pid)
        end
        Process.wait(pid)
      rescue SystemCallError
        nil
      end

      def describe(status)
        return "exit #{status.exitstatus}" if status.exited?
        return "killed by SIG#{Signal.signame(status.termsig)}" if status.signaled?

        status.to_s
      end

      def read_head(file)
        file.rewind
        head = file.read(MAX_STDERR + 1).to_s
        more = head.bytesize > MAX_STDERR
        text = head.byteslice(0, MAX_STDERR).force_encoding(Encoding::UTF_8).scrub.strip
        more ? "#{text} ..." : text
      end
    end

    # Runs an argv with the text on stdin.
    class Command
      attr_reader :name

      def initialize(name, argv, encoding: nil)
        @name = name
        @argv = argv
        @encoding = encoding
      end

      def copy(text)
        text = text.dup.force_encoding(Encoding::UTF_8).scrub.encode(@encoding) if @encoding
        Runner.run(@name, @argv, text)
      end
    end

    # Runs a user supplied command line through sh -c.
    class Shell
      attr_reader :name

      def initialize(cmdline)
        @cmdline = cmdline
        @name = cmdline.to_s.split.first || cmdline.to_s
      end

      def copy(text)
        Runner.run(@name, ["sh", "-c", @cmdline], text)
      end
    end

    # Writes an OSC 52 escape sequence to the terminal.
    class Osc52
      WARNING = "oops: warning: clipboard text truncated to fit OSC 52 limit".freeze

      def initialize(tty: "/dev/tty", max_bytes: 100_000)
        @tty = tty
        @max_bytes = max_bytes
      end

      def name = "osc52"

      def copy(text)
        payload = [fit(text.b)].pack("m0")
        write("\e]52;c;#{payload}\a")
      end

      private

      # Keeps the tail of the bytes so the base64 form fits max_bytes, never
      # starting in the middle of a UTF-8 character.
      def fit(bytes)
        limit = @max_bytes / 4 * 3
        return bytes if bytes.bytesize <= limit

        warn WARNING
        start = bytes.bytesize - limit
        start += 1 while start < bytes.bytesize && (bytes.getbyte(start) & 0xC0) == 0x80
        bytes.byteslice(start..)
      end

      # One write(2) where possible, so the sequence is not split up between
      # other output.
      def write(data)
        if @tty.respond_to?(:syswrite)
          write_all(@tty, data)
        else
          File.open(@tty, "wb") { |f| write_all(f, data) }
        end
      rescue SystemCallError, IOError => e
        raise Error, "osc52: cannot write to #{@tty.respond_to?(:syswrite) ? 'tty' : @tty}: #{e.message}"
      end

      def write_all(io, data)
        data = data.b
        until data.empty?
          written = io.syswrite(data)
          data = data.byteslice(written..)
        end
      end
    end

    KNOWN = {
      "pbcopy" => ["pbcopy"],
      "wl-copy" => ["wl-copy"],
      "xclip" => ["xclip", "-selection", "clipboard"],
      "xsel" => ["xsel", "--clipboard", "--input"],
      "clip.exe" => ["clip.exe"]
    }.freeze

    DEFAULT_WHICH = ->(cmd) { system("command -v #{cmd} >/dev/null 2>&1") }

    module_function

    def command_backend(name)
      Command.new(name, KNOWN.fetch(name), encoding: (name == "clip.exe" ? "UTF-16LE" : nil))
    end

    def detect(setting, env: ENV, which: DEFAULT_WHICH, platform: RUBY_PLATFORM, proc_version: nil)
      setting = setting.to_s.strip
      setting = "auto" if setting.empty? || %w[true false].include?(setting)
      return explicit(setting) unless setting == "auto"

      auto(env, which, platform, proc_version)
    end

    def explicit(setting)
      return Osc52.new if setting == "osc52"
      return command_backend(setting) if KNOWN.key?(setting)

      Shell.new(setting)
    end

    def auto(env, which, platform, proc_version)
      return Osc52.new unless env["SSH_TTY"].to_s.empty?
      return command_backend("pbcopy") if platform.include?("darwin") && which.call("pbcopy")
      return command_backend("clip.exe") if wsl?(proc_version) && which.call("clip.exe")
      return command_backend("wl-copy") if !env["WAYLAND_DISPLAY"].to_s.empty? && which.call("wl-copy")

      unless env["DISPLAY"].to_s.empty?
        %w[xclip xsel].each { |n| return command_backend(n) if which.call(n) }
      end
      Osc52.new
    end

    def wsl?(proc_version)
      proc_version ||= File.exist?("/proc/version") ? File.read("/proc/version") : ""
      proc_version.match?(/microsoft/i)
    rescue SystemCallError, IOError
      false
    end
  end
end
