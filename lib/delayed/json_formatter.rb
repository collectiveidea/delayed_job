require 'json'

module Delayed
  class JsonFormatter
    def call(severity, timestamp, progname, msg)
      json = {:level => severity, :timestamp => timestamp.to_s}
      json = json.merge(prosses_message(msg))
      json = json.merge(:progname => progname.to_s) unless progname.nil?

      json.to_json + "\n"
    end

    def prosses_message(msg)
      return msg if msg.is_a?(Hash)
      {:message => msg.strip}
    end
  end
end
