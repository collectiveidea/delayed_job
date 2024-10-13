require 'helper'
require 'active_job'
require "byebug"

describe 'a Rails active job backend' do
  module JobBuffer
    class << self
      def clear
        values.clear
      end

      def add(value)
        values << value
      end

      def values
        @values ||= []
      end
    end
  end

  class TestJob < ActiveJob::Base
    queue_as :integration_tests

    def perform(message)
      JobBuffer.add(message)
    end
  end

  let(:worker) { Delayed::Worker.new(sleep_delay: 0.5, queues: %w(integration_tests)) }

  before do
    ActiveJob::Base.queue_adapter = :delayed_job
  end

  after do
    JobBuffer.clear
  end

  it 'enqueus and executes the job' do
    start_worker do
      job = TestJob.perform_later('hello')
      sleep 2
      expect(JobBuffer.values).to eq(['hello'])
    end
  end

  it 'runs multiple queued jobs' do
    start_worker do
      ActiveJob.perform_all_later(TestJob.new('Rails'), TestJob.new('World'))
      sleep 2
      expect(JobBuffer.values).to eq(['Rails', 'World'])
    end
  end

  private
    def start_worker(&)
      thread = Thread.new { worker.start }
      yield
    ensure
      worker.stop
      thread.join
    end
end
