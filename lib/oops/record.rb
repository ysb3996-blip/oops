require "json"

module Oops
  # One captured command with its output, stored as a single JSON line.
  Record = Struct.new(:seq, :cmd, :cwd, :started_at, :ended_at, :exit, :output,
                      :dropped_bytes, :fullscreen, keyword_init: true) do
    def to_json_line
      h = to_h
      h[:cmd] = utf8_clean(cmd)
      h[:cwd] = utf8_clean(cwd)
      h[:output] = [output.to_s.b].pack("m0")
      "#{JSON.generate(h)}\n"
    end

    def utf8_clean(value)
      return nil if value.nil?

      value.to_s.dup.force_encoding(Encoding::UTF_8).scrub
    end
    private :utf8_clean

    def oops_self?
      cmd.to_s.match?(%r{\A\s*(\S*/)?oops(\s|\z)})
    end

    def self.from_json_line(line)
      h = JSON.parse(line)
      raise Record::ParseError, "record is not an object" unless h.is_a?(Hash)

      new(**h.slice(*members.map(&:to_s)).transform_keys(&:to_sym),
          output: h["output"].to_s.unpack1("m0"))
    rescue JSON::ParserError, ArgumentError => e
      raise Record::ParseError, e.message
    end
  end

  # Raised when a session log line cannot be decoded into a Record.
  class Record
    class ParseError < StandardError; end
  end
end
