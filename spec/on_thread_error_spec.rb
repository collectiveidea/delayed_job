require 'helper'

describe 'Delayed::Worker.on_thread_error' do
  let(:reported) { Concurrent::Array.new }
  let(:log) { StringIO.new }

  before do
    Delayed::Job.delete_all
    allow(Delayed::Worker).to receive(:logger).and_return(Logger.new(log))
    Delayed::Worker.on_thread_error = ->(error, info) { reported << [error, info] }
  end

  after do
    Delayed::Worker.reset
  end

  def contexts
    reported.map { |_, info| info[:context] }
  end

  it 'is nil by default, and reset by Worker.reset' do
    Delayed::Worker.reset
    expect(Delayed::Worker.on_thread_error).to be_nil
  end

  describe '.thread_error' do
    it 'calls the handler with the error and the info' do
      error = IOError.new('x')
      Delayed::Worker.thread_error(error, :context => 'Test', :worker => 'w')
      expect(reported).to eq [[error, {:context => 'Test', :worker => 'w'}]]
    end

    it 'calls a one-argument handler with the error only' do
      errors = []
      Delayed::Worker.on_thread_error = ->(error) { errors << error }
      error = IOError.new('x')
      Delayed::Worker.thread_error(error, :context => 'Test')
      expect(errors).to eq [error]
    end

    it 'calls a handler taking no arguments with none' do
      calls = 0
      Delayed::Worker.on_thread_error = -> { calls += 1 }
      Delayed::Worker.thread_error(IOError.new('x'), :context => 'Test')
      expect(calls).to eq 1
      expect(log.string).not_to include 'on_thread_error'
    end

    it 'calls an object whose #call takes no arguments with none' do
      handler = Class.new do
        attr_reader :calls

        def call
          @calls = (@calls || 0) + 1
        end
      end.new
      Delayed::Worker.on_thread_error = handler
      Delayed::Worker.thread_error(IOError.new('x'), :context => 'Test')
      expect(handler.calls).to eq 1
    end

    it 'calls a proc without parameters' do
      calls = 0
      Delayed::Worker.on_thread_error = proc { calls += 1 }
      Delayed::Worker.thread_error(IOError.new('x'), :context => 'Test')
      expect(calls).to eq 1
    end

    it 'calls a handler with an optional argument with the error and the info' do
      received = nil
      Delayed::Worker.on_thread_error = ->(error, info = nil) { received = [error, info] }
      error = IOError.new('x')
      Delayed::Worker.thread_error(error, :context => 'Test')
      expect(received).to eq [error, {:context => 'Test'}]
    end

    it 'accepts any callable' do
      handler = double('handler', :arity => 2)
      expect(handler).to receive(:call).with(kind_of(IOError), {:context => 'Test'})
      Delayed::Worker.on_thread_error = handler
      Delayed::Worker.thread_error(IOError.new, :context => 'Test')
    end

    describe 'handlers that are not Procs' do
      let(:error) { IOError.new('x') }

      it 'calls an object whose #call takes the error and the info' do
        handler = Class.new do
          attr_reader :calls

          def call(error, info)
            (@calls ||= []) << [error, info]
          end
        end.new
        Delayed::Worker.on_thread_error = handler
        Delayed::Worker.thread_error(error, :context => 'Test')
        expect(handler.calls).to eq [[error, {:context => 'Test'}]]
      end

      it 'calls an object whose #call takes the error only' do
        handler = Class.new do
          attr_reader :calls

          def call(error)
            (@calls ||= []) << error
          end
        end.new
        Delayed::Worker.on_thread_error = handler
        Delayed::Worker.thread_error(error, :context => 'Test')
        expect(handler.calls).to eq [error]
      end

      it 'calls an object whose #call takes optional or splat arguments with both' do
        handler = Class.new do
          attr_reader :calls

          def call(*args)
            (@calls ||= []) << args
          end
        end.new
        Delayed::Worker.on_thread_error = handler
        Delayed::Worker.thread_error(error, :context => 'Test')
        expect(handler.calls).to eq [[error, {:context => 'Test'}]]
      end

      it 'calls a Method object' do
        calls = []
        receiver = Object.new
        receiver.define_singleton_method(:report) { |e| calls << e }
        Delayed::Worker.on_thread_error = receiver.method(:report)
        Delayed::Worker.thread_error(error, :context => 'Test')
        expect(calls).to eq [error]
      end

      it 'calls a module function given as a Method' do
        mod = Module.new do
          def self.calls
            @calls ||= []
          end

          def self.report(error, info)
            calls << [error, info]
          end
        end
        Delayed::Worker.on_thread_error = mod.method(:report)
        Delayed::Worker.thread_error(error, :context => 'Test')
        expect(mod.calls).to eq [[error, {:context => 'Test'}]]
      end

      it 'logs and ignores a handler that does not respond to #call' do
        Delayed::Worker.on_thread_error = Object.new
        expect { Delayed::Worker.thread_error(error, :context => 'Test') }.not_to raise_error
        expect(log.string).to include 'Error in Delayed::Worker.on_thread_error: NameError'
      end

      it 'does not log anything for a working handler' do
        Delayed::Worker.on_thread_error = Class.new { def call(_e, _i); end }.new
        Delayed::Worker.thread_error(error, :context => 'Test')
        expect(log.string).not_to include 'on_thread_error'
      end
    end

    it 'publishes a thread_error event as well' do
      events = payloads_of(:thread_error)
      error = IOError.new('x')
      Delayed::Worker.thread_error(error, :context => 'Test')
      expect(events).to eq [{:context => 'Test', :error => error}]
    end

    it 'does nothing more without a handler' do
      Delayed::Worker.on_thread_error = nil
      expect { Delayed::Worker.thread_error(IOError.new, :context => 'Test') }.not_to raise_error
    end

    it 'logs and ignores errors raised by the handler' do
      Delayed::Worker.on_thread_error = ->(_error, _info) { raise 'tracker down' }
      expect { Delayed::Worker.thread_error(IOError.new, :context => 'Test') }.not_to raise_error
      expect(log.string).to include 'Error in Delayed::Worker.on_thread_error: RuntimeError: tracker down'
    end

    it 'does not need a logger to ignore a failing handler' do
      allow(Delayed::Worker).to receive(:logger).and_return(nil)
      Delayed::Worker.on_thread_error = ->(_error, _info) { raise 'tracker down' }
      expect { Delayed::Worker.thread_error(IOError.new, :context => 'Test') }.not_to raise_error
    end
  end

  describe 'reported errors' do
    let(:dispatcher) { Delayed::Dispatcher.new(:threads => 2, :sleep_delay => 0.01, :quiet => true) }

    before do
      silence_say(*and_workers(dispatcher))
    end

    it 'include failed reservations' do
      calls = 0
      allow(Delayed::Job).to receive(:reserve_batch) do
        raise IOError, 'db hiccup' if (calls += 1) == 1
        []
      end
      allow(Delayed::Job).to receive(:recover_from)
      run_to_completion
      error, info = reported.first
      expect(error.message).to eq 'db hiccup'
      expect(info).to eq(:context => 'Reservation', :dispatcher => dispatcher.name, :worker => nil)
    end

    it 'include the FatalBackendError that stops the dispatcher, after each failed reservation' do
      allow(Delayed::Job).to receive(:reserve_batch).and_raise(IOError, 'down')
      allow(Delayed::Job).to receive(:recover_from)
      expect { Timeout.timeout(5) { dispatcher.run } }.to raise_error(Delayed::FatalBackendError)
      expect(contexts).to eq(['Reservation'] * 10 + ['Dispatcher'])
      expect(reported.last.first).to be_a Delayed::FatalBackendError
    end

    it 'include errors raised by :loop plugins' do
      dispatcher
      Delayed::Worker.lifecycle.before(:loop) { raise ArgumentError, 'plugin bug' }
      expect { Timeout.timeout(5) { dispatcher.run } }.to raise_error(ArgumentError, 'plugin bug')
      expect(contexts).to eq ['Dispatcher']
    end

    it 'include a crashed worker thread, once' do
      Delayed::Job.enqueue(SimpleJob.new)
      dispatcher.workers.each { |w| allow(w).to receive(:perform_job).and_raise(NoMemoryError, 'escaped') }
      expect { run_to_completion }.to raise_error(NoMemoryError)
      expect(contexts).to eq ['Worker thread']
      expect(dispatcher.workers.map(&:name)).to include reported.first.last[:worker]
    end

    it 'include failed lock heartbeats' do
      allow(Delayed::Job).to receive(:lock_heartbeats?).and_return(true)
      allow(Delayed::Job).to receive(:touch_locks).and_raise(IOError, 'db hiccup')
      Delayed::Worker.lock_heartbeat_interval = 0.05
      Delayed::Worker.lock_timeout = 1
      thread = Thread.new { dispatcher.run }
      sleep 0.2
      dispatcher.stop
      Timeout.timeout(5) { thread.join }
      expect(contexts.uniq).to eq ['Lock heartbeat']
    end

    it 'include failing failure hooks' do
      payload = OnPermanentFailureJob.new
      payload.raise_error = true
      def payload.max_attempts
        1
      end

      def payload.perform
        raise 'job failed'
      end
      job = Delayed::Job.enqueue(payload)
      worker = Delayed::Worker.new
      allow(worker).to receive(:say)
      expect(worker.work_off).to eq [0, 1]
      error, info = reported.find { |_, i| i[:context] == 'Failure hook' }
      expect(error.message).to eq 'did not work'
      expect(info[:worker]).to eq worker.name
      expect(info[:job]).to eq job
    end

    it 'include failed recovery of a dead worker process' do
      launcher = Delayed::Launcher::Forking.new(:processes => 2)
      allow(launcher).to receive(:logger).and_return(Logger.new(nil))
      allow(Delayed::Worker.backend).to receive(:before_fork)
      allow(Delayed::Worker).to receive(:recover_jobs_of).and_raise(IOError, 'connection refused')
      status = double('Process::Status', :success? => false, :signaled? => true, :termsig => 9)
      launcher.send(:recover_jobs_of_worker, 'delayed_job.1', 99, {}, status)
      expect(reported.map(&:last)).to eq [{:context => 'Recovering jobs', :worker => 'delayed_job.1', :pid => 99}]
    end

    it 'exclude job errors' do
      Delayed::Job.enqueue(ErrorJob.new)
      run_to_completion
      expect(reported).to be_empty
    end

    it 'exclude signal exceptions that stop the dispatcher' do
      dispatcher
      Delayed::Worker.lifecycle.before(:loop) { raise Interrupt }
      expect { Timeout.timeout(5) { dispatcher.run } }.to raise_error(Interrupt)
      expect(reported).to be_empty
    end
  end
end
