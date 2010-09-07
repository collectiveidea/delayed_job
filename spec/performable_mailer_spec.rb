require 'spec_helper'
require 'action_mailer'
require 'delayed/performable_mailer'

class MyMailer < ActionMailer::Base
  def signup(email)
    mail :to => email, :subject => "Delaying Emails"
  end
end

describe ActionMailer::Base do
  describe "delay" do
    it "should enqueue a PerformableEmail job" do
      lambda {
        job = MyMailer.delay.signup('john@example.com')
        job.payload_object.class.should   == Delayed::PerformableMailer
        job.payload_object.method.should  == :signup
        job.payload_object.args.should    == ['john@example.com']
      }.should change { Delayed::Job.count }.by(1)
    end
  end
  
  describe "delay on a mail object" do
    it "should raise an exception" do
      lambda {
        MyMailer.signup('john@example.com').delay
      }.should raise_error(RuntimeError)
    end
  end
  
  describe Delayed::PerformableMailer do
    describe "perform" do
      before do
        @email = mock('email', :deliver => true)
        @mailer_class = mock('MailerClass', :signup => @email)
        @mailer = Delayed::PerformableMailer.new(@mailer_class, :signup, ['john@example.com'])
      end

      it "should call the method and #deliver on the mailer" do
        @mailer_class.should_receive(:signup).with('john@example.com')
        @email.should_receive(:deliver)
        @mailer.perform
      end
    end
  end
  
end
