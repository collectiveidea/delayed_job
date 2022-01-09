# frozen_string_literal: true

require 'delayed/launcher/cluster'

module Delayed
  module Launcher
    class PooledCluster < Cluster

      attr_reader :pools

      def initialize(launcher, options)
        @pools = options.delete(:pools)
        super
      end

    private

      def mode
        'pooled_cluster'
      end

      def setup_workers
        pools.each do |queues, pool_worker_count|
          options = @options.merge(:queues => queues)
          pool_worker_count.times { add_worker(options) }
        end
      end

      # TODO: CoW forking needs to fork from each worker pool.
      # because different pool jobs will have diff characteristics
      # (Disable with an option?)
      # Is each pool it's own cluster?

      # TODO: not yet supported
      def increment_worker_count
        # @worker_count += 1
      end

      # TODO: not yet supported
      def decrement_worker_count
        # @worker_count -= 1 if @worker_count >= 2
      end


      # OLD
      # def add_worker(options)
      #   worker_name = get_name(@worker_index)
      #   worker_pid = spawn_worker(worker_name, options)
      #
      #   queues = options[:queues]
      #   queue_msg = " queues=#{queues.empty? ? '*' : queues.join(',')}" if queues
      #   logger.info "Worker #{worker_name} started - pid #{worker_pid}#{queue_msg}"
      #
      #   @workers << WorkerHandle.new(@worker_index, worker_pid, worker_name, queues)
      #   @worker_index += 1
      # end
      #
      #
      #
    end
  end
end
