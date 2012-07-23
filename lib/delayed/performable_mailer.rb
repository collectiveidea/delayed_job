require 'mail'

module Delayed
  class PerformableMailer < PerformableMethod
    def perform
      object.send(method_name, *args).deliver
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
  def delay(*args)
    raise RuntimeError, "Use MyMailer.delay.mailer_action(args) to delay sending of emails."
  end
end
