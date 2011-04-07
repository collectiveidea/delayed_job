module Delayed
  module Manager
    class Local
      def initialize(options={})
      end

      def qty
        Rush::Box.new.processes.filter(:cmdline => /rake jobs:work/).size
      end

      def scale_up
        Rush::Box.new[RAILS_ROOT].bash "rake jobs:work", :background => true
      end

      def scale_down
        $exit = true
      end
    end
  end
end