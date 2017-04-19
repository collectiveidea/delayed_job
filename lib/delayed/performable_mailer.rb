require 'mail'

module Delayed
  class PerformableMailer < PerformableMethod
    def perform
      mailer = object.send(method_name, *args)
      mailer.respond_to?(:deliver_now) ? mailer.deliver_now : mailer.deliver
    end

    def display_name
      "#{object}.#{method_name}"
    end
  end

  module DelayMail
    def delay(options = {})
      DelayProxy.new(PerformableMailer, self, options)
    end
  end
end

Mail::Message.class_eval do
  def delay(*_args)
    raise 'Use MyMailer.delay.mailer_action(args) to delay sending of emails.'
  end
end
