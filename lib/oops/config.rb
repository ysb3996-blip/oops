require "yaml"
require_relative "paths"

module Oops
  # User configuration loaded from a YAML file; problems become warnings.
  class Config
    KNOWN_KEYS = %w[replace secrets clipboard].freeze

    attr_reader :replace, :secrets, :clipboard, :warnings

    def self.load(path = nil, env: ENV)
      new(path || Paths.config_file(env: env))
    end

    def initialize(path)
      @replace = {}
      @secrets = []
      @clipboard = "auto"
      @warnings = []
      read(path)
    end

    private

    def read(path)
      return unless File.file?(path)

      data = YAML.safe_load_file(path)
      return if data.nil?
      return @warnings << "could not parse #{path}: top level must be a mapping" unless data.is_a?(Hash)

      apply(data)
    rescue Psych::Exception, SystemCallError => e
      @warnings << "could not parse #{path}: #{e.message}"
    end

    def apply(data)
      (data.keys.map(&:to_s) - KNOWN_KEYS).each { |k| @warnings << "unknown key: #{k}" }
      apply_replace(data["replace"]) if data.key?("replace")
      apply_secrets(data["secrets"]) if data.key?("secrets")
      @clipboard = data["clipboard"].to_s unless data["clipboard"].to_s.empty?
    end

    def apply_replace(value)
      return @warnings << "replace must be a mapping; ignored" unless value.is_a?(Hash)

      pairs = value.map { |k, v| [k.to_s, v.to_s] }
      @replace = pairs.sort_by { |k, _| -k.length }.to_h
    end

    def apply_secrets(value)
      return @warnings << "secrets must be a list; ignored" unless value.is_a?(Array)

      value.each do |src|
        next @warnings << "blank secret pattern ignored" if src.to_s.strip.empty?

        @secrets << Regexp.new(src.to_s)
      rescue RegexpError => e
        @warnings << "invalid secret pattern #{src.inspect}: #{e.message}"
      end
    end
  end
end
