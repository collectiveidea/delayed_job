require 'helper'

module Delayed
  describe LogSubscriber do
    class DummyEvent < ActiveSupport::Notifications::Event
      def initialize(event_type, payload = {})
        super(event_type, Time.now, Time.now, 1, payload)
      end
    end

    before do
      @expected_time = Time.now.strftime('%FT%T%z')
    end

    describe '#starting' do
      let(:payload) { {:quiet => true, :dj_worker => 'ExampleJob', :dj_name => 'EJob', :dj_time => @expected_time} }
      it 'call logger with the expected text' do
        expect(subject.logger).to receive(:info).with("#{@expected_time}: [Worker(#{payload[:dj_worker]})] Starting job worker")
        subject.starting(DummyEvent.new('starting.delayed_job', payload))
      end

      it 'use worker default log_level' do
        Delayed::Worker.default_log_level = 'debug'

        expect(subject.logger).to receive(:debug).with("#{@expected_time}: [Worker(#{payload[:dj_worker]})] Starting job worker")
        subject.starting(DummyEvent.new('starting.delayed_job', payload))
      end
    end

    describe 'consecutive_failures' do
      let(:payload) { {:quiet => true, :dj_worker => 'ExampleJob', :dj_name => 'EJob', :dj_time => @expected_time, :dj_id => 10, :consecutive_attempts => 100} }
      it 'call logger with the expected text' do
        expect(subject.logger).to receive(:error).with("#{@expected_time}: [Worker(#{payload[:dj_worker]})] Job EJob (id=#{payload[:dj_id]}) FAILED permanently because of 100 consecutive failures")
        subject.consecutive_failures(DummyEvent.new('consecutive_failures.delayed_job', payload))
      end
    end

    describe 'running' do
      let(:payload) { {:quiet => true, :dj_worker => 'ExampleJob', :dj_name => 'EJob', :dj_time => @expected_time} }
      it 'call logger with the expected text' do
        expect(subject.logger).to receive(:info).with("#{@expected_time}: [Worker(#{payload[:dj_worker]})] Job EJob (id=#{payload[:dj_id]}) RUNNING")
        subject.running(DummyEvent.new('running.delayed_job', payload))
      end
    end

    describe 'completed' do
      let(:payload) { {:quiet => true, :dj_worker => 'ExampleJob', :dj_name => 'EJob', :dj_time => @expected_time, :dj_id => 10, :runtime => 0.4376} }
      it 'call logger with the expected text' do
        expect(subject.logger).to receive(:info).with("#{@expected_time}: [Worker(#{payload[:dj_worker]})] Job EJob (id=#{payload[:dj_id]}) COMPLETED after 0.4376")
        subject.completed(DummyEvent.new('completed.delayed_job', payload))
      end
    end

    describe 'failed_permanently' do
      let(:payload) { {:quiet => true, :dj_worker => 'ExampleJob', :dj_name => 'EJob', :dj_id => 10, :dj_time => @expected_time, :error_name => 'ConnectionError', :error_message => 'Connection Error'} }
      it 'call logger with the expected text' do
        expect(subject.logger).to receive(:error).with("#{@expected_time}: [Worker(#{payload[:dj_worker]})] Job EJob (id=#{payload[:dj_id]}) FAILED permanently with #{payload[:error_name]}: #{payload[:error_message]}")
        subject.failed_permanently(DummyEvent.new('failed_permanently.delayed_job', payload))
      end
    end

    describe 'failed' do
      let(:payload) { {:quiet => true, :dj_worker => 'ExampleJob', :dj_name => 'EJob', :dj_time => @expected_time, :dj_id => 10, :attempts => 8, :error_name => 'ConnectionError', :error_message => 'Connection Error'} }
      it 'call logger with the expected text' do
        expect(subject.logger).to receive(:error).with("#{@expected_time}: [Worker(#{payload[:dj_worker]})] Job EJob (id=#{payload[:dj_id]}) FAILED (#{payload[:attempts]} prior attempts) with #{payload[:error_name]}: #{payload[:error_message]}")
        subject.failed(DummyEvent.new('failed.delayed_job', payload))
      end
    end

    describe 'exiting' do
      let(:payload) { {:quiet => true, :dj_worker => 'ExampleJob', :dj_name => 'EJob', :dj_time => @expected_time} }
      it 'call logger with the expected text' do
        expect(subject.logger).to receive(:info).with("#{@expected_time}: [Worker(#{payload[:dj_worker]})] Exiting...")
        subject.exiting(DummyEvent.new('exiting.delayed_job', payload))
      end
    end

    describe 'no_jobs_available' do
      let(:payload) { {:quiet => true, :dj_worker => 'ExampleJob', :dj_name => 'EJob', :dj_time => @expected_time} }
      it 'call logger with the expected text' do
        expect(subject.logger).to receive(:info).with("#{@expected_time}: [Worker(#{payload[:dj_worker]})] No more jobs available. Exiting")
        subject.no_jobs_available(DummyEvent.new('no_jobs_available.delayed_job', payload))
      end
    end

    describe 'jobs_processed' do
      let(:payload) { {:quiet => true, :dj_worker => 'ExampleJob', :dj_name => 'EJob', :dj_time => @expected_time, :count => 10, :realtime => 39.3039, :faild => 1} }
      it 'call logger with the expected text' do
        expect(subject.logger).to receive(:info).with("#{@expected_time}: [Worker(#{payload[:dj_worker]})] #{payload[:count]} jobs processed at #{format('%.4f', payload[:count] / payload[:realtime])} j/s, #{payload[:faild]} failed")
        subject.jobs_processed(DummyEvent.new('jobs_processed.delayed_job', payload))
      end
    end

    describe 'failure_callback_error' do
      let(:payload) { {:quiet => true, :dj_worker => 'ExampleJob', :dj_name => 'EJob', :dj_time => @expected_time, :error => 'error\ntest'} }
      it 'call logger with the expected text' do
        expect(subject.logger).to receive(:error).with("#{@expected_time}: [Worker(#{payload[:dj_worker]})] Error when running failure callback: #{payload[:error]}")
        subject.failure_callback_error(DummyEvent.new('failure_callback_error.delayed_job', payload))
      end
    end

    describe 'error_backtrace' do
      let(:payload) { {:quiet => true, :dj_worker => 'ExampleJob', :dj_name => 'EJob', :dj_time => @expected_time, :error_backtrace => 'error\ntest'} }
      it 'call logger with the expected text' do
        expect(subject.logger).to receive(:error).with("#{@expected_time}: [Worker(#{payload[:dj_worker]})] #{payload[:error_backtrace]}")
        subject.error_backtrace(DummyEvent.new('error_backtrace.delayed_job', payload))
      end
    end

    describe 'reserving_error' do
      let(:payload) { {:quiet => true, :dj_worker => 'ExampleJob', :dj_name => 'EJob', :dj_time => @expected_time, :error => 'error\ntest'} }
      it 'call logger with the expected text' do
        expect(subject.logger).to receive(:error).with("#{@expected_time}: [Worker(#{payload[:dj_worker]})] Error while reserving job: #{payload[:error]}")
        subject.reserving_error(DummyEvent.new('reserving_error.delayed_job', payload))
      end
    end
  end
end
