# APC marker layout
#
# The shell hooks write these markers into the terminal stream and the pty
# relay extracts them again. Because they are APC sequences, terminals ignore
# them. Byte layout:
#
#   PREFIX  ESC _ o o p s ;        ("\e_oops;")
#   body    <kind> [; <field> ...]
#   SUFFIX  ESC \                  ("\e\\")
#
# Fields are separated by ";". Free-form text (cwd, cmd) is strict base64
# (RFC 4648, no line breaks), so it never contains ";", ESC or a newline.
#
#   start;<seq>;<epoch>;<b64 cwd>;<b64 cmd>   command is about to run
#   end;<seq>;<exit>                          command finished
#   pause                                     stop recording (e.g. full-screen UI)
#   resume                                    start recording again
#
# <seq>, <epoch> and <exit> are decimal integers. Example:
#
#   printf '\033_oops;start;%s;%s;%s;%s\033\\' "$seq" "$(date +%s)" \
#     "$(printf '%s' "$PWD" | base64 | tr -d '\n')" \
#     "$(printf '%s' "$cmd" | base64 | tr -d '\n')"
#
# Marker.parse takes the text between "ESC _" and "ESC \", i.e. it starts with
# "oops;".
module Oops
  module Marker
    PREFIX = "\e_oops;".b.freeze
    SUFFIX = "\e\\".b.freeze

    UINT = /\A\d+\z/
    INT = /\A-?\d+\z/

    def self.start(seq:, started_at:, cwd:, cmd:)
      wrap("start;#{seq};#{started_at};#{encode(cwd)};#{encode(cmd)}")
    end

    def self.end(seq:, exit:)
      wrap("end;#{seq};#{exit}")
    end

    def self.pause = wrap("pause")
    def self.resume = wrap("resume")

    # Returns a Hash for a well-formed payload, nil for anything else.
    def self.parse(payload)
      return nil unless payload.is_a?(String)

      fields = payload.b.split(";", -1)
      return nil unless fields.shift == "oops"

      case fields.shift
      when "start" then parse_start(fields)
      when "end" then parse_end(fields)
      when "pause" then fields.empty? ? { kind: :pause } : nil
      when "resume" then fields.empty? ? { kind: :resume } : nil
      end
    end

    def self.parse_start(fields)
      return nil unless fields.size == 4 && fields[0].match?(UINT) && fields[1].match?(UINT)

      cwd = decode(fields[2])
      cmd = decode(fields[3])
      return nil unless cwd && cmd

      { kind: :start, seq: fields[0].to_i, started_at: fields[1].to_i, cwd: cwd, cmd: cmd }
    end

    def self.parse_end(fields)
      return nil unless fields.size == 2 && fields[0].match?(UINT) && fields[1].match?(INT)

      { kind: :end, seq: fields[0].to_i, exit: fields[1].to_i }
    end

    def self.wrap(body) = "#{PREFIX}#{body}#{SUFFIX}"
    def self.encode(text) = [text.to_s.b].pack("m0")

    def self.decode(text)
      text.unpack1("m0").force_encoding(Encoding::UTF_8).scrub
    rescue ArgumentError
      nil
    end

    private_class_method :parse_start, :parse_end, :wrap, :encode, :decode
  end
end
