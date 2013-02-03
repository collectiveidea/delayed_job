require 'spec_helper'

require 'action_mailer'
class MyMailer < ActionMailer::Base
  def signup(email)
    mail :to => email, :subject => "Delaying Emails", :from => "delayedjob@example.com"
  end
end

describe ActionMailer::Base do
  describe "delay" do
    it "enqueues a PerformableEmail job" do
      expect {
        job = MyMailer.delay.signup('john@example.com')
        expect(job.payload_object.class).to eq(Delayed::PerformableMailer)
        expect(job.payload_object.method_name).to eq(:signup)
        expect(job.payload_object.args).to eq(['john@example.com'])
      }.to change { Delayed::Job.count }.by(1)
    end
  end

  describe "delay on a mail object" do
    it "raises an exception" do
      expect {
        MyMailer.signup('john@example.com').delay
      }.to raise_error(RuntimeError)
    end
  end

  describe Delayed::PerformableMailer do
    describe "perform" do
      it "calls the method and #deliver on the mailer" do
        email = mock('email', :deliver => true)
        mailer_class = mock('MailerClass', :signup => email)
        mailer = Delayed::PerformableMailer.new(mailer_class, :signup, ['john@example.com'])

        mailer_class.should_receive(:signup).with('john@example.com')
        email.should_receive(:deliver)
        mailer.perform
      end
    end
  end

end
