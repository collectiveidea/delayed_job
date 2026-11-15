module Delayed
  def self.program_name
    File.basename($PROGRAM_NAME)
  end

  # Parses decimal seconds ("5", "0.5", "010") to an Integer or Float.
  # Stricter than Float(), which accepts "0x10", "1_0" and "1e2".
  def self.parse_seconds(value)
    text = value.to_s.strip
    raise ArgumentError, "invalid number of seconds: #{value.inspect}" unless text =~ /\A-?\d+(\.\d+)?\z/
    Regexp.last_match(1) ? Float(text) : Integer(text, 10)
  end

  # Raises ArgumentError like Signal.trap for a reserved signal. JRuby only
  # warns when trapping QUIT, which the JVM reserves for thread dumps.
  def self.check_trappable!(signal)
    raise ArgumentError, "can't trap reserved signal: SIG#{signal}" if signal == 'QUIT' && RUBY_ENGINE == 'jruby'
  end

  def self.root
    defined?(::Rails.root) ? ::Rails.root : Pathname.new(Dir.pwd)
  end
end
