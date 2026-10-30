require "pty"
require "io/console"

module Oops
  # The pty relay behind `oops record`: runs the shell on a new pty, relays
  # input and output between it and the user's terminal, strips the hook
  # markers from the output and writes finished commands to the session log.
  #
  # Rule one is never to break the user's shell. Failing to set up the log
  # only disables recording; any failure after the shell is running switches
  # logging off and the relay goes on.
  class Recorder
    READ_SIZE = 65_536
    # Input waiting for the shell beyond this stays in the kernel's tty
    # buffer (it is not read) until the shell catches up.
    MAX_PENDING_INPUT = 1_048_576
    # Backstop for a missed SIGCHLD; normally the self-pipe wakes the loop.
    POLL_INTERVAL = 1.0

    # The shell could not be started on the new pty.
    class ChildStartError < StandardError; end

    # Feeds child output through the StreamParser and appends records to the
    # log. Failures never lose output: a failing log is dropped, and if the
    # parser itself fails, bytes are forwarded unparsed from then on.
    class OutputFilter
      def initialize(log:, on_error:, max_bytes: 1_048_576)
        @log = log
        @on_error = on_error
        @parser = StreamParser.new(max_bytes: max_bytes) { |record| store(record) }
        @broken = false
      end

      # Returns the bytes to show on the terminal.
      def feed(bytes)
        return bytes.b if @broken

        @parser.feed(bytes)
      rescue StandardError => e
        parser_failed(e)
        bytes.b
      end

      # Returns held-back bytes; an unfinished command is logged with exit nil.
      def finish
        return "".b if @broken

        @parser.finish
      rescue StandardError => e
        parser_failed(e)
        "".b
      end

      private

      def store(record)
        return unless @log

        @log.append(record)
      rescue StandardError => e
        @log = nil
        @on_error.call(e.message)
      end

      def parser_failed(error)
        @broken = true
        @log = nil
        @on_error.call("stream parser failed: #{error.class}: #{error.message}")
      end
    end

    def initialize(argv, env: ENV, stdin: $stdin, stdout: $stdout, stderr: $stderr)
      @argv = argv.empty? ? [default_shell(env)] : argv
      @env = env
      @stdin = stdin
      @stdout = stdout
      @stderr = stderr
      @raw = false
      @log_failed = false
    end

    def run
      tty = Tty.name(@stdin)
      return exec_shell({}) if tty && @env["OOPS_TTY"] == tty

      install_traps
      log = open_session
      master, pid = start_child
      unless pid
        discard_session
        return exec_shell({ "OOPS_DISABLE" => "1" })
      end

      @master = master
      @pid = pid
      @filter = OutputFilter.new(log: log, on_error: method(:log_failed))
      with_raw_mode { relay }
    ensure
      restore_traps
      @master.close if @master && !@master.closed?
      @wake_r&.close
      @wake_w&.close
    end

    private

    def default_shell(env)
      shell = env["SHELL"].to_s
      shell.empty? ? "/bin/sh" : shell
    end

    # Replaces this process with the shell. Returns only when exec fails.
    def exec_shell(extra_env)
      Kernel.exec(extra_env, [@argv[0], @argv[0]], *@argv[1..])
    rescue SystemCallError => e
      @stderr.puts "oops: cannot run #{@argv[0]}: #{e.message}"
      127
    end

    # --- session log ---

    def open_session
      dir = Paths.sessions_dir(env: @env)
      @session_path = SessionLog.new_path(dir)
      Paths.ensure_sessions_dir!(env: @env)
      rotate_logs(dir)
      File.open(@session_path, File::WRONLY | File::CREAT | File::APPEND, 0o600, &:itself)
      write_status("ok")
      SessionLog.new(@session_path)
    rescue StandardError => e
      @log_failed = true
      warn_line "oops: warning: session log unavailable (#{e.message}); recording disabled"
      write_status("log-error: #{e.message}")
      nil
    end

    # The shell runs unrecorded, so an empty log would only mislead.
    def discard_session
      return unless @session_path

      [@session_path, "#{@session_path}.status"].each do |f|
        File.delete(f)
      rescue SystemCallError
        nil
      end
    end

    # Rotation only frees space; failing to rotate must not stop recording.
    def rotate_logs(dir)
      SessionLog.rotate!(dir)
    rescue SystemCallError
      nil
    end

    def write_status(text)
      return unless @session_path && File.directory?(File.dirname(@session_path))

      File.open("#{@session_path}.status", File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |f|
        f.write(text)
      end
    rescue SystemCallError, IOError
      nil
    end

    # Called at most once: the first log failure switches logging off.
    def log_failed(message)
      return if @log_failed

      @log_failed = true
      warn_line "oops: warning: session log write failed (#{message}); recording disabled"
      write_status("log-error: #{message}")
    end

    def warn_line(message)
      @stderr.write(message, @raw ? "\r\n" : "\n")
      @stderr.flush
    rescue SystemCallError, IOError
      nil
    end

    # --- child process ---

    # Returns [master, pid], or nil after printing why the pty or the shell
    # could not be started.
    def start_child
      master, slave = PTY.open
      copy_termios(slave)
      copy_winsize(master)
      [master, fork_child(slave.path)]
    rescue SystemCallError, IOError, NotImplementedError, ChildStartError => e
      master&.close
      @stderr.puts "oops: recording disabled: #{e.message}"
      nil
    ensure
      # Kept open until the child has opened the slave itself, so the pty is
      # never without a slave in between (that would read as a hangup).
      slave&.close
    end

    # Forks the shell as a session leader with the pty slave as its
    # controlling terminal. A close-on-exec pipe reports whether exec
    # succeeded: EOF means it did, otherwise it carries the error.
    def fork_child(slave_path)
      report_r, report_w = IO.pipe
      child_env = { "OOPS_SESSION" => @session_path, "OOPS_TTY" => slave_path }
      pid = fork do
        report_r.close
        begin
          Process.setsid
          File.open(slave_path, File::RDWR) do |tty|
            Kernel.exec(child_env, [@argv[0], @argv[0]], *@argv[1..], in: tty, out: tty, err: tty)
          end
        rescue StandardError => e
          report_w.write("cannot run #{@argv[0]}: #{e.message}")
        ensure
          exit!(127)
        end
      end
      report_w.close
      error = report_r.read
      return pid if error.empty?

      Process.wait(pid)
      raise ChildStartError, error
    ensure
      report_r&.close
      report_w&.close unless report_w.nil? || report_w.closed?
    end

    # The shell starts with the user's terminal settings (erase key, UTF-8
    # input, ...), as script(1) does.
    def copy_termios(slave)
      return unless @stdin.respond_to?(:console_mode) && @stdin.tty?

      slave.console_mode = @stdin.console_mode
    rescue SystemCallError, IOError
      nil
    end

    def copy_winsize(master)
      return unless @stdin.respond_to?(:winsize) && @stdin.tty?

      rows, cols = @stdin.winsize
      master.winsize = [rows, cols] if rows.positive? && cols.positive?
    rescue SystemCallError, IOError
      nil
    end

    # --- signals ---

    def install_traps
      @wake_r, @wake_w = IO.pipe
      wake = @wake_w
      @old_traps = %w[WINCH CHLD].to_h do |sig|
        [sig, trap(sig) { wake.write_nonblock(sig[0], exception: false) }]
      end
    end

    def restore_traps
      @old_traps&.each { |sig, old| trap(sig, old || "DEFAULT") }
    end

    # --- terminal ---

    def with_raw_mode
      return yield unless @stdin.respond_to?(:raw!) && @stdin.tty?

      saved = @stdin.console_mode
      begin
        @stdin.raw!
        @raw = true
        yield
      ensure
        @raw = false
        begin
          @stdin.console_mode = saved
        rescue SystemCallError, IOError
          nil
        end
      end
    end

    # --- relay loop ---

    def relay
      @input = +"".b
      @stdin_open = true
      @output_open = true
      @status = nil
      step while @output_open && @status.nil?
      drain_output if @output_open
      write_terminal(@filter.finish)
      @status ||= Process.wait2(@pid)[1]
      exit_code(@status)
    end

    def step
      readers = [@master, @wake_r]
      readers << @stdin if @stdin_open && @input.bytesize < MAX_PENDING_INPUT
      writers = @input.empty? ? nil : [@master]
      readable, writable = IO.select(readers, writers, nil, POLL_INTERVAL)
      readable ||= []
      handle_wakeup if readable.include?(@wake_r)
      read_input if readable.include?(@stdin)
      write_input if writable&.include?(@master)
      read_output if readable.include?(@master)
      reap_child
    end

    def handle_wakeup
      signals = @wake_r.read_nonblock(READ_SIZE, exception: false)
      copy_winsize(@master) if signals.is_a?(String) && signals.include?("W")
    end

    def read_input
      @input << @stdin.readpartial(READ_SIZE).b
    rescue EOFError, Errno::EIO
      @stdin_open = false
    end

    def write_input
      written = @master.write_nonblock(@input, exception: false)
      @input = @input.byteslice(written..) if written.is_a?(Integer)
    rescue Errno::EIO, Errno::EPIPE
      @input.clear
    end

    def read_output
      data = @master.read_nonblock(READ_SIZE, exception: false)
      return if data == :wait_readable

      data.nil? ? (@output_open = false) : write_terminal(@filter.feed(data))
    rescue Errno::EIO
      # The child side closed the pty: the shell is gone.
      @output_open = false
    end

    # After the shell exited, a background job may still hold the pty open;
    # forward what is already there instead of waiting for it.
    def drain_output
      loop do
        data = @master.read_nonblock(READ_SIZE, exception: false)
        break if data.nil? || data == :wait_readable

        write_terminal(@filter.feed(data))
      end
    rescue Errno::EIO
      nil
    end

    def reap_child
      _, status = Process.wait2(@pid, Process::WNOHANG)
      @status = status if status
    end

    def write_terminal(bytes)
      return if bytes.empty? || @terminal_gone

      @stdout.write(bytes)
      @stdout.flush
    rescue Errno::EIO, Errno::EPIPE
      # The terminal is gone; hang up the shell as closing it would.
      @terminal_gone = true
      begin
        Process.kill("HUP", @pid)
      rescue SystemCallError
        nil
      end
    end

    def exit_code(status)
      status.exitstatus || (128 + status.termsig.to_i)
    end
  end
end
