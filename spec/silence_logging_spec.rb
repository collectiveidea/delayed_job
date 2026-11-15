require 'helper'
require_relative 'processes/helpers'

# Delayed::Worker.silence_logging, on a real Active Record backend (an SQLite
# file) logging its SQL.
describe 'Delayed::Worker.silence_logging' do
  include ProcessHelpers

  let(:job_class) { Delayed::Backend::SqliteFile::Job }
  let(:sql_log) { StringIO.new }
  let(:sql_logger) { ActiveSupport::Logger.new(sql_log).tap { |l| l.level = Logger::DEBUG } }

  around do |example|
    previous = ActiveRecord::Base.logger
    Delayed::Worker.backend = job_class
    ActiveRecord::Base.logger = sql_logger
    example.run
  ensure
    ActiveRecord::Base.logger = previous
    Delayed::Worker.reset
    Delayed::Worker.backend = :test
  end

  before do
    SimpleJob.runs = 0
    allow(Delayed::Worker).to receive(:logger).and_return(Logger.new(nil))
  end

  def run_to_completion(dispatcher)
    silence_say(*and_workers(dispatcher))
    super
  end

  # SQL statements logged, by kind.
  def logged(kind)
    sql_log.string.gsub(/\e\[[\d;]*m/, '').lines.grep(/\b#{kind}\b/)
  end

  # Statements of the reservation query: finding candidates, then locking one.
  def reservations
    logged('SELECT').grep(/locked_at IS NULL OR locked_at </) +
      logged('UPDATE').grep(/SET "locked_at" = \?, "locked_by" = \? WHERE \(id = /)
  end

  # Lock refreshes (see SqliteFile::Job.touch_locks).
  def lock_refreshes
    logged('UPDATE').grep(/SET "locked_at" = \? WHERE "delayed_jobs"."locked_by" (IN|=) /)
  end

  it 'is off by default, and reset by Worker.reset' do
    expect(Delayed::Worker.silence_logging).to be false
    Delayed::Worker.silence_logging = true
    Delayed::Worker.reset
    expect(Delayed::Worker.silence_logging).to be false
  end

  it 'is set by Worker.new options' do
    Delayed::Worker.new(:silence_logging => true)
    expect(Delayed::Worker.silence_logging).to be true
  end

  context 'when off' do
    it 'logs the reservation queries' do
      job_class.create!(:payload_object => SimpleJob.new)
      run_to_completion(Delayed::Dispatcher.new(:threads => 2))
      expect(reservations.size).to be >= 3 # Two to reserve the job, one to find no more.
    end
  end

  context 'when off, with lock heartbeats' do
    it 'logs the lock refreshes' do
      Delayed::Worker.lock_heartbeat_interval = 0.05
      Delayed::Worker.lock_timeout = 1
      job_class.create!(:payload_object => ProcessJobs::SleepJob.new('long', 0.3))
      run_to_completion(Delayed::Dispatcher.new(:threads => 1))
      expect(lock_refreshes.size).to be >= 2
    end
  end

  context 'when on' do
    before { Delayed::Worker.silence_logging = true }

    it 'does not log the queries of an idle poll' do
      run_to_completion(Delayed::Dispatcher.new(:threads => 2))
      expect(reservations).to be_empty
      # Clearing the workers' locks as they exit is not polling.
      expect(logged('SELECT') + logged('INSERT') + logged('DELETE')).to be_empty
    end

    it "still logs jobs' own queries, and finishing jobs" do
      job_class.create!(:payload_object => ProcessJobs::SleepJob.new('logged', 0))
      run_to_completion(Delayed::Dispatcher.new(:threads => 2))
      expect(logged('INSERT').grep(/runs/).size).to eq 1 # The job's own query.
      expect(logged('DELETE').size).to eq 1 # Finishing the job.
      expect(reservations).to be_empty
    end

    it 'does not log lock refreshes' do
      Delayed::Worker.lock_heartbeat_interval = 0.05
      Delayed::Worker.lock_timeout = 1
      touched = 0
      allow(job_class).to(receive(:touch_locks).and_wrap_original do |m, names|
        touched += 1
        m.call(names)
      end)
      job_class.create!(:payload_object => ProcessJobs::SleepJob.new('long', 0.3))
      run_to_completion(Delayed::Dispatcher.new(:threads => 1))
      expect(touched).to be >= 2
      expect(lock_refreshes).to be_empty
    end

    it 'silences the polling thread only: jobs running meanwhile still log' do
      job_class.create!(:payload_object => ProcessJobs::SleepJob.new('a', 0.2))
      job_class.create!(:payload_object => ProcessJobs::SleepJob.new('b', 0.2))
      run_to_completion(Delayed::Dispatcher.new(:threads => 2, :sleep_delay => 0.01))
      expect(logged('INSERT').grep(/runs/).size).to eq 2
    end

    it 'restores the log level after a failed poll' do
      calls = 0
      allow(job_class).to receive(:reserve_batch).and_wrap_original do |m, *args|
        raise IOError, 'db hiccup' if (calls += 1) == 1
        m.call(*args)
      end
      allow(job_class).to receive(:recover_from)
      run_to_completion(Delayed::Dispatcher.new(:threads => 1))
      expect(sql_logger.level).to eq Logger::DEBUG
      ActiveRecord::Base.logger.debug('after')
      expect(sql_log.string).to include 'after'
    end

    it 'silences polls of Worker#work_off too' do
      job_class.create!(:payload_object => SimpleJob.new)
      worker = Delayed::Worker.new
      allow(worker).to receive(:say)
      expect(worker.work_off).to eq [1, 0]
      expect(reservations).to be_empty
      expect(logged('DELETE').size).to eq 1
    end
  end

  describe 'Delayed::Job.silence_logging (the default backend hook)' do
    it 'silences ActiveRecord::Base.logger below WARN in the block' do
      job_class.silence_logging do
        ActiveRecord::Base.logger.info('quiet')
        ActiveRecord::Base.logger.warn('loud')
      end
      expect(sql_log.string).not_to include 'quiet'
      expect(sql_log.string).to include 'loud'
    end

    it 'returns the result of the block' do
      expect(job_class.silence_logging { 42 }).to eq 42
    end

    it 'leaves other threads logging' do
      other = nil
      job_class.silence_logging do
        other = Thread.new { ActiveRecord::Base.logger.info('other thread') }
        other.join
      end
      expect(sql_log.string).to include 'other thread'
    end

    it 'just yields without an Active Record logger' do
      ActiveRecord::Base.logger = nil
      expect(job_class.silence_logging { :ran }).to eq :ran
    end

    it 'just yields with a logger that cannot silence' do
      ActiveRecord::Base.logger = Logger.new(sql_log)
      expect(job_class.silence_logging { :ran }).to eq :ran
    end

    it 'just yields without Active Record' do
      hide_const('ActiveRecord::Base')
      expect(Delayed::Backend::Test::Job.silence_logging { :ran }).to eq :ran
    end

    it 'can be overridden by backends' do
      calls = []
      allow(job_class).to receive(:silence_logging) { |&block|
        calls << :silenced
        block.call
      }
      Delayed::Worker.silence_logging = true
      run_to_completion(Delayed::Dispatcher.new(:threads => 1))
      expect(calls).not_to be_empty
    end
  end
end
