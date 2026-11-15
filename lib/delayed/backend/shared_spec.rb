require File.expand_path('../../../spec/sample_jobs', __dir__)

require 'active_support/core_ext/numeric/time'

shared_examples_for 'a delayed_job backend' do
  let(:worker) { Delayed::Worker.new }

  def create_job(opts = {})
    described_class.create(opts.merge(:payload_object => SimpleJob.new))
  end

  before do
    Delayed::Worker.max_priority = nil
    Delayed::Worker.min_priority = nil
    Delayed::Worker.default_priority = 99
    Delayed::Worker.delay_jobs = true
    Delayed::Worker.default_queue_name = 'default_tracking'
    SimpleJob.runs = 0
    described_class.delete_all
  end

  after do
    Delayed::Worker.reset
  end

  it 'sets run_at automatically if not set' do
    expect(described_class.create(:payload_object => ErrorJob.new).run_at).not_to be_nil
  end

  it 'does not set run_at automatically if already set' do
    later = described_class.db_time_now + 5.minutes
    job = described_class.create(:payload_object => ErrorJob.new, :run_at => later)
    expect(job.run_at).to be_within(1).of(later)
  end

  describe '#reload' do
    it 'reloads the payload' do
      job = described_class.enqueue :payload_object => SimpleJob.new
      expect(job.payload_object.object_id).not_to eq(job.reload.payload_object.object_id)
    end
  end

  describe 'enqueue' do
    context 'with a hash' do
      it "raises ArgumentError when handler doesn't respond_to :perform" do
        expect { described_class.enqueue(:payload_object => Object.new) }.to raise_error(ArgumentError)
      end

      it 'is able to set priority' do
        job = described_class.enqueue :payload_object => SimpleJob.new, :priority => 5
        expect(job.priority).to eq(5)
      end

      it 'uses default priority' do
        job = described_class.enqueue :payload_object => SimpleJob.new
        expect(job.priority).to eq(99)
      end

      it 'is able to set run_at' do
        later = described_class.db_time_now + 5.minutes
        job = described_class.enqueue :payload_object => SimpleJob.new, :run_at => later
        expect(job.run_at).to be_within(1).of(later)
      end

      it 'is able to set queue' do
        job = described_class.enqueue :payload_object => NamedQueueJob.new, :queue => 'tracking'
        expect(job.queue).to eq('tracking')
      end

      it 'uses default queue' do
        job = described_class.enqueue :payload_object => SimpleJob.new
        expect(job.queue).to eq(Delayed::Worker.default_queue_name)
      end

      it "uses the payload object's queue" do
        job = described_class.enqueue :payload_object => NamedQueueJob.new
        expect(job.queue).to eq(NamedQueueJob.new.queue_name)
      end
    end

    context 'with multiple arguments' do
      it "raises ArgumentError when handler doesn't respond_to :perform" do
        expect { described_class.enqueue(Object.new) }.to raise_error(ArgumentError)
      end

      it 'increases count after enqueuing items' do
        described_class.enqueue SimpleJob.new
        expect(described_class.count).to eq(1)
      end

      it 'is able to set priority [DEPRECATED]' do
        silence_warnings do
          job = described_class.enqueue SimpleJob.new, 5
          expect(job.priority).to eq(5)
        end
      end

      it 'uses default priority when it is not set' do
        @job = described_class.enqueue SimpleJob.new
        expect(@job.priority).to eq(99)
      end

      it 'is able to set run_at [DEPRECATED]' do
        silence_warnings do
          later = described_class.db_time_now + 5.minutes
          @job = described_class.enqueue SimpleJob.new, 5, later
          expect(@job.run_at).to be_within(1).of(later)
        end
      end

      it 'works with jobs in modules' do
        M::ModuleJob.runs = 0
        job = described_class.enqueue M::ModuleJob.new
        expect { job.invoke_job }.to change { M::ModuleJob.runs }.from(0).to(1)
      end

      it 'does not mutate the options hash' do
        options = {:priority => 1}
        described_class.enqueue SimpleJob.new, options
        expect(options).to eq(:priority => 1)
      end
    end

    context 'with delay_jobs = false' do
      before(:each) do
        Delayed::Worker.delay_jobs = false
      end

      it 'does not increase count after enqueuing items' do
        described_class.enqueue SimpleJob.new
        expect(described_class.count).to eq(0)
      end

      it 'invokes the enqueued job' do
        job = SimpleJob.new
        expect(job).to receive(:perform)
        described_class.enqueue job
      end

      it 'returns a job, not the result of invocation' do
        expect(described_class.enqueue(SimpleJob.new)).to be_instance_of(described_class)
      end
    end
  end

  describe 'callbacks' do
    before(:each) do
      CallbackJob.messages = []
    end

    %w[before success after].each do |callback|
      it "calls #{callback} with job" do
        job = described_class.enqueue(CallbackJob.new)
        expect(job.payload_object).to receive(callback).with(job)
        job.invoke_job
      end
    end

    it 'calls before and after callbacks' do
      job = described_class.enqueue(CallbackJob.new)
      expect(CallbackJob.messages).to eq(['enqueue'])
      job.invoke_job
      expect(CallbackJob.messages).to eq(%w[enqueue before perform success after])
    end

    it 'calls the after callback with an error' do
      job = described_class.enqueue(CallbackJob.new)
      expect(job.payload_object).to receive(:perform).and_raise(RuntimeError.new('fail'))

      expect { job.invoke_job }.to raise_error(RuntimeError)
      expect(CallbackJob.messages).to eq(['enqueue', 'before', 'error: RuntimeError', 'after'])
    end

    it 'calls error when before raises an error' do
      job = described_class.enqueue(CallbackJob.new)
      expect(job.payload_object).to receive(:before).and_raise(RuntimeError.new('fail'))
      expect { job.invoke_job }.to raise_error(RuntimeError)
      expect(CallbackJob.messages).to eq(['enqueue', 'error: RuntimeError', 'after'])
    end
  end

  describe 'payload_object' do
    it 'raises a DeserializationError when the job class is totally unknown' do
      job = described_class.new :handler => '--- !ruby/object:JobThatDoesNotExist {}'
      expect { job.payload_object }.to raise_error(Delayed::DeserializationError)
    end

    it 'raises a DeserializationError when the job struct is totally unknown' do
      job = described_class.new :handler => '--- !ruby/struct:StructThatDoesNotExist {}'
      expect { job.payload_object }.to raise_error(Delayed::DeserializationError)
    end

    it 'raises a DeserializationError when the YAML.load raises argument error' do
      job = described_class.new :handler => '--- !ruby/struct:GoingToRaiseArgError {}'
      expect(YAML).to receive(:load_dj).and_raise(ArgumentError)
      expect { job.payload_object }.to raise_error(Delayed::DeserializationError)
    end

    it 'raises a DeserializationError when the YAML.load raises syntax error' do
      # only test with Psych since the other YAML parsers don't raise a SyntaxError
      if YAML.parser.class.name !~ /syck|yecht/i
        job = described_class.new :handler => 'message: "no ending quote'
        expect { job.payload_object }.to raise_error(Delayed::DeserializationError)
      end
    end
  end

  describe 'reserve' do
    before do
      Delayed::Worker.max_run_time = 2.minutes
    end

    after do
      Time.zone = nil
    end

    it 'does not reserve failed jobs' do
      create_job :attempts => 50, :failed_at => described_class.db_time_now
      expect(described_class.reserve(worker)).to be_nil
    end

    it 'does not reserve jobs scheduled for the future' do
      create_job :run_at => described_class.db_time_now + 1.minute
      expect(described_class.reserve(worker)).to be_nil
    end

    it 'reserves jobs scheduled for the past' do
      job = create_job :run_at => described_class.db_time_now - 1.minute
      expect(described_class.reserve(worker)).to eq(job)
    end

    it 'reserves jobs scheduled for the past when time zones are involved' do
      Time.zone = 'America/New_York'
      job = create_job :run_at => described_class.db_time_now - 1.minute
      expect(described_class.reserve(worker)).to eq(job)
    end

    it 'does not reserve jobs locked by other workers' do
      job = create_job
      other_worker = Delayed::Worker.new
      other_worker.name = 'other_worker'
      expect(described_class.reserve(other_worker)).to eq(job)
      expect(described_class.reserve(worker)).to be_nil
    end

    it 'reserves open jobs' do
      job = create_job
      expect(described_class.reserve(worker)).to eq(job)
    end

    it 'reserves expired jobs' do
      job = create_job(:locked_by => 'some other worker', :locked_at => described_class.db_time_now - Delayed::Worker.max_run_time - 1.minute)
      expect(described_class.reserve(worker)).to eq(job)
    end

    it 'reserves own jobs' do
      job = create_job(:locked_by => worker.name, :locked_at => (described_class.db_time_now - 1.minutes))
      expect(described_class.reserve(worker)).to eq(job)
    end
  end

  describe 'reserve_batch' do
    def batch_workers(*names)
      names.map { |name| Delayed::Worker.named(name) }
    end

    def reload_job(job)
      described_class.find(job.id)
    end

    it 'reserves one job for each worker, in order, each locked under the name it is paired with' do
      jobs = Array.new(3) { |i| create_job(:priority => i) }
      workers = batch_workers('w0', 'w1', 'w2')
      reserved = described_class.reserve_batch(workers)
      expect(reserved.map(&:first)).to eq workers
      expect(reserved.map { |_, job| job.id }.uniq.size).to eq 3
      expect(reserved.map { |_, job| job.id }.sort).to eq jobs.map(&:id).sort
      reserved.each do |worker, job|
        expect(job.locked_by).to eq worker.name
        expect(reload_job(job).locked_by).to eq worker.name
        expect(reload_job(job).locked_at).not_to be_nil
      end
    end

    it 'gives the most urgent jobs to the first workers' do
      [5, 1, 3].each { |priority| create_job(:priority => priority) }
      reserved = described_class.reserve_batch(batch_workers('w0', 'w1', 'w2'))
      expect(reserved.map { |_, job| job.priority }).to eq [1, 3, 5]
    end

    it 'reserves for the first workers only when there are fewer jobs, leaving the rest out' do
      2.times { create_job }
      workers = batch_workers('w0', 'w1', 'w2', 'w3')
      reserved = described_class.reserve_batch(workers)
      expect(reserved.map(&:first)).to eq workers.first(2)
    end

    it 'reserves nothing when no job is available' do
      create_job(:run_at => described_class.db_time_now + 3600)
      expect(described_class.reserve_batch(batch_workers('w0', 'w1'))).to eq []
    end

    it 'never reserves a job locked by another worker' do
      taken = create_job(:locked_by => 'other', :locked_at => described_class.db_time_now)
      free = create_job
      reserved = described_class.reserve_batch(batch_workers('w0', 'w1'))
      expect(reserved.map { |_, job| job.id }).to eq [free.id]
      expect(reload_job(taken).locked_by).to eq 'other'
    end

    it 'returns a job already locked under a worker name again, to that worker (crash recovery)' do
      mine = create_job(:locked_by => 'w1', :locked_at => described_class.db_time_now)
      reserved = described_class.reserve_batch(batch_workers('w1'))
      expect(reserved.map { |worker, job| [worker.name, job.id] }).to eq [['w1', mine.id]]
    end

    it 'returns no job twice across batches while they stay locked' do
      4.times { create_job }
      first = described_class.reserve_batch(batch_workers('w0', 'w1'))
      second = described_class.reserve_batch(batch_workers('w2', 'w3'))
      ids = (first + second).map { |_, job| job.id }
      expect(ids.size).to eq 4
      expect(ids.uniq.size).to eq 4
    end

    it 'says whether a partial batch may leave jobs behind' do
      expect(described_class.partial_batch_may_leave_jobs?).to be(true).or be(false)
    end
  end

  context '#name' do
    it 'is the class name of the job that was enqueued' do
      expect(described_class.create(:payload_object => ErrorJob.new).name).to eq('ErrorJob')
    end

    it 'is the method that will be called if its a performable method object' do
      job = described_class.new(:payload_object => NamedJob.new)
      expect(job.name).to eq('named_job')
    end

    it 'is the instance method that will be called if its a performable method object' do
      job = Story.create(:text => '...').delay.save
      expect(job.name).to eq('Story#save')
    end

    it 'parses from handler on deserialization error' do
      job = Story.create(:text => '...').delay.text
      job.payload_object.object.destroy
      expect(job.reload.name).to eq('Delayed::PerformableMethod')
    end

    it 'is Unknown for a handler that is not valid YAML, rather than raising' do
      job = described_class.new(:handler => 'message: "no ending quote')
      expect(job.name).to eq('Unknown')
    end

    it 'is recomputed after a reload' do
      job = described_class.create(:payload_object => NamedJob.new)
      expect(job.name).to eq('named_job')
      job.handler = ErrorJob.new.to_yaml
      job.send(:reset)
      expect(job.name).to eq('ErrorJob')
    end
  end

  context 'worker prioritization' do
    after do
      Delayed::Worker.max_priority = nil
      Delayed::Worker.min_priority = nil
      Delayed::Worker.queue_attributes = {}
    end

    it 'fetches jobs ordered by priority' do
      10.times { described_class.enqueue SimpleJob.new, :priority => rand(10) }
      # Distinct names: reserve would return a worker's own locked job again.
      jobs = Array.new(10) { |i| described_class.reserve(Delayed::Worker.named("w#{i}")) }
      expect(jobs.compact.map(&:id).uniq.size).to eq(10)
      jobs.each_cons(2) do |a, b|
        expect(a.priority).to be <= b.priority
      end
    end

    it 'only finds jobs greater than or equal to min priority' do
      min = 5
      Delayed::Worker.min_priority = min
      [4, 5, 6].sort_by { |_i| rand }.each { |i| create_job :priority => i }
      2.times do
        job = described_class.reserve(worker)
        expect(job.priority).to be >= min
        job.destroy
      end
      expect(described_class.reserve(worker)).to be_nil
    end

    it 'only finds jobs less than or equal to max priority' do
      max = 5
      Delayed::Worker.max_priority = max
      [4, 5, 6].sort_by { |_i| rand }.each { |i| create_job :priority => i }
      2.times do
        job = described_class.reserve(worker)
        expect(job.priority).to be <= max
        job.destroy
      end
      expect(described_class.reserve(worker)).to be_nil
    end

    it 'sets job priority based on queue_attributes configuration' do
      Delayed::Worker.queue_attributes = {'job_tracking' => {:priority => 4}}
      job = described_class.enqueue :payload_object => NamedQueueJob.new
      expect(job.priority).to eq(4)
    end

    it 'sets job priority based on the passed in priority overrideing queue_attributes configuration' do
      Delayed::Worker.queue_attributes = {'job_tracking' => {:priority => 4}}
      job = described_class.enqueue :payload_object => NamedQueueJob.new, :priority => 10
      expect(job.priority).to eq(10)
    end
  end

  describe 'locked_jobs' do
    it 'returns the jobs locked by the given worker, or nil when unsupported' do
      mine = create_job(:locked_by => 'worker1', :locked_at => described_class.db_time_now)
      create_job(:locked_by => 'worker2', :locked_at => described_class.db_time_now)
      create_job
      jobs = described_class.locked_jobs('worker1')
      skip 'this backend does not implement locked_jobs' if jobs.nil?
      expect(jobs.map(&:id)).to eq [mine.id]
    end
  end

  describe 'locked_jobs and clear_locks! with an array of names' do
    it 'returns the jobs locked by any of the named workers, or nil when unsupported' do
      one = create_job(:locked_by => 'w1 slot:0', :locked_at => described_class.db_time_now)
      two = create_job(:locked_by => 'w1 slot:1', :locked_at => described_class.db_time_now)
      create_job(:locked_by => 'w2 slot:0', :locked_at => described_class.db_time_now)
      create_job
      jobs = described_class.locked_jobs(['w1 slot:0', 'w1 slot:1', 'w1 slot:2'])
      skip 'this backend does not implement locked_jobs' if jobs.nil?
      expect(jobs.map(&:id)).to match_array [one.id, two.id]
    end

    it 'clears the locks of all the named workers, and only theirs' do
      mine = Array.new(2) { |i| create_job(:locked_by => "w1 slot:#{i}", :locked_at => described_class.db_time_now) }
      other = create_job(:locked_by => 'w2 slot:0', :locked_at => described_class.db_time_now)
      described_class.clear_locks!(['w1 slot:0', 'w1 slot:1'])
      expect(mine.map { |job| described_class.find(job.id).locked_by }).to eq [nil, nil]
      expect(described_class.find(other.id).locked_by).to eq 'w2 slot:0'
    end
  end

  describe 'Delayed::Worker.recover_jobs_of (a dead worker process)' do
    let(:exit_error) { Delayed::ProcessExitError.new('dj.1', 77, double('Process::Status', :signaled? => true, :termsig => 9, :exitstatus => nil)) }

    def dead_job(locked_by, attrs = {})
      described_class.create!({:payload_object => SimpleJob.new, :locked_by => locked_by, :locked_at => described_class.db_time_now}.merge(attrs))
    end

    def reloaded(job)
      described_class.find(job.id)
    end

    before { skip 'this backend does not implement locked_jobs' if described_class.locked_jobs('nobody').nil? }

    it "counts each of the dead process' jobs as a failed attempt and unlocks it, leaving others alone" do
      names = Delayed::Worker.lock_names('dj.1 ', 77, 2, 1) # Two threads, two slots each.
      mine = [dead_job(names[0]), dead_job(names[3])]
      other = dead_job('dj.2 pid:88 thread:0 slot:0')
      expect(Delayed::Worker.recover_jobs_of(names, exit_error)).to eq 2
      mine.map { |job| reloaded(job) }.each do |job|
        expect([job.attempts, job.locked_by, job.locked_at]).to eq [1, nil, nil]
        expect(job.last_error).to match(/was killed by signal 9/)
        expect(job.run_at).to be > described_class.db_time_now
      end
      expect(reloaded(other).locked_by).to eq 'dj.2 pid:88 thread:0 slot:0'
    end

    it 'only unlocks a job that had already failed permanently' do
      failed_at = described_class.db_time_now - 60
      job = dead_job('dj.1 pid:77', :attempts => 3, :failed_at => failed_at, :last_error => 'original')
      expect(Delayed::Worker.recover_jobs_of(['dj.1 pid:77'], exit_error)).to eq 0
      job = reloaded(job)
      expect([job.attempts, job.last_error, job.locked_by]).to eq [3, 'original', nil]
      expect(job.failed_at).to be_within(1).of(failed_at)
    end

    it 'reschedules a job whose payload can no longer be loaded, with the default back-off' do
      job = dead_job('dj.1 pid:77', :handler => "--- !ruby/object:NoSuchJobClassAnyMore\nx: 1\n")
      expect(Delayed::Worker.recover_jobs_of(['dj.1 pid:77'], exit_error)).to eq 1
      job = reloaded(job)
      expect([job.attempts, job.locked_by, job.failed_at]).to eq [1, nil, nil]
      expect(job.run_at).to be_within(3).of(described_class.db_time_now + 6)
    end
  end

  context 'clear_locks!' do
    before do
      @job = create_job(:locked_by => 'worker1', :locked_at => described_class.db_time_now)
    end

    it 'clears locks for the given worker' do
      described_class.clear_locks!('worker1')
      expect(described_class.reserve(worker)).to eq(@job)
    end

    it 'does not clear locks for other workers' do
      described_class.clear_locks!('different_worker')
      expect(described_class.reserve(worker)).to be_nil
      expect(described_class.find(@job.id).locked_by).to eq('worker1')
    end
  end

  context 'unlock' do
    before do
      @job = create_job(:locked_by => 'worker', :locked_at => described_class.db_time_now)
    end

    it 'clears locks' do
      @job.unlock
      expect(@job.locked_by).to be_nil
      expect(@job.locked_at).to be_nil
    end
  end

  context 'large handler' do
    before do
      text = 'Lorem ipsum dolor sit amet. ' * 1000
      @job = described_class.enqueue Delayed::PerformableMethod.new(text, :length, {})
    end

    it 'has an id' do
      expect(@job.id).not_to be_nil
    end
  end

  context 'named queues' do
    context 'when worker has one queue set' do
      before(:each) do
        worker.queues = ['large']
      end

      it 'only works off jobs which are from its queue' do
        expect(SimpleJob.runs).to eq(0)

        create_job(:queue => 'large')
        create_job(:queue => 'small')
        worker.work_off

        expect(SimpleJob.runs).to eq(1)
      end
    end

    context 'when worker has two queue set' do
      before(:each) do
        worker.queues = %w[large small]
      end

      it 'only works off jobs which are from its queue' do
        expect(SimpleJob.runs).to eq(0)

        create_job(:queue => 'large')
        create_job(:queue => 'small')
        create_job(:queue => 'medium')
        create_job
        worker.work_off

        expect(SimpleJob.runs).to eq(2)
      end
    end

    context 'when worker does not have queue set' do
      before(:each) do
        worker.queues = []
      end

      it 'works off all jobs' do
        expect(SimpleJob.runs).to eq(0)

        create_job(:queue => 'one')
        create_job(:queue => 'two')
        create_job
        worker.work_off

        expect(SimpleJob.runs).to eq(3)
      end
    end
  end

  context 'max_attempts' do
    before(:each) do
      @job = described_class.enqueue SimpleJob.new
    end

    it 'is not defined' do
      expect(@job.max_attempts).to be_nil
    end

    it 'uses the max_attempts value on the payload when defined' do
      expect(@job.payload_object).to receive(:max_attempts).and_return(99)
      expect(@job.max_attempts).to eq(99)
    end
  end

  describe '#max_run_time' do
    before(:each) { @job = described_class.enqueue SimpleJob.new }

    it 'is not defined' do
      expect(@job.max_run_time).to be_nil
    end

    it 'results in a default run time when not defined' do
      expect(worker.max_run_time(@job)).to eq(Delayed::Worker::DEFAULT_MAX_RUN_TIME)
    end

    it 'uses the max_run_time value on the payload when defined' do
      expect(@job.payload_object).to receive(:max_run_time).and_return(30.minutes)
      expect(@job.max_run_time).to eq(30.minutes)
    end

    it 'results in an overridden run time when defined' do
      expect(@job.payload_object).to receive(:max_run_time).and_return(45.minutes)
      expect(worker.max_run_time(@job)).to eq(45.minutes)
    end

    it 'job set max_run_time can not exceed default max run time' do
      expect(@job.payload_object).to receive(:max_run_time).and_return(Delayed::Worker::DEFAULT_MAX_RUN_TIME + 60)
      expect(worker.max_run_time(@job)).to eq(Delayed::Worker::DEFAULT_MAX_RUN_TIME)
    end
  end

  describe 'destroy_failed_jobs' do
    context 'with a SimpleJob' do
      before(:each) do
        @job = described_class.enqueue SimpleJob.new
      end

      it 'is not defined' do
        expect(@job.destroy_failed_jobs?).to be true
      end

      it 'uses the destroy failed jobs value on the payload when defined' do
        expect(@job.payload_object).to receive(:destroy_failed_jobs?).and_return(false)
        expect(@job.destroy_failed_jobs?).to be false
      end
    end

    context 'with a job that raises DserializationError' do
      before(:each) do
        @job = described_class.new :handler => '--- !ruby/struct:GoingToRaiseArgError {}'
      end

      it 'falls back reasonably' do
        expect(YAML).to receive(:load_dj).and_raise(ArgumentError)
        expect(@job.destroy_failed_jobs?).to be true
      end
    end
  end

  describe 'yaml serialization' do
    context 'when serializing jobs' do
      it 'raises error ArgumentError for new records' do
        story = Story.new(:text => 'hello')
        if story.respond_to?(:new_record?)
          expect { story.delay.tell }.to raise_error(
            ArgumentError,
            "job cannot be created for non-persisted record: #{story.inspect}"
          )
        end
      end

      it 'raises error ArgumentError for destroyed records' do
        story = Story.create(:text => 'hello')
        story.destroy
        expect { story.delay.tell }.to raise_error(
          ArgumentError,
          "job cannot be created for non-persisted record: #{story.inspect}"
        )
      end
    end

    context 'when reload jobs back' do
      it 'reloads changed attributes' do
        story = Story.create(:text => 'hello')
        job = story.delay.tell
        story.text = 'goodbye'
        story.save!
        expect(job.reload.payload_object.object.text).to eq('goodbye')
      end

      it 'raises deserialization error for destroyed records' do
        story = Story.create(:text => 'hello')
        job = story.delay.tell
        story.destroy
        expect { job.reload.payload_object }.to raise_error(Delayed::DeserializationError)
      end
    end
  end

  describe 'worker integration' do
    before do
      Delayed::Job.delete_all
      SimpleJob.runs = 0
    end

    describe 'running a job' do
      it 'fails after Worker.max_run_time' do
        Delayed::Worker.max_run_time = 1.second
        job = Delayed::Job.create :payload_object => LongRunningJob.new
        worker.run(job)
        expect(job.error).to_not be_nil
        expect(job.reload.last_error).to match(/expired/)
        expect(job.reload.last_error).to match(/Delayed::Worker\.max_run_time is only 1 second/)
        expect(job.attempts).to eq(1)
      end

      context 'when the job raises a deserialization error' do
        after do
          Delayed::Worker.destroy_failed_jobs = true
        end

        it 'marks the job as failed' do
          Delayed::Worker.destroy_failed_jobs = false
          job = described_class.create! :handler => '--- !ruby/object:JobThatDoesNotExist {}'
          expect_any_instance_of(described_class).to receive(:destroy_failed_jobs?).and_return(false)
          worker.work_off
          job.reload
          expect(job).to be_failed
        end
      end
    end

    describe 'failed jobs' do
      before do
        @job = Delayed::Job.enqueue(ErrorJob.new, :run_at => described_class.db_time_now - 1)
      end

      after do
        # reset default
        Delayed::Worker.destroy_failed_jobs = true
      end

      it 'records last_error when destroy_failed_jobs = false, max_attempts = 1' do
        Delayed::Worker.destroy_failed_jobs = false
        Delayed::Worker.max_attempts = 1
        worker.run(@job)
        @job.reload
        expect(@job.error).to_not be_nil
        expect(@job.last_error).to match(/did not work/)
        expect(@job.attempts).to eq(1)
        expect(@job).to be_failed
      end

      it 're-schedules jobs after failing' do
        worker.work_off
        @job.reload
        expect(@job.last_error).to match(/did not work/)
        expect(@job.last_error).to match(/sample_jobs.rb:\d+:in [`'](ErrorJob#)?perform'/)
        expect(@job.attempts).to eq(1)
        expect(@job.run_at).to be > Delayed::Job.db_time_now - 10.minutes
        expect(@job.run_at).to be < Delayed::Job.db_time_now + 10.minutes
        expect(@job.locked_by).to be_nil
        expect(@job.locked_at).to be_nil
      end

      it 're-schedules jobs with handler provided time if present' do
        job = Delayed::Job.enqueue(CustomRescheduleJob.new(99.minutes))
        worker.run(job)
        job.reload

        expect((Delayed::Job.db_time_now + 99.minutes - job.run_at).abs).to be < 1
      end

      it "does not fail when the triggered error doesn't have a message" do
        error_with_nil_message = StandardError.new
        expect(error_with_nil_message).to receive(:message).twice.and_return(nil)
        expect(@job).to receive(:invoke_job).and_raise error_with_nil_message
        expect { worker.run(@job) }.not_to raise_error
      end
    end

    context 'reschedule' do
      before do
        @job = Delayed::Job.create :payload_object => SimpleJob.new
      end

      shared_examples_for 'any failure more than Worker.max_attempts times' do
        context "when the job's payload has a #failure hook" do
          before do
            @job = Delayed::Job.create :payload_object => OnPermanentFailureJob.new
            expect(@job.payload_object).to respond_to(:failure)
          end

          it 'runs that hook' do
            expect(@job.payload_object).to receive(:failure)
            worker.reschedule(@job)
          end

          it 'handles error in hook' do
            Delayed::Worker.destroy_failed_jobs = false
            @job.payload_object.raise_error = true
            expect { worker.reschedule(@job) }.not_to raise_error
            expect(@job.failed_at).to_not be_nil
          end
        end

        context "when the job's payload has no #failure hook" do
          # It's a little tricky to test this in a straightforward way,
          # because putting a not_to receive expectation on
          # @job.payload_object.failure makes that object incorrectly return
          # true to payload_object.respond_to? :failure, which is what
          # reschedule uses to decide whether to call failure. So instead, we
          # just make sure that the payload_object as it already stands doesn't
          # respond_to? failure, then shove it through the iterated reschedule
          # loop and make sure we don't get a NoMethodError (caused by calling
          # that nonexistent failure method).

          before do
            expect(@job.payload_object).not_to respond_to(:failure)
          end

          it 'does not try to run that hook' do
            expect do
              Delayed::Worker.max_attempts.times { worker.reschedule(@job) }
            end.not_to raise_exception
          end
        end
      end

      context 'and we want to destroy jobs' do
        after do
          Delayed::Worker.destroy_failed_jobs = true
        end

        it_behaves_like 'any failure more than Worker.max_attempts times'

        it 'is destroyed if it failed more than Worker.max_attempts times' do
          expect(@job).to receive(:destroy)
          Delayed::Worker.max_attempts.times { worker.reschedule(@job) }
        end

        it 'is destroyed if the job has destroy failed jobs set' do
          Delayed::Worker.destroy_failed_jobs = false
          expect(@job).to receive(:destroy_failed_jobs?).and_return(true)
          expect(@job).to receive(:destroy)
          Delayed::Worker.max_attempts.times { worker.reschedule(@job) }
        end

        it 'is not destroyed if failed fewer than Worker.max_attempts times' do
          expect(@job).not_to receive(:destroy)
          (Delayed::Worker.max_attempts - 1).times { worker.reschedule(@job) }
        end
      end

      context "and we don't want to destroy jobs" do
        before do
          Delayed::Worker.destroy_failed_jobs = false
        end

        after do
          Delayed::Worker.destroy_failed_jobs = true
        end

        it_behaves_like 'any failure more than Worker.max_attempts times'

        context 'and destroy failed jobs is false' do
          it 'is failed if it failed more than Worker.max_attempts times' do
            expect(@job.reload).not_to be_failed
            Delayed::Worker.max_attempts.times { worker.reschedule(@job) }
            expect(@job.reload).to be_failed
          end

          it 'is not failed if it failed fewer than Worker.max_attempts times' do
            (Delayed::Worker.max_attempts - 1).times { worker.reschedule(@job) }
            expect(@job.reload).not_to be_failed
          end
        end

        context 'and destroy failed jobs for job is false' do
          before do
            Delayed::Worker.destroy_failed_jobs = true
          end

          it 'is failed if it failed more than Worker.max_attempts times' do
            expect(@job).to receive(:destroy_failed_jobs?).and_return(false)
            expect(@job.reload).not_to be_failed
            Delayed::Worker.max_attempts.times { worker.reschedule(@job) }
            expect(@job.reload).to be_failed
          end

          it 'is not failed if it failed fewer than Worker.max_attempts times' do
            (Delayed::Worker.max_attempts - 1).times { worker.reschedule(@job) }
            expect(@job.reload).not_to be_failed
          end
        end
      end
    end
  end
end

# For backends implementing lock_heartbeats?, touch_locks,
# destroy_if_locked_by and save_if_locked_by. Use with 'a delayed_job backend'.
# Examples running a real Delayed::Dispatcher (threads, prefetch, shutdown,
# and lock heartbeats with prefetch where supported) against the backend.
# Set Delayed::Worker.backend to the described class around them.
shared_examples_for 'a delayed_job backend running a dispatcher' do
  let(:dj_log) { Concurrent::Array.new }
  let(:dj_errors) { Concurrent::Array.new }
  let(:dj_events) { Concurrent::Array.new }

  before do
    described_class.delete_all
    GateJob.reset
    FuzzJob.completed.clear
    Delayed::Worker.sleep_delay = 0.05
    Delayed::Worker.on_thread_error = ->(error, info) { dj_errors << [error, info] }
    @dj_running = []
    @dj_subscription = ActiveSupport::Notifications.subscribe('jobs_released.delayed_job') { |*args| dj_events << args.last }
  end

  after do
    GateJob.release = true
    @dj_running.each do |dispatcher, thread|
      dispatcher.stop
      thread.join(10)
    end
    ActiveSupport::Notifications.unsubscribe(@dj_subscription)
    Delayed::Worker.reset
  end

  def dj_dispatcher(threads, prefix = nil)
    Delayed::Dispatcher.new(:threads => threads).tap do |dispatcher|
      dispatcher.name_prefix = prefix if prefix
      [dispatcher, *dispatcher.workers].each do |speaker|
        allow(speaker).to receive(:say) { |text, level = 'info'| dj_log << [level, text] }
      end
    end
  end

  def dj_run_in_thread(dispatcher)
    Thread.new { dispatcher.run }.tap do |thread|
      thread.report_on_exception = false
      @dj_running << [dispatcher, thread]
    end
  end

  def dj_wait_until(timeout = 10)
    Timeout.timeout(timeout) { sleep 0.02 until yield }
  end

  def dj_enqueue(payload, priority = 0)
    described_class.create!(:payload_object => payload, :priority => priority)
  end

  def dj_locked
    described_class.all.to_a.select(&:locked_by)
  end

  def dj_reloaded(job)
    described_class.find(job.id)
  end

  def dj_lost_locks
    dj_log.map(&:last).grep(/lock expired and another worker reserved it/)
  end

  [0, 2].each do |prefetch|
    it "runs every job exactly once with two dispatchers competing (prefetch #{prefetch})" do
      Delayed::Worker.prefetch = prefetch
      Delayed::Worker.exit_on_complete = true
      40.times { |i| dj_enqueue(FuzzJob.new(i, rand * 0.02)) }
      runs = [dj_dispatcher(3, 'a '), dj_dispatcher(3, 'b ')].map { |dispatcher| Thread.new { dispatcher.run } }
      Timeout.timeout(60) { runs.each(&:join) }
      expect(FuzzJob.completed.size).to eq 40
      expect(FuzzJob.completed.values).to all(eq 1)
      expect(described_class.count).to eq 0
      expect(dj_errors).to be_empty
    end
  end

  it 'holds jobs queued behind running ones, each locked under a slot name of its own' do
    Delayed::Worker.prefetch = 1
    4.times { |i| dj_enqueue(GateJob.new(i)) }
    dj_run_in_thread(dj_dispatcher(2))
    dj_wait_until { GateJob.started.size == 2 && dj_locked.size == 4 }
    names = dj_locked.map(&:locked_by)
    expect(names.uniq.size).to eq 4
    expect(names).to all(match(/ slot:[01]\z/))
    GateJob.release = true
    dj_wait_until { described_class.count.zero? }
    expect(GateJob.finished.sort).to eq [0, 1, 2, 3]
  end

  it 'releases queued jobs at once on shutdown, attempts unchanged, while running ones finish' do
    Delayed::Worker.prefetch = 2
    jobs = Array.new(3) { |i| dj_enqueue(GateJob.new(i)) }
    dispatcher = dj_dispatcher(1)
    thread = dj_run_in_thread(dispatcher)
    dj_wait_until { GateJob.started.size == 1 && dj_locked.size == 3 }
    dispatcher.stop
    dj_wait_until { dj_locked.size == 1 }
    queued = jobs.map { |job| dj_reloaded(job) }.reject(&:locked_by)
    expect(queued.map { |job| [job.attempts, job.locked_at] }).to eq [[0, nil], [0, nil]]
    # Published once the locks are cleared.
    dj_wait_until { dj_events.map { |payload| payload[:reason] }.include?('shutdown') }
    GateJob.release = true
    Timeout.timeout(10) { thread.join }
    expect(described_class.count).to eq 2
    expect(dj_locked).to be_empty
  end

  it 'releases a running job interrupted by quit, attempts unchanged' do
    job = dj_enqueue(GateJob.new(:a))
    dispatcher = dj_dispatcher(1)
    thread = dj_run_in_thread(dispatcher)
    dj_wait_until { GateJob.started.size == 1 }
    dispatcher.quit
    Timeout.timeout(10) { thread.join }
    expect(GateJob.interrupted).to eq [:a]
    job = dj_reloaded(job)
    expect([job.attempts, job.locked_by, job.locked_at]).to eq [0, nil, nil]
  end

  context 'with lock heartbeats' do
    before do
      skip 'this backend does not support lock heartbeats' unless described_class.lock_heartbeats?
      Delayed::Worker.lock_heartbeat_interval = 0.1
      Delayed::Worker.lock_timeout = 0.5
    end

    it 'keeps the locks of queued jobs fresh while they wait, so no other worker takes them' do
      Delayed::Worker.prefetch = 2
      3.times { |i| dj_enqueue(GateJob.new(i)) }
      dj_run_in_thread(dj_dispatcher(1))
      dj_wait_until { GateJob.started.size == 1 && dj_locked.size == 3 }
      sleep 3 * Delayed::Worker.lock_timeout # Unrefreshed, they would have expired twice over.
      expect(dj_locked.map(&:locked_at)).to all(be > described_class.db_time_now - Delayed::Worker.lock_timeout)
      expect(described_class.reserve(Delayed::Worker.named('intruder'), Delayed::Worker.lock_expiry)).to be_nil
      GateJob.release = true
      dj_wait_until { described_class.count.zero? }
      expect(GateJob.finished.sort).to eq [0, 1, 2]
      expect(dj_lost_locks).to be_empty
      expect(dj_errors).to be_empty
    end

    [false, true].each do |dynamic|
      it "runs every job exactly once with two dispatchers competing (prefetch_dynamic #{dynamic})" do
        Delayed::Worker.prefetch = 2
        Delayed::Worker.prefetch_dynamic = dynamic
        Delayed::Worker.exit_on_complete = true
        40.times { |i| dj_enqueue(FuzzJob.new(i, rand * 0.2)) } # Queued for about lock_timeout.
        runs = [dj_dispatcher(2, 'a '), dj_dispatcher(2, 'b ')].map { |dispatcher| Thread.new { dispatcher.run } }
        Timeout.timeout(60) { runs.each(&:join) }
        expect(FuzzJob.completed.size).to eq 40
        expect(FuzzJob.completed.values).to all(eq 1)
        expect(described_class.count).to eq 0
        expect(dj_lost_locks).to be_empty
        expect(dj_errors).to be_empty
      end
    end

    it 'releases the jobs queued behind a stuck job, so another thread runs them meanwhile' do
      Delayed::Worker.prefetch = 1
      # One poll fills the slots in rounds, in priority order: the stuck job
      # runs on one thread, `behind` is queued behind it.
      stuck = dj_enqueue(StuckJob.new(4, 1), 0) # Ignores its 1s timeout for 4s.
      dj_enqueue(FuzzJob.new(:quick, 0), 1)
      dj_enqueue(FuzzJob.new(:behind, 0), 2)
      dj_enqueue(FuzzJob.new(:other, 0), 3)
      dj_run_in_thread(dj_dispatcher(2))
      dj_wait_until(3) { FuzzJob.completed.key?(:behind) }
      expect(dj_reloaded(stuck)).not_to be_nil # Still stuck.
      expect(dj_events.map { |payload| payload[:reason] }).to include 'stuck job'
      expect(FuzzJob.completed.values).to all(eq 1)
    end

    it 'times a job started while the heartbeat keeps failing out at its lock expiry' do
      Delayed::Worker.prefetch = 1
      allow(described_class).to receive(:touch_locks).and_raise(IOError, 'database gone')
      dj_run_in_thread(dj_dispatcher(1))
      sleep 2 * Delayed::Worker.lock_timeout # No refresh gets through.
      job = dj_enqueue(LongRunningJob.new)
      dj_wait_until { dj_reloaded(job).attempts == 1 }
      expect(dj_reloaded(job).last_error).to match(/execution expired/)
      expect(dj_errors.map { |_, info| info[:context] }.uniq).to eq ['Lock heartbeat']
    end

    it 'releases a queued job whose lock expired while the heartbeat was failing, then runs it once' do
      Delayed::Worker.prefetch = 1
      dj_enqueue(GateJob.new(:first))
      dj_enqueue(GateJob.new(:queued))
      allow(described_class).to receive(:touch_locks).and_raise(IOError, 'database gone')
      dj_run_in_thread(dj_dispatcher(1))
      dj_wait_until { GateJob.started.size == 1 && dj_locked.size == 2 }
      sleep 2 * Delayed::Worker.lock_timeout
      GateJob.release = true
      dj_wait_until { described_class.count.zero? }
      expect(dj_events.map { |payload| payload[:reason] }).to include 'lock expired in queue'
      expect(GateJob.finished.sort).to eq %i(first queued)
    end

    it 'stops the heartbeat with the dispatcher' do
      Delayed::Worker.prefetch = 1
      dj_enqueue(GateJob.new(:a))
      touches = Concurrent::AtomicFixnum.new
      allow(described_class).to(receive(:touch_locks).and_wrap_original do |original, names|
        touches.increment
        original.call(names)
      end)
      dispatcher = dj_dispatcher(1)
      thread = dj_run_in_thread(dispatcher)
      dj_wait_until { touches.value > 0 }
      GateJob.release = true
      dispatcher.stop
      Timeout.timeout(10) { thread.join }
      expect(dispatcher.instance_variable_get(:@heartbeat)).not_to be_alive
      beats = touches.value
      sleep 3 * Delayed::Worker.lock_heartbeat_interval
      expect(touches.value).to eq beats
    end
  end
end

shared_examples_for 'a delayed_job backend supporting lock heartbeats' do
  let(:now) { described_class.db_time_now }

  before { SimpleJob.runs = 0 }

  def locked(name, locked_at = described_class.db_time_now)
    described_class.create!(:payload_object => SimpleJob.new, :locked_by => name, :locked_at => locked_at)
  end

  def reload_job(job)
    described_class.where(:id => job.id).first
  end

  # As reserve would after the lock expired.
  def take_over(job, name = 'w2')
    described_class.where(:id => job.id).update_all(:locked_by => name, :locked_at => described_class.db_time_now)
  end

  it 'supports lock heartbeats' do
    expect(described_class.lock_heartbeats?).to be true
  end

  describe 'touch_locks' do
    it "refreshes the given workers' locks only" do
      mine = locked('w1', now - 600)
      also_mine = locked('w2', now - 600)
      other = locked('w3', now - 600)
      unlocked = described_class.create!(:payload_object => SimpleJob.new)

      expect(described_class.touch_locks(%w[w1 w2])).to eq 2
      expect(reload_job(mine).locked_at).to be_within(5).of(now)
      expect(reload_job(also_mine).locked_at).to be_within(5).of(now)
      expect(reload_job(other).locked_at).to be_within(1).of(now - 600)
      expect(reload_job(unlocked).locked_at).to be_nil
    end
  end

  describe 'reserve with a short lock expiry' do
    let(:worker) { Delayed::Worker.new.tap { |w| w.name = 'w2' } }

    it 'reserves a job whose lock is older than the expiry' do
      job = locked('w1', now - 120)
      expect(described_class.reserve(worker, 60).id).to eq job.id
      expect(reload_job(job).locked_by).to eq 'w2'
    end

    it 'does not reserve a job whose lock was refreshed' do
      locked('w1', now - 120)
      described_class.touch_locks(['w1'])
      expect(described_class.reserve(worker, 60)).to be_nil
    end
  end

  describe 'destroy_if_locked_by' do
    it 'destroys the job while the worker holds its lock' do
      job = locked('w1')
      expect(job.destroy_if_locked_by('w1')).to be true
      expect(reload_job(job)).to be_nil
    end

    it 'leaves the job alone once another worker holds its lock' do
      job = locked('w1')
      take_over(job)
      expect(job.destroy_if_locked_by('w1')).to be false
      expect(reload_job(job).locked_by).to eq 'w2'
    end
  end

  describe 'save_if_locked_by' do
    it 'saves the job while the worker holds its lock' do
      job = locked('w1')
      job.attempts = 3
      job.run_at = now + 3600
      job.unlock
      expect(job.save_if_locked_by('w1')).to be true
      saved = reload_job(job)
      expect([saved.attempts, saved.locked_by, saved.locked_at]).to eq [3, nil, nil]
      expect(saved.run_at).to be_within(5).of(now + 3600)
    end

    it 'saves nothing once another worker holds its lock' do
      job = locked('w1')
      take_over(job)
      job.attempts = 3
      job.unlock
      expect(job.save_if_locked_by('w1')).to be false
      saved = reload_job(job)
      expect([saved.attempts, saved.locked_by]).to eq [0, 'w2']
    end
  end

  describe 'a worker that lost its lock' do
    let(:stale) { Delayed::Worker.new.tap { |w| w.name = 'w1' } }

    it 'does not delete the job when it finishes' do
      job = locked('w1')
      take_over(job)
      expect(stale.run(job)).to be true
      expect(reload_job(job).locked_by).to eq 'w2'
    end

    it 'does not reschedule the job when it fails' do
      job = described_class.create!(:payload_object => ErrorJob.new, :locked_by => 'w1', :locked_at => now)
      take_over(job)
      expect(stale.run(job)).to be false
      saved = reload_job(job)
      expect([saved.attempts, saved.locked_by, saved.last_error]).to eq [0, 'w2', nil]
    end

    it 'does not fail or delete the job permanently' do
      job = described_class.create!(:payload_object => ErrorJob.new, :locked_by => 'w1', :locked_at => now,
                                    :attempts => Delayed::Worker.max_attempts - 1)
      take_over(job)
      stale.run(job)
      saved = reload_job(job)
      expect(saved).not_to be_nil
      expect([saved.failed_at, saved.locked_by]).to eq [nil, 'w2']
    end
  end
end
