module Oops
  # Splits the shell's pty output into bytes for the user's terminal and
  # per-command records.
  #
  # Two layers work on the stream:
  #
  # 1. Marker extraction. Complete "ESC _ oops; ... ESC \" APCs are removed
  #    and handled as events; everything else is forwarded byte for byte, in
  #    order. A chunk may end inside a possible marker, so a trailing possible
  #    prefix is held back until the next feed decides it:
  #      :text    nothing held
  #      :prefix  holding a proper prefix of "ESC _ oops;" (1..7 bytes)
  #      :body    holding "ESC _ oops;" plus body bytes, waiting for "ESC \"
  #    A held body is given up (emitted as ordinary bytes) when it grows past
  #    MAX_HELD_MARKER bytes, or when an ESC inside it is not followed by "\".
  #    An APC that does not start with "oops;" never reaches :body, so it is
  #    forwarded untouched.
  #
  # 2. Recording. Content bytes seen between a start marker and the matching
  #    end marker are stored for that command, except inside alternate-screen
  #    spans ("ESC [ ? 1049 h", "ESC [ ? 1047 h", "ESC [ ? 47 h" up to any of
  #    the matching "l" forms), which are replaced by one OMITTED line. The
  #    alternate-screen detector keeps its own small pending tail so that a
  #    sequence split across chunks is still recognised; this only delays
  #    storing, never forwarding.
  #
  # While paused nothing is stored and start/end markers are ignored (they are
  # still removed from the forwarded bytes).
  #
  # Any program can print a marker, so the optional pause_gate decides whether
  # a pause or resume marker is genuine: it is called with :pause or :resume
  # and the marker is ignored when it returns false.
  class StreamParser
    OMITTED = "[full-screen app output omitted]\n".b.freeze
    MAX_HELD_MARKER = 65_536

    PREFIX = Marker::PREFIX
    ESC = "\e".b.freeze
    APC_START = "\e_".b.freeze
    ESC_BYTE = 0x1b
    BACKSLASH = 0x5c

    ALT_ENTER = /\e\[\?(?:1049|1047|47)h/n
    ALT_LEAVE = /\e\[\?(?:1049|1047|47)l/n
    ALT_ENTER_SEQS = ["\e[?1049h", "\e[?1047h", "\e[?47h"].map { |s| s.b.freeze }.freeze
    ALT_LEAVE_SEQS = ["\e[?1049l", "\e[?1047l", "\e[?47l"].map { |s| s.b.freeze }.freeze
    ALT_MAX_PARTIAL = ALT_ENTER_SEQS.map(&:bytesize).max - 1

    # A command between its start marker and its end marker.
    OpenCommand = Struct.new(:seq, :cmd, :cwd, :started_at, :buffer, :fullscreen, :in_span, :pending)

    # Keeps the last max bytes appended, without re-copying the retained data
    # on every append: bytes live in chunks of about CHUNK bytes and the front
    # is trimmed by moving an offset into the first chunk.
    class TailBuffer
      CHUNK = 65_536

      attr_reader :dropped

      def initialize(max)
        @max = max
        @chunks = []
        @head = 0
        @size = 0
        @dropped = 0
      end

      def <<(str)
        return self if str.empty?

        if str.bytesize >= @max
          @dropped += @size + str.bytesize - @max
          @chunks = [str.byteslice(str.bytesize - @max, @max).b]
          @head = 0
          @size = @max
          return self
        end

        last = @chunks.last
        if last && last.bytesize < CHUNK
          last << str
        else
          @chunks << String.new(str, encoding: Encoding::BINARY, capacity: CHUNK)
        end
        @size += str.bytesize
        trim
        self
      end

      def to_s
        return "".b if @chunks.empty?

        out = String.new(encoding: Encoding::BINARY, capacity: @size)
        out << @chunks[0].byteslice(@head..)
        @chunks.drop(1).each { |chunk| out << chunk }
        out
      end

      private

      def trim
        excess = @size - @max
        while excess.positive?
          avail = @chunks[0].bytesize - @head
          take = [avail, excess].min
          if take == avail
            @chunks.shift
            @head = 0
          else
            @head += take
          end
          @size -= take
          @dropped += take
          excess -= take
        end
      end
    end

    def initialize(max_bytes: 1_048_576, pause_gate: nil, &on_record)
      @max_bytes = max_bytes
      @pause_gate = pause_gate
      @on_record = on_record
      @state = :text
      @hold = +"".b
      @hold_ends_with_esc = false
      @paused = false
      @command = nil
      @recorded_upto = 0
    end

    def paused? = @paused

    # Returns the bytes to write to the terminal (binary String).
    def feed(bytes)
      data = bytes.b
      out = String.new(encoding: Encoding::BINARY, capacity: data.bytesize)
      @recorded_upto = 0
      pos = 0
      while pos < data.bytesize
        pos = case @state
              when :text then scan_text(data, pos, out)
              when :prefix then scan_prefix(data, pos, out)
              else scan_body(data, pos, out)
              end
      end
      flush_recording(out)
      out
    end

    # Ends the stream: held-back bytes are treated as ordinary content and
    # returned so the caller can still forward them, and an open command is
    # emitted with exit: nil.
    def finish
      out = +"".b
      @recorded_upto = 0
      release_hold(out)
      flush_recording(out)
      close_command(nil) if @command
      out
    end

    private

    # --- marker extraction ---

    # Only "ESC _" can start a marker, plus a lone ESC at the end of the
    # chunk, which might be followed by "_" in the next one.
    def scan_text(data, pos, out)
      i = data.index(APC_START, pos)
      if i
        out << data.byteslice(pos, i - pos)
        @hold = +APC_START
        @state = :prefix
        return i + 2
      end

      last = data.bytesize - 1
      if data.getbyte(last) == ESC_BYTE
        out << data.byteslice(pos, last - pos)
        @hold = +ESC
        @state = :prefix
      else
        out << data.byteslice(pos..)
      end
      data.bytesize
    end

    def scan_prefix(data, pos, out)
      unless data.getbyte(pos) == PREFIX.getbyte(@hold.bytesize)
        release_hold(out)
        return pos
      end

      @hold << data.byteslice(pos, 1)
      @state = :body if @hold.bytesize == PREFIX.bytesize
      pos + 1
    end

    def scan_body(data, pos, out)
      return scan_terminator(data, pos, out) if @hold_ends_with_esc

      i = data.index(ESC, pos) || data.bytesize
      @hold << data.byteslice(pos, i - pos)
      if i < data.bytesize
        @hold << ESC
        @hold_ends_with_esc = true
        i += 1
      end
      give_up_body(out) if @hold.bytesize > MAX_HELD_MARKER
      i
    end

    # The held body ends with ESC; the byte at pos decides whether it is "ESC \".
    def scan_terminator(data, pos, out)
      if data.getbyte(pos) == BACKSLASH
        payload = @hold.byteslice(2, @hold.bytesize - 3)
        reset_hold
        flush_recording(out)
        handle_marker(payload)
        pos + 1
      else
        give_up_body(out)
        pos
      end
    end

    # Emits a held body as ordinary bytes. A trailing ESC may start a new
    # marker, so it stays held as a fresh prefix.
    def give_up_body(out)
      restart = @hold_ends_with_esc
      @hold.chop! if restart
      release_hold(out)
      return unless restart

      @hold = +ESC
      @state = :prefix
    end

    # Emits held bytes as ordinary content.
    def release_hold(out)
      held = @hold
      reset_hold
      out << held
    end

    def reset_hold
      @hold = +"".b
      @hold_ends_with_esc = false
      @state = :text
    end

    # Forwarded bytes are collected in out; the part after @recorded_upto has
    # not been offered to the recorder yet. Flushing once per run of content
    # (before each marker and at the end of a feed) keeps the per-byte cost
    # low for escape-heavy output.
    def flush_recording(out)
      record_content(out.byteslice(@recorded_upto..)) if @command && out.bytesize > @recorded_upto
      @recorded_upto = out.bytesize
    end

    # --- marker events ---

    def handle_marker(payload)
      marker = Marker.parse(payload)
      return unless marker

      case marker[:kind]
      when :pause
        return unless gate_open?(:pause)

        @command = nil
        @paused = true
      when :resume
        @paused = false if gate_open?(:resume)
      when :start
        open_command(marker) unless @paused
      when :end
        close_command(marker[:exit]) if !@paused && @command && @command.seq == marker[:seq]
      end
    end

    def gate_open?(kind)
      @pause_gate.nil? || @pause_gate.call(kind)
    end

    def open_command(marker)
      close_command(nil) if @command
      @command = OpenCommand.new(marker[:seq], marker[:cmd], marker[:cwd], marker[:started_at],
                                 TailBuffer.new(@max_bytes), false, false, "".b)
    end

    def close_command(exit_status)
      cmd = @command
      @command = nil
      cmd.buffer << cmd.pending unless cmd.in_span
      @on_record&.call(Record.new(seq: cmd.seq, cmd: cmd.cmd, cwd: cmd.cwd, started_at: cmd.started_at,
                                  ended_at: Time.now.to_i, exit: exit_status, output: cmd.buffer.to_s,
                                  dropped_bytes: cmd.buffer.dropped, fullscreen: cmd.fullscreen))
    end

    # --- recording with alternate-screen detection ---

    def record_content(bytes)
      cmd = @command
      data = cmd.pending.empty? ? bytes : cmd.pending + bytes
      cmd.pending = "".b
      pos = 0
      loop do
        if cmd.in_span
          match = ALT_LEAVE.match(data, pos)
          unless match
            cut = partial_start(data, pos, ALT_LEAVE_SEQS)
            cmd.pending = data.byteslice(cut..) if cut
            return
          end
          cmd.in_span = false
        else
          match = ALT_ENTER.match(data, pos)
          unless match
            cut = partial_start(data, pos, ALT_ENTER_SEQS) || data.bytesize
            cmd.buffer << data.byteslice(pos, cut - pos)
            cmd.pending = data.byteslice(cut..)
            return
          end
          cmd.buffer << data.byteslice(pos, match.begin(0) - pos)
          cmd.buffer << OMITTED
          cmd.fullscreen = true
          cmd.in_span = true
        end
        pos = match.end(0)
      end
    end

    # Index of the earliest ESC at or after from whose tail is a proper prefix
    # of one of seqs, or nil.
    def partial_start(data, from, seqs)
      first = [from, data.bytesize - ALT_MAX_PARTIAL].max
      (first...data.bytesize).each do |k|
        next unless data.getbyte(k) == ESC_BYTE

        tail = data.byteslice(k..)
        return k if seqs.any? { |seq| seq.bytesize > tail.bytesize && seq.start_with?(tail) }
      end
      nil
    end
  end
end
