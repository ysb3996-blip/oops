require "fileutils"

module Oops
  # Filesystem locations following the XDG base directory spec.
  module Paths
    module_function

    def config_file(env: ENV)
      File.join(base(env, "XDG_CONFIG_HOME", ".config"), "oops", "config.yml")
    end

    def sessions_dir(env: ENV)
      File.join(base(env, "XDG_STATE_HOME", ".local/state"), "oops", "sessions")
    end

    def ensure_sessions_dir!(env: ENV)
      dir = sessions_dir(env: env)
      FileUtils.mkdir_p(dir, mode: 0o700)
      File.chmod(0o700, dir)
      dir
    end

    def base(env, key, fallback)
      value = env[key]
      value.nil? || value.empty? ? File.join(Dir.home, fallback) : value
    end
  end
end
