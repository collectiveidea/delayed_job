module Delayed
  def self.program_name
    File.basename($PROGRAM_NAME)
  end

  def self.root
    defined?(::Rails.root) ? ::Rails.root : Pathname.new(Dir.pwd)
  end
end
