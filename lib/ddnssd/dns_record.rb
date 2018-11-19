require 'resolv'
require 'freedom_patches/dns_name'
require 'ddnssd/error'

module DDNSSD
  class DNSRecord

    class InvalidStateError < DDNSSD::Error; end

    attr_reader :ttl, :type, :data

    def initialize(name, ttl, type, *data)
      if name.is_a?(Resolv::DNS::Name)
        @name = name
      else
        @name = Resolv::DNS::Name.create(name)
      end

      @ttl, @type = ttl, type

      puts "#{name.inspect}, #{ttl.inspect}, #{type.inspect}, #{data.inspect}" if data.empty?

      data_class = Resolv::DNS::Resource::IN.const_get(type)
      @data = if data[0]&.is_a?(data_class)
        data[0]
      else
        # ensure all names in the record are either absolute or relative
        case type
        when :PTR, :CNAME
          data_class.new(
            Resolv::DNS::Name.create(
              @name.absolute? && !absolute_name?(data[0]) ? "#{data[0]}." : data[0]
            )
          )
        when :SRV
          data_class.new(
            *data[0, 3],
            @name.absolute? && !absolute_name?(data[3]) ? "#{data[3]}." : data[3]
          )
        else
          data_class.new(*data)
        end
      end
    end

    def self.new_absolute_from_relative(base_domain, rr)
      absolute_data =
        case rr.type
        when :A, :AAAA
          [rr.data.address]
        when :PTR, :CNAME
          ["#{rr.data.name}.#{base_domain}"]
        when :TXT
          rr.data.strings
        when :SRV
          [rr.data.priority, rr.data.weight, rr.data.port, "#{rr.data.target}.#{base_domain}"]
        else
          raise RuntimeError, "Unknown RR type #{rr.type.inspect}"
        end

      new("#{rr.name}.#{base_domain}", rr.ttl, rr.type, *absolute_data)
    end

    def raw_name
      @name
    end

    def name
      @name.to_s
    end

    def parent_name
      Resolv::DNS::Name.new(@name[1..-1]).to_s
    end

    def value
      case @type
      when :A, :AAAA
        @data.address.to_s
      when :CNAME, :PTR
        @data.name.to_s
      when :TXT
        @data.strings.map { |s| '"' + s.gsub('"', '\"') + '"' }.join(" ")
      when :SRV
        "#{@data.priority} #{@data.weight} #{@data.port} #{@data.target.to_s}"
      else
        raise RuntimeError,
          "Unknown RR type #{@type.inspect}, can't convert to value"
      end
    end

    def absolute?
      @name.absolute?
    end

    def value_absolute(base_domain)
      case @type
      when :PTR, :SRV, :CNAME
        "#{value}.#{base_domain}"
      else
        value
      end
    end

    def to_absolute(base_domain)
      raise InvalidStateError.new('Record is already absolute!') if absolute?

      abs_data =
        case type
        when :PTR, :CNAME
          [data.name + base_domain]
        when :SRV
          [data.priority, data.weight, data.port, data.target + base_domain]
        when :A, :AAAA, :TXT
          [data]
        else
          raise RuntimeError, "Unknown RR type #{@type.inspect}, can't convert to absolute"
        end

      self.class.new(@name + base_domain, @ttl, @type, *abs_data)
    end

    def to_relative(base_domain)
      raise InvalidStateError.new('Record is already relative!') unless absolute?

      rel_data =
        case type
        when :PTR, :CNAME
          [data.name - base_domain]
        when :SRV
          [data.priority, data.weight, data.port, data.target - base_domain]
        when :A, :AAAA, :TXT
          [data]
        else
          raise RuntimeError, "Unknown RR type #{@type.inspect}, can't convert to relative"
        end

      self.class.new(@name - base_domain, @ttl, @type, *rel_data)
    end

    def ==(other)
      return false unless DNSRecord === other

      @name == other.raw_name && @ttl == other.ttl && @data == other.data
    end

    alias eql? ==

    def hash
      @name.hash ^ @ttl.hash ^ @data.hash
    end

    private

    def absolute_name?(n)
      if n.is_a?(Resolv::DNS::Name)
        n.absolute?
      else
        n.to_s.end_with?('.')
      end
    end
  end
end
