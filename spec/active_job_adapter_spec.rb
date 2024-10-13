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

  it 'enqueus and executes the job' do
    thread = Thread.new { worker.start }

    ActiveJob::Base.queue_adapter = :delayed_job
    job = TestJob.perform_later('hello')
    sleep 2

    expect(JobBuffer.values).to eq(['hello'])
  ensure
    worker.stop
    thread.join
  end

  it 'runs multiple queued jobs' do
    JobBuffer.clear
    thread = Thread.new { worker.start }

    ActiveJob::Base.queue_adapter = :delayed_job
    ActiveJob.perform_all_later(TestJob.new('Rails'), TestJob.new('World'))
    sleep 2

    expect(JobBuffer.values).to eq(['Rails', 'World'])
  ensure
    worker.stop
    thread.join
  end
end
