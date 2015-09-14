require 'mail'

module Delayed
  class PerformableMailer < PerformableMethod
    def perform
      mailer = object.send(method_name, *args)
      mailer.respond_to?(:deliver_now) ? mailer.deliver_now : mailer.deliver
    end
  end

  module DelayMail
    def delay(options = {})
      DelayProxy.new(PerformableMailer, self, options)
    end
  end
end
