require 'ddnssd/service_instance'

module DDNSSD
  class Container
    attr_reader :id, :name, :ipv4_address, :ipv6_address

    attr_accessor :stopped

    def initialize(docker_data, system_config)
      @id = docker_data.id

      @config = system_config
      @logger = @config.logger

      @name = (docker_data.info["Name"] || docker_data.info["Names"].first).sub(/\A\//, '')
      @ipv4_address = docker_data.info["NetworkSettings"]["IPAddress"]
      @ipv6_address = docker_data.info["NetworkSettings"]["GlobalIPv6Address"]

      @exposed_ports   = docker_data.info["Config"]["ExposedPorts"] || {}
      @published_ports = docker_data.info["NetworkSettings"]["Ports"]

      @service_instances = parse_service_instances(docker_data.info["Config"]["Labels"])
    end

    def short_id
      @id[0..11]
    end

    def dns_records
      @service_instances.map { |si| si.dns_records }.flatten(1)
    end

    def port_exposed?(spec)
      !@exposed_ports[spec].nil?
    end

    def host_port_for(spec)
      (@published_ports[spec].first["HostPort"] rescue nil).tap do |v|
        @logger.debug(progname) { "host_port_for(#{spec.inspect}) => #{v.inspect}" }
      end
    end

    def host_address_for(spec)
      addr = @published_ports[spec].first["HostIp"] rescue nil

      if addr == "0.0.0.0" || addr == ""
        nil
      else
        addr
      end.tap do |v|
        @logger.debug(progname) { "host_address_for(#{spec.inspect}) => #{v.inspect}" }
      end
    end

    def publish_records(backend)
      dns_records.each { |rr| backend.publish_record(rr) }
    end

    def suppress_records(backend)
      dns_records.each { |rr| backend.suppress_record(rr) unless %i{TXT PTR}.include?(rr.type) }
    end

    private

    def progname
      @logger_progname ||= "DDNSSD::Container(#{short_id})"
    end

    def parse_service_instances(labels)
      labels.select do |lbl, val|
        lbl =~ /\Aorg\.discourse\.service\./
      end.map do |lbl, val|
        [lbl.sub(/\Aorg\.discourse\.service\./, ''), val]
      end.each_with_object(Hash.new { |h, k| h[k] = {} }) do |(lbl, val), h|
        svcname, sublabel = lbl.split('.', 2)
        h[svcname][sublabel] = val
      end.map do |svc, labels|
        unless svc[0] == "_"
          @logger.error(progname) { "Label org.discourse.service.#{svc}... ignored.  Service names must begin with an underscore." }
          next nil
        end

        DDNSSD::ServiceInstance.new(svc[1..-1], labels, self, @config)
      end.compact
    end
  end
end
