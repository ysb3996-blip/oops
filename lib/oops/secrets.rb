module Oops
  # Masks likely secrets in captured text. Each pattern replaces either its
  # whole match or, when it defines a named group `secret`, only that group.
  module Secrets
    TOKEN = "[secret]".freeze

    # Octet 0-255, used by the IPv4 pattern.
    OCTET = "(?:25[0-5]|2[0-4]\\d|1?\\d?\\d)".freeze

    # Token formats with a fixed prefix. These are also tried on shell words
    # with their quotes removed (see mask_split_tokens).
    TOKEN_FORMATS = [
      /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/,                                   # AWS access key id
      /\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_\w{20,})/,             # GitHub tokens
      /\bxox[abprs]-[A-Za-z0-9-]+/, # Slack tokens
      /\bsk-[A-Za-z0-9_-]{20,}/,                                        # OpenAI / Anthropic keys
      /\b[sr]k_(?:live|test)_[A-Za-z0-9]{16,}/,                         # Stripe secret keys
      /\bglpat-[A-Za-z0-9_-]{20,}/,                                     # GitLab tokens
      /(?<![A-Za-z0-9_])hf_[A-Za-z0-9]{16,}(?![A-Za-z0-9_])/, # Hugging Face access tokens
      /(?<![A-Za-z0-9_-])sb_secret_[A-Za-z0-9_-]{24,128}(?![A-Za-z0-9_-])/, # Supabase server-only keys
      /(?<![A-Za-z0-9_])lin_api_[A-Za-z0-9]{40}(?![A-Za-z0-9_])/, # Linear personal API keys
      /(?<![A-Za-z0-9_])ntn_[A-Za-z0-9]{40,}(?![A-Za-z0-9_])/, # Notion integration tokens
      /(?<![A-Za-z0-9_])(?:dop|doo|dor)_v1_[0-9a-f]{64}(?![A-Za-z0-9_])/, # DigitalOcean API tokens
      /(?<![A-Za-z0-9_])(?:shpat|shpca|shppa)_[A-Za-z0-9]{32,}(?![A-Za-z0-9_])/, # Shopify access tokens
      %r{
        (?<![A-Za-z0-9_])sntrys_eyJ[A-Za-z0-9+/]{16,800}={0,2}_
        [A-Za-z0-9+/]{43}(?![A-Za-z0-9+/=_])
      }x, # Sentry org auth tokens
      /\bAIza[0-9A-Za-z_-]{35}/, # Google API keys
      /(?<![A-Za-z0-9_-])SG\.[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{43}(?![A-Za-z0-9_-])/, # SendGrid API keys
      /\bnpm_[A-Za-z0-9]{36}/ # npm tokens
    ].freeze

    # A word that holds a quote or a backslash. The lookbehind lets it start
    # only at the beginning of a word, so a long word is scanned once.
    QUOTED_WORD = /(?<!\S)(?=\S*["'\\])\S+/

    # Shell syntax that may surround a split token and stays readable: a
    # leading NAME= or --flag= and trailing ; & | ) characters.
    ASSIGNMENT = /\A(?:--?[A-Za-z0-9-]+|[A-Za-z_]\w*)=/
    TRAILING_OPERATORS = /\A[;&|)]+/

    # Order matters: specific token formats first, then URL userinfo before
    # email, and the generic key/value rule last so it skips values that an
    # earlier pattern already replaced.
    BUILTIN = [
      *TOKEN_FORMATS,
      %r{hooks\.slack\.com/services/(?<secret>[A-Za-z0-9/]+)}, # Slack webhook URLs
      /\beyJ[\w-]+\.[\w-]+\.[\w-]+/, # JWT
      %r{Authorization:[ \t]*(?:Bearer|Basic|token)[ \t]+(?<secret>[\w.~+/=-]+)}i,
      # Without an END line (cut off by head, a failed command or the capture
      # limit) everything after BEGIN is masked.
      /-----BEGIN [A-Z ]*PRIVATE KEY-----.*?(?:-----END [A-Z ]*PRIVATE KEY-----|\z)/m,
      %r{\b[a-z][a-z0-9+.-]*://(?<secret>[^\s/@:]+:[^\s/@]+)@}i, # URL userinfo
      # Email. The last label must be letters, like a real TLD, so versioned
      # names such as mysql@8.4 stay; the lookahead skips git@host:path.
      %r{[A-Za-z0-9._%+-]+@(?>(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,})(?![A-Za-z0-9-])(?!:[\w~/])},
      # Public IPv4: not private/loopback/unspecified, and not part of a longer
      # dotted number such as a version string (1.2.3.4.5).
      Regexp.new(
        "(?<![\\w.])" \
        "(?!127\\.|0\\.0\\.0\\.0|10\\.|192\\.168\\.|172\\.(?:1[6-9]|2\\d|3[01])\\.)" \
        "(?<secret>#{OCTET}(?:\\.#{OCTET}){3})(?!\\w|\\.\\d)"
      ),
      # Passwords given as command-line arguments. The spans between the
      # command name and the option are bounded so a long line of repeated
      # command names cannot make matching quadratic.
      /(?<![\w-])--(?:password|passwd|pwd)[ \t]+(?<q>["'])?
        (?<secret>(?![-\[])(?(<q>)(?>\\.|(?!\k<q>)[^\\\n])++|[^\s"']+))\k<q>?/ix,
      /\bcurl\b[^\n|;&]{0,200}?\s(?:-u|--user)[ \t]+(?<secret>[^\s:]+:\S+)/,
      /\bmysql(?:dump|admin|pump)?\b[^\n|;&]{0,200}?\s-p(?<secret>[^\s"']+)/,
      /\bdocker\b[^\n|;&]{0,200}?\blogin\b[^\n|;&]{0,200}?\s(?:-p|--password)[ \t]+(?<secret>\S+)/,
      # name containing key/token/secret/password/passwd/pwd, then = or :
      # Quoted values run to the matching closing quote (backslash escapes
      # allowed) using an atomic body, so matching stays linear; an unterminated
      # quote masks to the end of the line. Unquoted values stop at whitespace,
      # quotes, , ; and & (so query strings keep each pair apart). The name
      # parts are bounded: with unbounded repeats on both sides of the keyword,
      # a long word that is full of keywords took quadratic time.
      /(?<![\w.-])[\w.-]{0,64}(?:key|token|secret|password|passwd|pwd)[\w.-]{0,64}["']?[ \t]*[=:][ \t]*
        (?<q>["'])?
        (?<secret>(?!\[secret\])(?(<q>)(?>\\.|(?!\k<q>)[^\\\n])++|[^\s"',;&]+))
        \k<q>?/ix
    ].freeze

    module_function

    # Returns [masked_text, number_of_replacements]. `extra` regexps run first.
    # Input is scrubbed (invalid UTF-8 bytes become U+FFFD) so regexps never
    # raise on arbitrary captured output; the returned copy is always valid.
    def mask(text, extra: [])
      out, count = mask_split_tokens(text.scrub)
      (extra + BUILTIN).each do |pattern|
        out = out.gsub(pattern) do
          count += 1
          replacement(Regexp.last_match)
        end
      end
      [out, count]
    end

    # A token split by shell quotes, such as ghp_"abc", only matches once the
    # quotes are gone, so the word is replaced. A leading NAME= and trailing
    # operators are kept when the token lies between them; otherwise the whole
    # word goes. Words where a format already matches in place are left to the
    # patterns that keep the quotes.
    def mask_split_tokens(text)
      count = 0
      out = text.gsub(QUOTED_WORD) do |word|
        masked = mask_split_word(word)
        count += 1 if masked != word
        masked
      end
      [out, count]
    end

    def mask_split_word(word)
      head = word[ASSIGNMENT] || ""
      # Reversed so the anchored match reads only the trailing run.
      tail = word.reverse[TRAILING_OPERATORS]&.reverse || ""
      core = word[head.size...(word.size - tail.size)]
      return "#{head}#{TOKEN}#{tail}" if split_token?(core)
      return TOKEN if split_token?(word)

      word
    end

    def split_token?(word)
      bare = word.delete(%q("'\\))
      TOKEN_FORMATS.any? { |format| bare.match?(format) && !word.match?(format) }
    end

    def replacement(match)
      return TOKEN unless match.names.include?("secret") && match[:secret]

      # Byte offsets: char offsets would cost O(n) per match on long input.
      whole = match[0]
      start = match.byteoffset(0).first
      from, to = match.byteoffset(:secret).map { |offset| offset - start }
      whole.byteslice(0, from) + TOKEN + whole.byteslice(to..)
    end
  end
end
