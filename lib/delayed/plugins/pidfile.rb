require 'fileutils'

module Delayed
  module Plugins
    class Pidfile < Delayed::Plugin
      callbacks do |lifecycle|
        lifecycle.around(:execute) do |worker, &block|
          dir = File.dirname(pidfile)
          FileUtils.mkdir_p(dir)

          File.write(pidfile, "#{Process.pid}\n", mode => 'wx')
          begin
            block.call(worker)
          ensure
            File.unlink(pidfile)
          end
        end
      end

      def self.pidfile
        "#{Rails.root}/tmp/delayed_job.pid"
      end
    end
  end
end
