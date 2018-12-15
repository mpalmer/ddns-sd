# frozen_string_literal: true

require 'shellwords'

require 'ddnssd/backend'
require 'ddnssd/config'
require 'ddnssd/dns_record'
require 'ddnssd/error'

require 'sequel'

class DDNSSD::Backend::PdnsSql < DDNSSD::Backend
  def initialize(config)
    super

    %w(DATABASE_URL).each do |env_var|
      if (backend_config[env_var] || '').empty?
        raise DDNSSD::Config::InvalidEnvironmentError,
          "DDNSSD_PDNS_SQL_#{env_var} cannot be empty or missing"
      end
    end

    @stats = Frankenstein::Request.new(
      :ddnssd_pdns_sql,
      description: "PowerDNS SQL server",
      registry: @config.metrics_registry
    )
  end

  def db
    @conn ||= begin
      Sequel.connect(backend_config['DATABASE_URL'])
    end
  end

  def dns_records
    @stats.measure(op: "list") do
      retryable do
        db[:domains]
          .join(:records, domain_id: Sequel[:domains][:id])
          .select(
            Sequel[:records][:name],
            Sequel[:records][:type],
            Sequel[:records][:ttl],
            Sequel[:records][:content]
          )
          .where(Sequel[:domains][:name] => base_domain.to_s)
          .all
      end
    end.map do |rr|
      rrdata = if rr[:type] == 'TXT'
        Shellwords.shellwords(rr[:content])
      else
        rr[:content].split(/\s+/).map { |v| v =~ /\A\d+\z/ ? v.to_i : v }
      end

      dns_record = DDNSSD::DNSRecord.new("#{rr[:name]}.", rr[:ttl], rr[:type].to_sym, *rrdata)

      if DDNSSD::Backend::PUBLISHABLE_TYPES.include?(dns_record.type)
        if dns_record.subdomain_of?(base_domain)
          dns_record.to_relative(base_domain)
        else
          @logger.warn(progname) { "Found a record with a value that isn't a subdomain of #{base_domain}. Ignoring it. #{dns_record.inspect}" }
          nil
        end
      end
    end.compact
  end

  def set_record(rr)
    @logger.debug(progname) { "-> set_record(#{rr.short_inspect} #{rr.inspect})" }
    rr = rr.to_absolute(base_domain)
    @stats.measure(op: "set") do
      retryable do
        db.transaction(isolation: :serializable) do
          db[:records].where(name: rr.name, type: rr.type.to_s).delete
          db[:records].insert(
            name: rr.name.to_s,
            type: rr.type.to_s,
            ttl: rr.ttl,
            content: rr.type == :AAAA ? rr.value.downcase : rr.value,
            domain_id: domain_id,
          )
        end
      end
    end
    @logger.debug(progname) { "<- set_record(#{rr.short_inspect} #{rr.inspect})" }
  end

  def add_record(rr)
    @logger.debug(progname) { "-> add_record(#{rr.short_inspect} #{rr.inspect})" }
    rr = rr.to_absolute(base_domain)
    @stats.measure(op: "add") do
      retryable do
        db.transaction(isolation: :serializable) do
          if db[:records].where(name: rr.name.to_s, type: rr.type.to_s, content: rr.value).count == 0
            db[:records].insert(
              name: rr.name.to_s,
              type: rr.type.to_s,
              ttl: rr.ttl,
              content: rr.type == :AAAA ? rr.value.downcase : rr.value,
              domain_id: domain_id,
            )
          end
        end
      end
    end
    @logger.debug(progname) { "<- add_record(#{rr.short_inspect} #{rr.inspect})" }
  end

  def remove_record(rr)
    @logger.debug(progname) { "-> remove_record(#{rr.short_inspect} #{rr.inspect})" }
    rr = rr.to_absolute(base_domain)
    @stats.measure(op: "remove") do
      retryable do
        db.transaction(isolation: :serializable) do
          db[:records].where(
            name: rr.name.to_s,
            type: rr.type.to_s,
            content: rr.type == :AAAA ? rr.value.downcase : rr.value,
            domain_id: domain_id
          ).delete
        end
      end
    end
    @logger.debug(progname) { "<- remove_record(#{rr.short_inspect} #{rr.inspect})" }
  end

  def remove_srv_record(rr)
    @logger.debug(progname) { "-> remove_srv_record(#{rr.inspect})" }

    rr = rr.to_absolute(base_domain)

    @stats.measure(op: "remove_srv") do
      retryable do
        db.transaction(isolation: :serializable) do
          db[:records].where(
            name: rr.name.to_s,
            type: rr.type.to_s,
            content: rr.type == :AAAA ? rr.value.downcase : rr.value,
            domain_id: domain_id,
          ).delete

          if db[:records].where(name: rr.name.to_s, type: rr.type.to_s).count == 0
            db[:records].where(
              name: rr.name.to_s,
              type: "TXT",
              domain_id: domain_id,
            ).delete

            db[:records].where(
              type: "PTR",
              content: rr.name.to_s,
              domain_id: domain_id,
            ).delete
          end
        end
      end
    end

    @logger.debug(progname) { "<- remove_srv_record(#{rr.inspect})" }
  end

  private

  def progname
    @logger_progname ||= "#{self.class.name}(#{base_domain})"
  end

  def next_timeout(prev_timeout = nil)
    if prev_timeout.nil?
      0.5 + rand / 2
    else
      prev_timeout * 1.1 + rand
    end
  end

  def retryable
    retry_count = 0
    timeout = next_timeout

    begin
      yield
    rescue Sequel::SerializationFailure => ex
      retry_count += 1
      timeout = next_timeout(timeout)
      @logger.info(progname) { "Received #{ex.class} on attempt #{retry_count}; waiting for #{timeout}s and retrying" }
      Kernel.sleep timeout
      retry
    end
  end

  def domain_id
    @domain_id ||= begin
      domain = base_domain.to_s
      domain_id = nil

      until domain_id || domain.empty?
        domain_id = db[:domains].where(name: domain).select(:id).first[:id]
        domain = domain.split(".", 2).last
      end

      domain_id
    end
  end
end
