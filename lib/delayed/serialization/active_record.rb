class ActiveRecord::Base
  yaml_as "tag:ruby.yaml.org,2002:ActiveRecord"

# This doesn't work if uploading yamled objects from another database
# def self.yaml_new(klass, tag, val)
#    klass.unscoped.find(val['attributes'][klass.primary_key])
#  rescue ActiveRecord::RecordNotFound
#    foo = klass.new
#    val['attributes'].each do |k, v|
#      foo[k] = v
#    end
#    foo
#  end
  
  def persistent?
    primary_key = self['attributes'][self.class.primary_key]
    if primary_key_value = self['attributes'][primary_key]
      obj = self.class.where(primary_key.to_sym => primary_key_value).select(primary_key).first
      obj ? true : false
    end
  end

  def to_yaml_properties
    ['@attributes']
  end
end
