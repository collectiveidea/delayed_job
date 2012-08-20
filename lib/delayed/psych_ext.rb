if defined?(ActiveRecord)
  class ActiveRecord::Base
    # serialize to YAML
    def encode_with(coder)
      coder["attributes"] = @attributes
      coder.tag = ['!ruby/ActiveRecord', self.class.name].join(':')
    end
  end
end

class Delayed::PerformableMethod
  # serialize to YAML
  def encode_with(coder)
    coder.map = {
      "object" => object,
      "method_name" => method_name,
      "args" => args
    }
  end
end
