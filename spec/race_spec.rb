require 'helper'
require_relative 'processes/helpers'

# Races between a dispatcher's threads, its shutdown and its lock heartbeat,
# exercised many times with random timings. Each prints its seed on failure.
describe 'Races' do
  let(:reported) { Concurrent::Array.new }
  let(:seed) { Integer(ENV.fetch('RACE_SEED', Random.new_seed)) }

  before do
    Delayed::Job.delete_all
    FuzzJob.completed = Concurrent::Map.new
    Delayed::Worker.on_thread_error = ->(error, info) { reported << [error, info] }
  end

  after { Delayed::Backend::Test::Job.before_destroy = nil }

  def quiet_dispatcher(options)
    Delayed::Dispatcher.new(options).tap do |d|
      silence_say(*and_workers(d))
    end
  end

  # R4
  describe 'stopping or quitting at a random moment' do
    it 'finishes each job once, or releases it unlocked with its attempts unchanged' do
      random = Random.new(seed)
      30.times do |round|
        Delayed::Job.delete_all
        FuzzJob.completed = Concurrent::Map.new
        Delayed::Worker.shutdown_timeout = [nil, 0, 0.05].sample(:random => random)
        jobs = Array.new(8) { |i| Delayed::Job.enqueue(FuzzJob.new(i, random.rand * 0.1)) }
        d = quiet_dispatcher(:threads => 3, :sleep_delay => 0.01)
        # Deleting a finished job takes a moment, as in a database: once it
        # has started, the job is done and must never be released.
        past_job = Queue.new
        # Not allow_any_instance_of: rspec-mocks sets it up on each instance
        # as it is first called, which isn't thread-safe (JRuby).
        Delayed::Backend::Test::Job.before_destroy = lambda do |job|
          past_job << job.id
          sleep 0.005
        end
        thread = Thread.new { d.run }
        sleep random.rand * 0.15
        how = %i(stop quit).sample(:random => random)
        d.public_send(how)
        Timeout.timeout(10) { thread.join }

        context = "round #{round} (seed #{seed}, #{how}, shutdown_timeout #{Delayed::Worker.shutdown_timeout.inspect})"
        left = Delayed::Job.all
        done = Array.new(past_job.size) { past_job.pop }
        expect(left.map(&:id) & done).to be_empty, "#{context}: jobs #{left.map(&:id) & done} were released while being deleted"

        jobs.each_with_index do |job, key|
          runs = FuzzJob.completed.fetch(key, 0)
          if left.include?(job)
            job.reload
            # A job interrupted right after its last line still counts as run:
            # it is released and runs again (jobs must be safe to retry).
            expect(runs).to be <= 1, "#{context}: job #{key} completed #{runs} times and is still queued"
            expect([job.locked_by, job.locked_at, job.attempts]).to eq([nil, nil, 0]), "#{context}: job #{key} left #{job.inspect}"
          else
            expect(runs).to eq(1), "#{context}: job #{key} was deleted after completing #{runs} times"
          end
        end
        expect(reported).to be_empty, "#{context}: #{reported.map { |e, i| [e.class, i[:context]] }}"
      end
    end
  end

  # R6
  describe 'lock heartbeats racing job finishes', :processes do
    include ProcessHelpers

    around do |example|
      Delayed::Worker.backend = Delayed::Backend::SqliteFile::Job
      example.run
    ensure
      Delayed::Worker.backend = :test
    end

    it 'never loses a lock or leaves a job behind, with refreshes all the time' do
      Delayed::Worker.lock_heartbeat_interval = 0.01
      Delayed::Worker.lock_timeout = 0.5
      Delayed::Worker.exit_on_complete = true
      job_class = Delayed::Backend::SqliteFile::Job
      touches = 0
      allow(job_class).to(receive(:touch_locks).and_wrap_original do |m, names|
        touches += 1
        m.call(names)
      end)
      messages = Concurrent::Array.new # Appended to from every worker thread.
      d = Delayed::Dispatcher.new(:threads => 4, :sleep_delay => 0.01)
      allow(d).to receive(:say)
      d.workers.each { |w| allow(w).to receive(:say) { |text, *| messages << text } }
      60.times { |i| job_class.create!(:payload_object => FuzzJob.new(i, rand * 0.02)) }
      Timeout.timeout(30) { d.run }

      expect(job_class.count).to eq 0
      expect(FuzzJob.completed.values).to all(eq 1)
      expect(FuzzJob.completed.size).to eq 60
      expect(touches).to be > 5
      expect(messages.grep(/lock expired and another worker reserved it/)).to be_empty
      expect(reported).to be_empty
    end

    it 'does not refresh a lock that another worker took over' do
      job_class = Delayed::Backend::SqliteFile::Job
      job = job_class.create!(:payload_object => SimpleJob.new, :locked_by => 'other process', :locked_at => job_class.db_time_now - 60)
      d = Delayed::Dispatcher.new(:threads => 2)
      allow(d).to receive(:say)
      Delayed::Worker.lock_heartbeat_interval = 10
      Delayed::Worker.lock_timeout = 30
      d.send(:heartbeat)
      expect(job_class.find(job.id).locked_at).to be < job_class.db_time_now - 59
    end
  end

  # R7
  describe 'a job enqueued while the dispatcher is stopping' do
    it 'is neither started nor locked' do
      GateJob.reset
      Delayed::Job.enqueue(GateJob.new(:running))
      d = quiet_dispatcher(:threads => 2, :sleep_delay => 0.01)
      thread = Thread.new { d.run }
      Timeout.timeout(5) { GateJob.started.pop }
      d.stop
      late = Delayed::Job.enqueue(GateJob.new(:late))
      sleep 0.2 # An idle thread would have picked it up by now.
      GateJob.release = true
      Timeout.timeout(10) { thread.join }

      expect(GateJob.finished).to eq [:running]
      late.reload
      expect([late.locked_by, late.locked_at, late.attempts]).to eq [nil, nil, 0]
      expect(reported).to be_empty
    ensure
      GateJob.release = true
    end
  end
end
