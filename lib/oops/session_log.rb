module Oops
  # Append-only JSONL log of captured commands for one shell session. A log
  # that grows past its cap is rewritten to keep only its newest records.
  class SessionLog
    CHUNK_SIZE = 64 * 1024
    DEFAULT_MAX_BYTES = 50 * 1024 * 1024
    # When a log passes its cap it is cut to this share of the cap, so a busy
    # tab is not rewritten on every command.
    TRIM_TO = 0.75
    LOG_NAME = /\A(\d{8}-\d{6})-(\d+)\.jsonl\z/

    attr_reader :path

    def self.new_path(dir, pid: Process.pid, now: Time.now)
      stamp = now.strftime("%Y%m%d-%H%M%S")
      File.join(dir, "#{stamp}-#{pid}.jsonl")
    end

    def self.process_alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::EPERM
      true
    rescue SystemCallError
      false
    end

    # Deletes the oldest logs of finished sessions until the total size of
    # all session logs is at most max_bytes. Logs of live sessions are kept.
    def self.rotate!(dir, max_bytes: DEFAULT_MAX_BYTES, alive: method(:process_alive?))
      logs = Dir.children(dir).filter_map do |name|
        m = LOG_NAME.match(name)
        next unless m

        size = begin
          File.size(File.join(dir, name))
        rescue SystemCallError
          next
        end
        { name: name, pid: m[2].to_i, size: size }
      end
      total = logs.sum { |l| l[:size] }
      logs.sort_by { |l| l[:name] }.each do |log|
        break if total <= max_bytes
        next if alive.call(log[:pid])

        remove_log(File.join(dir, log[:name]))
        total -= log[:size]
      end
    rescue Errno::ENOENT
      nil
    end

    def self.remove_log(file)
      [file, "#{file}.paused", "#{file}.status", "#{file}.trim"].each do |f|
        File.delete(f)
      rescue Errno::ENOENT
        nil
      end
    end
    private_class_method :remove_log

    def initialize(path, max_bytes: DEFAULT_MAX_BYTES)
      @path = path
      @max_bytes = max_bytes
    end

    # Raises if the record cannot be written. Trimming an oversized log is
    # best effort and never raises.
    def append(record)
      line = record.to_json_line
      size = File.open(@path, File::APPEND | File::CREAT | File::WRONLY, 0o600) do |f|
        f.syswrite(line)
        f.size
      end
      trim if size > @max_bytes
    end

    # Yields records newest first. Unparsable lines are skipped. The block can
    # return :stop to end the iteration.
    def each_backward
      return enum_for(:each_backward) unless block_given?

      File.open(@path, "rb") do |io|
        each_line_backward(io) do |line|
          record = parse(line)
          next unless record
          return nil if yield(record) == :stop
        end
      end
      nil
    rescue Errno::ENOENT
      nil
    end

    # Newest count finished, non-oops records, oldest first. With failed_only,
    # only records with a non-zero integer exit status count toward the limit.
    def last(count, skip_oops: true, failed_only: false)
      found = []
      each_backward do |r|
        next if r.exit.nil? || (skip_oops && r.oops_self?)
        next if failed_only && (!r.exit.is_a?(Integer) || r.exit.zero?)

        found << r
        :stop if found.size >= count
      end
      found.reverse
    end

    def last_failed
      last(1, failed_only: true).first
    end

    def paused?
      File.exist?(pause_path)
    end

    def pause!
      File.open(pause_path, File::CREAT | File::WRONLY, 0o600, &:itself)
    end

    def resume!
      File.delete(pause_path)
    rescue Errno::ENOENT
      nil
    end

    private

    def pause_path
      "#{@path}.paused"
    end

    # Rewrites the log with the newest complete records that fit in TRIM_TO
    # of the cap (always at least the newest one). The new file is written
    # next to the log and renamed over it, so a reader sees either the old or
    # the new log, never a mix.
    def trim
      keep = newest_lines((@max_bytes * TRIM_TO).to_i)
      tmp = "#{@path}.trim"
      remove_file(tmp)
      File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |f|
        keep.reverse_each { |l| f.write(l, "\n") }
      end
      File.rename(tmp, @path)
    rescue StandardError
      remove_file(tmp) if tmp
      nil
    end

    # Newest lines first, as many as fit in limit bytes (newlines included),
    # but at least one.
    def newest_lines(limit)
      lines = []
      total = 0
      File.open(@path, "rb") do |io|
        each_line_backward(io) do |line|
          next if line.empty?
          break if !lines.empty? && total + line.bytesize + 1 > limit

          lines << line
          total += line.bytesize + 1
        end
      end
      lines
    end

    def remove_file(file)
      File.delete(file)
    rescue SystemCallError
      nil
    end

    def parse(line)
      return nil if line.empty?

      Record.from_json_line(line)
    rescue Record::ParseError
      nil
    end

    def read_chunk(io, offset, length)
      io.seek(offset)
      io.read(length)
    end

    # Yields complete lines (without newline) from the end of the file. An
    # unterminated tail, if any, is ignored as a partial write.
    def each_line_backward(io, &)
      pos = io.size
      return if pos.zero?

      discard = read_chunk(io, pos - 1, 1) != "\n"
      carry = "".b
      while pos.positive?
        len = [CHUNK_SIZE, pos].min
        pos -= len
        parts = (read_chunk(io, pos, len) + carry).split("\n", -1)
        if discard
          if parts.size > 1
            parts.pop
            discard = false
          else
            parts.clear
          end
        end
        carry = pos.positive? && !parts.empty? ? parts.shift : "".b
        parts.reverse_each(&)
      end
    end
  end
end
