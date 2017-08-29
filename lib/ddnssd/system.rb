require 'frankenstein/server'
require 'logger'
require 'ipaddr'

require 'ddnssd/config'
require 'ddnssd/docker_watcher'

module DDNSSD
  class System
    attr_reader :config

    # Create a new DDNS-SD system.
    #
    # @param env [Hash] the set of environment variables
    #   with which to configure the system.
    #
    # @param logger [Logger] pass in a custom logger to the system.
    #
    # @return [DDNSSD::System]
    #
    # @raise [DDNSSD::Config::InvalidEnvironmentError] if any problems are
    #   detected with the environment variables found.
    #
    def initialize(env, logger:)
      @config = DDNSSD::Config.new(env, logger: logger)
      @logger = logger
      @backend = @config.backend_class.new(@config)
      @queue = Queue.new
      @watcher = DDNSSD::DockerWatcher.new(queue: @queue, config: @config)
    end

    def run
      @watcher.run!

      if @config.enable_metrics
        @logger.info(progname) { "Starting metrics server" }
        register_start_time_metric
        @metrics_server = Frankenstein::Server.new(port: 9218, logger: @logger, registry: @config.metrics_registry)
        @metrics_server.run
      end

      loop do
        item = @queue.pop
        @logger.debug(progname) { "Received message #{item.inspect}" }

        break if item == [:terminate]

        case (item.first rescue nil)
        when :containers
          reconcile_containers(item.last)
        when :started
          item.last.dns_records.each { |rr| @backend.publish_record(rr) }
        when :stopped
          item.last.dns_records.reverse.each do |rr|
            unless rr.type == :PTR || rr.type == :TXT
              @backend.suppress_record(rr)
            end
          end
        else
          @logger.error(progname) { "SHOULDN'T HAPPEN: docker watcher sent an unrecognized message: #{item.inspect}.  This is a bug, please report it." }
        end
      end
    end

    def shutdown
      @queue.push([:terminate])
      @watcher.shutdown
      @metrics_server.shutdown if @metrics_server
    end

    private

    def progname
      "DDNSSD::System"
    end

    def reconcile_containers(containers)
      @logger.info(progname) { "Reconciling DNS records with container services" }

      our_live_records = @backend.dns_records.select { |rr| our_record?(rr) }
      our_desired_records = containers.map { |c| c.dns_records }.flatten(1)

      if @config.host_ip_address
        our_desired_records.unshift(DDNSSD::DNSRecord.new("#{@config.hostname}.#{@config.base_domain}", @config.record_ttl, :A, @config.host_ip_address))
      end

      @logger.info(progname) { "Found #{our_live_records.length} relevant DNS records." }
      @logger.debug(progname) { (["Relevant DNS records:"] + our_live_records.map { |rr| "#{rr.name} #{rr.ttl} #{rr.type} #{rr.value}" }).join("\n  ") } unless our_live_records.empty?
      @logger.info(progname) { "Should have #{our_desired_records.length} DNS records." }
      @logger.debug(progname) { (["Desired DNS records:"] + our_desired_records.map { |rr| "#{rr.name} #{rr.ttl} #{rr.type} #{rr.value}" }).join("\n  ") } unless our_desired_records.empty?

      @logger.info(progname) { "Deleting #{(our_live_records - our_desired_records).length} DNS records." }

      # Delete any of "our" records that are no longer needed
      (our_live_records - our_desired_records).reject do |rr|
        # We never manually delete PTR and TXT records; the backend will
        # clean them up as-and-when required
        rr.data.is_a?(Resolv::DNS::Resource::IN::PTR) || rr.data.is_a?(Resolv::DNS::Resource::IN::TXT)
      end.each { |rr| @backend.suppress_record(rr) }

      # ... and create any new records we need
      @logger.info(progname) { "Creating #{(our_desired_records - our_live_records).uniq.length} DNS records." }
      (our_desired_records - our_live_records).uniq.each { |rr| @backend.publish_record(rr) }
    end

    def our_record?(rr)
      suffix = /#{Regexp.escape(@config.hostname)}\.#{Regexp.escape(@config.base_domain)}\z/

      case rr.data
      when Resolv::DNS::Resource::IN::A, Resolv::DNS::Resource::IN::AAAA
        rr.name =~ suffix
      when Resolv::DNS::Resource::IN::SRV
        rr.data.target.to_s =~ suffix
      when Resolv::DNS::Resource::IN::PTR, Resolv::DNS::Resource::IN::TXT
        # Everyone shares ownership of TXT and PTR records
        false
      else
        # If I don't know what it is, I ain't touchin' it!
        false
      end
    end

    def register_start_time_metric
      #:nocov:
      label_set = if ENV["DDNSSD_GIT_REVISION"]
        { git_revision: ENV["DDNSSD_GIT_REVISION"] }
      else
        {}
      end

      @config.metrics_registry.gauge(:ddnssd_start_timestamp, "When the server was started").set(label_set, Time.now.to_i)
      #:nocov:
    end
  end
end
