require 'mail'

module Delayed
  class PerformableMailer < PerformableMethod
    def perform
      object.send(method_name, *args).deliver
    end
  end

  module DelayMail
    def delay(options = {})
      DelayProxy.new(PerformableMailer, self, options)
    end
  end
end
