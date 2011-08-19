class ActiveRecord::Base
  yaml_as "tag:ruby.yaml.org,2002:ActiveRecord"

  def self.yaml_new(klass, tag, val)
    klass.unscoped.find(val['attributes'][klass.primary_key])
  rescue ActiveRecord::RecordNotFound
    foo = klass.new
    val['attributes'].each do |k, v|
      meth = "#{k}="
      foo.send(meth, v) if foo.respond_to?(meth)
    end
    foo
  end


  def to_yaml_properties
    ['@attributes']
  end

  def ghost_dj?
    false if self.class.find(self.id)
  rescue ActiveRecord::RecordNotFound
    true
  end

end
