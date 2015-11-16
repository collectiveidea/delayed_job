require 'helper'

describe 'ActiveSupport::Concern' do
  describe 'ClassMethods' do
    module TestConcern
      extend ActiveSupport::Concern

      module ClassMethods
        def concern_test_method
        end
      end
    end

    class NotExtended
    end

    class Extended
      include TestConcern
    end

    it 'should not litter the ClassMethods' do
      expect(NotExtended).to_not respond_to(:concern_test_method)
      expect(Extended).to respond_to(:concern_test_method)
    end
  end
end
