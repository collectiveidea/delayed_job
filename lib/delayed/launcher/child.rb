# frozen_string_literal: true

module Delayed
  module Launcher

    # This class is instantiated by the `Delayed::Launcher::Cluster` and
    # represents a single child worker process.
    #
    # At the core of this class is running an instance of `Delayed::Worker`
    # which gets created via the `start_worker` method.
    #
    # Code in this class is adapted from Puma (https://puma.io/)
    # See: `Puma::Cluster::Worker`
    class Child
      attr_reader :index,
                  :parent

      def initialize(index, parent, options, pipes, worker = nil)
        @index = index
        @parent = parent
        @options = options
        @check_pipe = pipes[:check_pipe]
        @child_write = pipes[:child_write]
        @fork_pipe = pipes[:fork_pipe]
        @wakeup = pipes[:wakeup]
        @worker = worker
      end

      def run
        title  = "delayed: cluster child #{index}: #{parent}"
        title += " [#{@options[:tag]}]" if @options[:tag] && !@options[:tag].empty?
        $0 = title

        Signal.trap 'SIGINT', 'IGNORE'
        Signal.trap 'SIGCHLD', 'DEFAULT'

        Thread.new do
          Delayed.set_thread_name 'wrkr check'
          @check_pipe.wait_readable
          logger.warn '! Detected parent died, dying'
          exit! 1
        end

        report_bundler_info

        # Invoke any child boot hooks so they can get
        # things in shape before booting the app.
        # @launcher.config.run_hooks :before_child_boot, index, @launcher.events

        begin
          worker = @worker ||= create_worker
        rescue Exception => e
          logger.warn '! Unable to start worker'
          logger.warn e.backtrace[0]
          exit 1
        end

        restart_worker = Queue.new << true << false

        setup_child_zero(worker, restart_worker) if index == 0

        Signal.trap 'SIGTERM' do
          @child_write << "e#{Process.pid}\n" rescue nil
          restart_worker.clear
          worker.stop
          restart_worker << false
        end

        begin
          @child_write << "b#{Process.pid}:#{index}\n"
        rescue SystemCallError, IOError
          Delayed.purge_interrupt_queue
          STDERR.puts 'Master seems to have exited, exiting.'
          return
        end

        while restart_worker.pop
          worker_thread = worker.start(true)
          stat_thread ||= Thread.new(@child_write) do |io|
            Delayed.set_thread_name 'stat pld'
            while true
              begin
                io << "p#{Process.pid}"
              rescue IOError
                Delayed.purge_interrupt_queue
                break
              end
              sleep @options[:child_check_interval]
            end
          end
          worker_thread.join
        end

        # Invoke any child shutdown hooks so they can prevent the child
        # exiting until any background operations are completed
        # @launcher.config.run_hooks :before_child_shutdown, index, @launcher.events
      ensure
        @child_write << "t#{Process.pid}\n" rescue nil
        @child_write.close
      end

      delegate :logger, to: :parent

    private

      def create_worker
        Delayed::Worker.new(@options)
      end

      def setup_child_zero(worker, restart_worker)
        restart_worker.clear
        child_pids = []
        Signal.trap 'SIGCHLD' do
          wakeup! if child_pids.reject! do |p|
            Process.wait(p, Process::WNOHANG) rescue true
          end
        end

        Thread.new do
          Delayed.set_thread_name 'wrkr fork'
          while (idx = @fork_pipe.gets)
            idx = idx.to_i
            if idx == -1 # stop worker
              if restart_worker.length > 0
                restart_worker.clear
                worker.begin_restart(true)
                # @launcher.config.run_hooks :before_refork, nil, @launcher.events
                Delayed.nakayoshi_gc(logger)
              end
            elsif idx == 0 # restart worker
              restart_worker << true << false
            else # fork child
              child_pids << pid = spawn_child(idx)
              @child_write << "f#{pid}:#{idx}\n" rescue nil
            end
          end
        end
      end

      def spawn_child(idx)
        Delayed::Worker.before_fork

        pid = fork do
          new_child = Child.new(idx,
                                parent,
                                @options,
                                { check_pipe: @check_pipe,
                                  child_write: @child_write },
                                @worker)
          new_child.run
        end

        unless pid
          logger.warn '! Complete inability to spawn new child processes detected'
          logger.warn '! Seppuku is the only choice.'
          exit! 1
        end

        Delayed::Worker.after_fork
        pid
      end

      # If we're not running under a Bundler context, then
      # report the info about the context we will be using
      def report_bundler_info
        return if ENV['BUNDLE_GEMFILE']
        if File.exist?('Gemfile')
          logger.info "+ Gemfile in context: #{File.expand_path('Gemfile')}"
        elsif File.exist?('gems.rb')
          logger.info "+ Gemfile in context: #{File.expand_path('gems.rb')}"
        end
      end

      def wakeup!
        return if !@wakeup || @wakeup.closed?
        @wakeup.write('!')
      rescue SystemCallError, IOError
        Delayed.purge_interrupt_queue
      end
    end
  end
end
