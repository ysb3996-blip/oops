module Oops
  # The device path of the terminal an IO is connected to.
  module Tty
    module_function

    # Returns e.g. "/dev/ttys003", or nil when io is not a terminal. IO#ttyname
    # needs io-console 0.7.2 or later (Ruby 3.3 ships 0.7.1), so this falls
    # back to tty(1) on older versions.
    def name(io)
      return nil unless io.respond_to?(:tty?) && io.tty?
      return io.ttyname if io.respond_to?(:ttyname)

      name = IO.popen(["tty"], in: io, err: File::NULL, &:read).strip
      name.start_with?("/") ? name : nil
    rescue SystemCallError, IOError, NotImplementedError
      nil
    end
  end
end
