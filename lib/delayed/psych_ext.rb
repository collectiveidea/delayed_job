if defined?(ActiveRecord)
  ActiveRecord::Base.class_eval do
    if instance_methods.include?(:encode_with)
      def encode_with_override(coder)
        encode_with_without_override(coder)
        coder.tag = "!ruby/ActiveRecord:#{self.class.name}" if coder.respond_to?(:tag=)
      end
      alias_method :encode_with_without_override, :encode_with
      alias_method :encode_with, :encode_with_override
    else
      def encode_with(coder)
        coder["attributes"] = attributes
        coder.tag = "!ruby/ActiveRecord:#{self.class.name}" if coder.respond_to?(:tag=)
      end
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

module Psych
  module Visitors
    class YAMLTree
      def visit_Class(klass)
        @emitter.scalar klass.name, nil, '!ruby/class', false, false, Nodes::Scalar::SINGLE_QUOTED
      end
    end

    class ToRuby
      def visit_Psych_Nodes_Scalar(o)
        @st[o.anchor] = o.value if o.anchor

        if klass = Psych.load_tags[o.tag]
          instance = klass.allocate

          if instance.respond_to?(:init_with)
            coder = Psych::Coder.new(o.tag)
            coder.scalar = o.value
            instance.init_with coder
          end

          return instance
        end

        return o.value if o.quoted
        return @ss.tokenize(o.value) unless o.tag

        case o.tag
        when '!binary', 'tag:yaml.org,2002:binary'
          o.value.unpack('m').first
        when '!str', 'tag:yaml.org,2002:str'
          o.value
        when "!ruby/object:DateTime"
          require 'date'
          @ss.parse_time(o.value).to_datetime
        when "!ruby/object:Complex"
          Complex(o.value)
        when "!ruby/object:Rational"
          Rational(o.value)
        when "!ruby/class", "!ruby/module"
          resolve_class o.value
        when "tag:yaml.org,2002:float", "!float"
          Float(@ss.tokenize(o.value))
        when "!ruby/regexp"
          o.value =~ /^\/(.*)\/([mixn]*)$/
          source  = $1
          options = 0
          lang    = nil
          ($2 || '').split('').each do |option|
            case option
            when 'x' then options |= Regexp::EXTENDED
            when 'i' then options |= Regexp::IGNORECASE
            when 'm' then options |= Regexp::MULTILINE
            when 'n' then options |= Regexp::NOENCODING
            else lang = option
            end
          end
          Regexp.new(*[source, options, lang].compact)
        when "!ruby/range"
          args = o.value.split(/([.]{2,3})/, 2).map { |s|
            accept Nodes::Scalar.new(s)
          }
          args.push(args.delete_at(1) == '...')
          Range.new(*args)
        when /^!ruby\/sym(bol)?:?(.*)?$/
          o.value.to_sym
        else
          @ss.tokenize o.value
        end
      end

      def visit_Psych_Nodes_Mapping_with_class(object)
        return revive(Psych.load_tags[object.tag], object) if Psych.load_tags[object.tag]

        case object.tag
        when /^!ruby\/ActiveRecord:(.+)$/
          klass = resolve_class($1)
          payload = Hash[*object.children.map { |c| accept c }]
          id = payload["attributes"][klass.primary_key]
          begin
            klass.unscoped.find(id)
          rescue ActiveRecord::RecordNotFound
            raise Delayed::DeserializationError
          end
        when /^!ruby\/Mongoid:(.+)$/
          klass = resolve_class($1)
          payload = Hash[*object.children.map { |c| accept c }]
          begin
            klass.find(payload["attributes"]["_id"])
          rescue Mongoid::Errors::DocumentNotFound
            raise Delayed::DeserializationError
          end
        when /^!ruby\/DataMapper:(.+)$/
          klass = resolve_class($1)
          payload = Hash[*object.children.map { |c| accept c }]
          begin
            primary_keys = klass.properties.select { |p| p.key? }
            key_names = primary_keys.map { |p| p.name.to_s }
            klass.get!(*key_names.map { |k| payload["attributes"][k] })
          rescue DataMapper::ObjectNotFoundError
            raise Delayed::DeserializationError
          end
        else
          visit_Psych_Nodes_Mapping_without_class(object)
        end
      end
      alias_method_chain :visit_Psych_Nodes_Mapping, :class

      def resolve_class_with_constantize(klass_name)
        klass_name.constantize
      rescue
        resolve_class_without_constantize(klass_name)
      end
      alias_method_chain :resolve_class, :constantize
    end
  end
end
