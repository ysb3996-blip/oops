module Oops
  # Removes the PROMPT_SP filler that zsh writes at the end of a command's
  # output.
  #
  # Before it draws a prompt (and before precmd, so before our end marker),
  # zsh with PROMPT_SP and PROMPT_CR set (the default) writes:
  #
  #   <PROMPT_EOL_MARK> <columns - W - (0 or 1) spaces> CR <W spaces> CR
  #
  # where W is the display width of the expanded mark (default "%B%S%#%s%b",
  # a bold inverse "%" or "#"). On a terminal this leaves the mark after
  # output that did not end in a newline and moves the prompt to a fresh
  # line. In a record it is noise, and worse: line-control handling keeps the
  # text after the last CR (" "), so a last line without a newline is lost.
  #
  # Only an exact trailing match is removed: the CR / spaces / CR shape, a
  # mark of width W right before the spaces, and mark plus spaces at least
  # MIN_COLUMNS wide (the filler spans the terminal). Assumes a mark that
  # does not end in spaces.
  module PromptSp
    MIN_COLUMNS = 20
    FILLER = /(?<! )( ++)\r( *+)\r\z/n
    TOKEN = Regexp.union(Ansi::ESCAPES, /[\xC2-\xF4][\x80-\xBF]*|./mn)
    WIDE = [
      0x1100..0x115F, 0x2E80..0x303E, 0x3041..0x33FF, 0x3400..0x4DBF, 0x4E00..0x9FFF,
      0xA000..0xA4CF, 0xAC00..0xD7A3, 0xF900..0xFAFF, 0xFE30..0xFE4F, 0xFF00..0xFF60,
      0xFFE0..0xFFE6, 0x1F300..0x1F64F, 0x1F900..0x1F9FF, 0x20000..0x3FFFD
    ].freeze

    module_function

    # Returns bytes without a trailing filler, or bytes unchanged.
    def strip(bytes)
      raw = bytes.b
      m = FILLER.match(raw)
      return bytes unless m

      width = m[2].bytesize
      return bytes if width + m[1].bytesize < MIN_COLUMNS

      before = raw.byteslice(0, m.begin(0))
      line_start = (before.rindex("\n") || -1) + 1
      tokens = before.byteslice(line_start..).scan(TOKEN)
      tokens = drop_mark(tokens, width)
      return bytes unless tokens

      (before.byteslice(0, line_start) + tokens.join).force_encoding(bytes.encoding)
    end

    # Pops the mark (width display columns) and the escape sequences around
    # it off the end of the line's tokens; nil if the line is too short.
    def drop_mark(tokens, width)
      tokens = tokens.dup
      while width.positive?
        token = tokens.pop
        return nil unless token

        width -= token_width(token)
      end
      tokens.pop while tokens.any? && token_width(tokens.last).zero?
      tokens
    end

    def token_width(token)
      return 0 if token.start_with?("\e", "\a")
      return 1 if token.bytesize == 1

      char = token.dup.force_encoding(Encoding::UTF_8)
      return 1 unless char.valid_encoding?

      WIDE.any? { |range| range.cover?(char.ord) } ? 2 : 1
    end
  end
end
