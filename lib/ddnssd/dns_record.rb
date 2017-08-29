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
          "Unknown RR type, can't convert to value"
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
