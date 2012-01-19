if defined?(ActiveRecord)
  class ActiveRecord::Base
    yaml_as "tag:ruby.yaml.org,2002:ActiveRecord"

    def self.yaml_new(klass, tag, val)
      if ActiveRecord::VERSION::MAJOR == 3
        klass.unscoped.find(val['attributes'][klass.primary_key])
      else # Rails 2
        klass.with_exclusive_scope { klass.find(val['attributes'][klass.primary_key]) }
      end
    rescue ActiveRecord::RecordNotFound
      raise Delayed::DeserializationError, "ActiveRecord::RecordNotFound, class: #{klass} , primary key: #{val['attributes'][klass.primary_key]} "
    end

    def to_yaml_properties
      ['@attributes']
    end
  end
end