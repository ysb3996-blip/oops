module Oops
  # Masks likely secrets in captured text. Each pattern replaces either its
  # whole match or, when it defines a named group `secret`, only that group.
  module Secrets
    TOKEN = "[secret]".freeze

    # Octet 0-255, used by the IPv4 pattern.
    OCTET = "(?:25[0-5]|2[0-4]\\d|1?\\d?\\d)".freeze

    # Order matters: specific token formats first, then URL userinfo before
    # email, and the generic key/value rule last so it skips values that an
    # earlier pattern already replaced.
    BUILTIN = [
      /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/,                                   # AWS access key id
      /\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_\w{20,})/,             # GitHub tokens
      /\bxox[abprs]-[A-Za-z0-9-]+/, # Slack tokens
      /\beyJ[\w-]+\.[\w-]+\.[\w-]+/,                                     # JWT
      %r{Authorization:[ \t]*(?:Bearer|Basic)[ \t]+(?<secret>[\w.~+/=-]+)}i,
      /-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----/m,
      %r{\b[a-z][a-z0-9+.-]*://(?<secret>[^\s/@:]+:[^\s/@]+)@}i,         # URL userinfo
      %r{[A-Za-z0-9._%+-]+@(?>[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+)(?!:[\w~/])}, # email, not scp-style git@host:path
      # Public IPv4: not private/loopback/unspecified, and not part of a longer
      # dotted number such as a version string (1.2.3.4.5).
      Regexp.new(
        "(?<![\\w.])" \
        "(?!127\\.|0\\.0\\.0\\.0|10\\.|192\\.168\\.|172\\.(?:1[6-9]|2\\d|3[01])\\.)" \
        "(?<secret>#{OCTET}(?:\\.#{OCTET}){3})(?!\\w|\\.\\d)"
      ),
      # name containing key/token/secret/password/passwd/pwd, then = or :
      # Quoted values are masked through the closing quote; unquoted values stop
      # at whitespace, quotes, , ; and & (so query strings keep each pair apart).
      /(?<![\w.-])[\w.-]*(?:key|token|secret|password|passwd|pwd)[\w.-]*["']?[ \t]*[=:][ \t]*["']?
        (?<secret>(?!\[secret\])(?:(?<=")[^"\n]+(?=")|(?<=')[^'\n]+(?=')|[^\s"',;&]+))/ix
    ].freeze

    module_function

    # Returns [masked_text, number_of_replacements]. `extra` regexps run first.
    # Input is scrubbed (invalid UTF-8 bytes become U+FFFD) so regexps never
    # raise on arbitrary captured output; the returned copy is always valid.
    def mask(text, extra: [])
      out = text.scrub
      count = 0
      (extra + BUILTIN).each do |pattern|
        out = out.gsub(pattern) do
          count += 1
          replacement(Regexp.last_match)
        end
      end
      [out, count]
    end

    def replacement(match)
      return TOKEN unless match.names.include?("secret") && match[:secret]

      whole = match[0]
      from = match.begin(:secret) - match.begin(0)
      to = match.end(:secret) - match.begin(0)
      whole[0, from] + TOKEN + whole[to..]
    end
  end
end
