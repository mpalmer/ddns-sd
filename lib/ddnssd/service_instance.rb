require 'resolv'

require 'ddnssd/dns_record'
require 'ddnssd/error'

module DDNSSD
  class ServiceInstance
    class ServiceInstanceValidationError < DDNSSD::Error; end

    attr_reader :name, :labels, :container, :config, :container_desc

    def initialize(name, labels, container, config)
      @name, @labels, @container, @config = name, labels, container, config

      @logger = @config.logger
    end

    def dns_records(base_domain = nil)
      unless @container.addressable?
        @logger.debug(progname) { "Container #{@container.name} does not have IP addresses; not creating DNS records for service #{@name}" }
        return []
      end

      begin
        protos.each do |proto|
          unless @container.port_exposed?("#{@labels["port"]}/#{proto}")
            raise ServiceInstanceValidationError,
              "Port specified in labels (#{@labels["port"]}/#{proto}) on container #{container_desc} not exposed."
          end
        end

        d = DNSRecords.new(self, protos, base_domain || @config.base_domain)

        # This ordering is quite particular; it makes sure that records
        # which reference other records are created after the referenced
        # records.  That's not *essential*, but it is polite.
        d.a_records + d.aaaa_records + d.srv_records + d.txt_records + d.ptr_records + d.cname_records
      rescue ServiceInstanceValidationError => ex
        @logger.error(progname) { "#{ex.message} Service not registered." }
        return []
      end
    end

    def container_desc
      "#{@container.short_id} (#{@container.name.inspect})"
    end

    private

    def progname
      @logger_progname ||= "DDNSSD::ServiceInstance(#{@name})"
    end

    def protos
      unless @labels["protocol"].nil? || @labels["protocol"] =~ /\A(|tcp|udp|both)\z/i
        raise ServiceInstanceValidationError,
          "Invalid protocol label #{@labels["protocol"].inspect} on container #{container_desc}, must be one of 'tcp', 'udp', or 'both'."
      end

      case @labels["protocol"].to_s.downcase
      when "", "tcp"
        ["tcp"]
      when "udp"
        ["udp"]
      when "both"
        ["tcp", "udp"]
      end
    end

    # This class calculates the DNS records for the given service instance
    # for the given protocols and base domain.
    class DNSRecords
      def initialize(service_instance, protos, base_domain)
        @service_instance, @protos, @base_domain = service_instance, protos, base_domain

        @name = service_instance.name
        @labels = service_instance.labels
        @container = service_instance.container
        @config = service_instance.config
      end

      def host_fqdn
        "#{@config.hostname}.#{@base_domain}"
      end

      def container_fqdn
        "#{@container.short_id}.#{host_fqdn}"
      end

      def address_fqdn
        "#{instance_v4_address.gsub('.', '-')}.#{host_fqdn}"
      end

      def instance_address_fqdn
        if @container.host_network
          host_fqdn
        elsif @container.host_port_for("#{@labels["port"]}/#{@protos.first}")
          if @container.host_address_for("#{@labels["port"]}/#{@protos.first}")
            address_fqdn
          else
            host_fqdn
          end
        else
          container_fqdn
        end
      end

      def service_fqdn(proto)
        "_#{@name}._#{proto}.#{@base_domain}"
      end

      def instance_v4_address
        if @container.host_port_for("#{@labels["port"]}/#{@protos.first}")
          if pub_addr = @container.host_address_for("#{@labels["port"]}/#{@protos.first}")
            pub_addr
          else
            if @config.host_ip_address.nil?
              raise ServiceInstanceValidationError,
                "Published port on default IP address detected on container #{@service_instance.container_desc}, but no host IP address configured."
            end

            nil
          end
        else
          @container.ipv4_address
        end
      end

      def srv_instance_fqdn(proto)
        name = @labels["instance"] || @container.name
        name.force_encoding("UTF-8")

        if name.bytesize == 0
          raise ServiceInstanceValidationError,
            "Instance name on container #{@service_instance.container_desc} is empty."
        end

        if name.bytesize > 63
          raise ServiceInstanceValidationError,
            "Instance name #{name.inspect} on container #{@service_instance.container_desc} is too long (must be <= 63 octets)."
        end

        unless name.valid_encoding?
          raise ServiceInstanceValidationError,
            "Instance name #{name.inspect} on container #{@service_instance.container_desc} is not valid UTF-8."
        end

        unless name =~ /\A[^\u0000-\u001f\u007f]+\z/
          raise ServiceInstanceValidationError,
            "Instance name #{name.inspect} on container #{@service_instance.container_desc} is not valid Net-Unicode (contains ASCII control characters)."
        end

        "#{name}.#{service_fqdn(proto)}"
      end

      def a_records
        if !@container.host_network && instance_v4_address
          [DDNSSD::DNSRecord.new(instance_address_fqdn, @config.record_ttl, :A, instance_v4_address)]
        else
          []
        end
      end

      def aaaa_records
        if  @container.host_network ||
            @container.host_port_for("#{@labels["port"]}/#{@protos.first}") ||
            @container.ipv6_address.nil? ||
            @container.ipv6_address.empty?
          []
        else

          [DDNSSD::DNSRecord.new(instance_address_fqdn, @config.record_ttl, :AAAA, @container.ipv6_address)]
        end
      end

      def parse_ushort_label(k)
        if @labels[k]
          unless @labels[k] =~ /\A\d+\z/
            raise ServiceInstanceValidationError,
              "Value #{@labels[k].inspect} for label org.discourse.service._#{@name}.#{k} on #{@service_instance.container_desc} is not a number."
          end

          unless (0..65535).include?(@labels[k].to_i)
            raise ServiceInstanceValidationError,
              "Value #{@labels[k].inspect} for label org.discourse.service._#{@name}.#{k} on #{@service_instance.container_desc} is invalid (must be between 0-65535 inclusive)."
          end

          @labels[k].to_i
        else
          0
        end
      end

      def srv_records
        priority = parse_ushort_label("priority")
        weight   = parse_ushort_label("weight")

        @protos.map do |proto|
          port = @container.host_port_for("#{@labels["port"]}/#{proto}") || @labels["port"]

          DDNSSD::DNSRecord.new(srv_instance_fqdn(proto),
            @config.record_ttl,
            :SRV,
            priority,
            weight,
            port.to_i,
            instance_address_fqdn
          )
        end
      end

      def ptr_records
        @protos.map do |proto|
          DDNSSD::DNSRecord.new(service_fqdn(proto), @config.record_ttl, :PTR, srv_instance_fqdn(proto))
        end
      end

      def txt_records
        @protos.map do |proto|
          DDNSSD::DNSRecord.new(srv_instance_fqdn(proto), @config.record_ttl, :TXT, *parse_tag_labels)
        end
      end

      def cname_records
        @labels["aliases"].to_s.split(',').map do |relrrname|
          DDNSSD::DNSRecord.new("#{relrrname}.#{@base_domain}", @config.record_ttl, :CNAME, instance_address_fqdn)
        end
      end

      def parse_tag_labels
        value_tags = @labels.select { |k, v| k =~ /\Atag\./ }.map do |k, v|
          k = k.sub(/\Atag\./, '')

          validate_tag_key(k)

          "#{k}=#{v}"
        end

        boolean_tags = @labels["tags"].to_s.split("\n").each { |t| validate_tag_key(t) }

        tags = value_tags + boolean_tags

        tags.each do |t|
          if t.bytesize > 255
            raise ServiceInstanceValidationError,
              "Tag #{t.inspect} on #{@service_instance.container_desc} is too long (must be <= 255 octets)."
          end
        end

        tags.sort_by! { |v| v =~ /\Atxtvers=/ ? 0 : 1 }

        if tags.empty?
          [""]
        else
          tags
        end
      end

      def validate_tag_key(k)
        if k == ""
          raise ServiceInstanceValidationError,
            "Tag label set on #{@service_instance.container_desc} has an empty tag key."
        end

        if k.include?("=")
          raise ServiceInstanceValidationError,
            "Tag key #{k.inspect} on #{@service_instance.container_desc} contains an equals sign, which is forbidden."
        end

        unless k =~ /\A[\x20-\x7e]+\z/
          raise ServiceInstanceValidationError,
            "Tag label #{k.inspect} on #{@service_instance.container_desc} contains a forbidden character (only printable ASCII allowed)."
        end
      end
    end

  end
end
