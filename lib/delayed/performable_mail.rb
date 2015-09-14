require 'mail'

module Delayed
  class PerformableMail < PerformableMethod
    def initialize(raw_mail, method_name, args)
      super(Mail.new(raw_mail), method_name, args)
    end
  end

  module DelayMailMessage
    def delay(options = {})
      DelayProxy.new(PerformableMail, encoded, options)
    end
  end
end
