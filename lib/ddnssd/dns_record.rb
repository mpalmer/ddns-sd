require 'resolv'

module DDNSSD
  class DNSRecord
    attr_reader :ttl, :type, :data

    def initialize(name, ttl, type, *data)
      if name.is_a?(Resolv::DNS::Name)
        @name = name
      else
        @name = Resolv::DNS::Name.create(name)
      end

      @ttl, @type = ttl, type

      puts "#{name.inspect}, #{ttl.inspect}, #{type.inspect}, #{data.inspect}" if data.empty?
      @data = Resolv::DNS::Resource::IN.const_get(type).new(*data)
    end

    def self.new_relative_from_absolute(base_domain, name, ttl, type, *data)
      s = ".#{base_domain}"

      rel_data =
        case type
        when :PTR, :CNAME
          [data[0].chomp(s)]
        when :SRV
          data[0, 3] + [data[3].chomp(s)]
        else
          data
        end

      new(name.chomp(s), ttl, type, *rel_data)
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
        "#{@data.priority} #{@data.weight} #{@data.port} #{@data.target}"
      else
        raise RuntimeError,
          "Unknown RR type #{@type.inspect}, can't convert to value"
      end
    end

    def value_absolute(base_domain)
      case @type
      when :PTR, :SRV, :CNAME
        "#{value}.#{base_domain}"
      else
        value
      end
    end

    def ==(other)
      return false unless DNSRecord === other

      @name == other.raw_name && @ttl == other.ttl && @data == other.data
    end

    alias eql? ==

    def hash
      @name.hash ^ @ttl.hash ^ @data.hash
    end
  end
end
