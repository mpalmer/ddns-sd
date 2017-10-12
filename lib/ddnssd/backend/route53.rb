require 'aws-sdk'
require 'shellwords'

require 'ddnssd/backend'
require 'ddnssd/config'
require 'ddnssd/dns_record'
require 'ddnssd/error'

class DDNSSD::Backend::Route53 < DDNSSD::Backend
  class RetryError < DDNSSD::Error; end
  class InvalidChangeRequest < DDNSSD::Error; end

  module Retryable
    def retryable
      next_timeout = 0.1
      tries_left = 10

      begin
        tries_left -= 1
        yield
      rescue Aws::Route53::Errors::Throttled, Aws::Route53::Errors::PriorRequestNotComplete => ex
        if tries_left > 0
          @logger.info(progname) { "Received #{ex.class}; waiting for #{next_timeout}s and retrying" }
          Kernel.sleep next_timeout
          next_timeout *= 2
          retry
        else
          raise RetryError, "Attempted request 10 times, got a retryable error every time. This is not normal. Giving up."
        end
      end
    end
  end

  include Retryable

  class RecordCache
    include Retryable

    def initialize(zone_id, route53, route53_stats, logger)
      @zone_id, @route53, @route53_stats, @logger = zone_id, route53, route53_stats, logger

      blank_cache
    end

    def get(name, type)
      @cache[name][type]
    end

    def all_of_type(type)
      @cache.values.map { |v| v[type] }.flatten.compact
    end

    def add(rr)
      @cache[rr.name][rr.type] << rr unless @cache[rr.name][rr.type].include?(rr)
    end

    def remove(rr)
      @cache[rr.name][rr.type].delete(rr)
    end

    def set(*rr)
      @cache[rr.first.name][rr.first.type] = rr
    end

    def refresh_all
      blank_cache

      all_resource_record_sets do |rrset|
        import_rrset(rrset)
      end
    end

    def refresh(name, type)
      res = retryable do
        @route53_stats.measure(op: "get") do
          @route53.list_resource_record_sets(hosted_zone_id: @zone_id, start_record_name: name, start_record_type: type.to_s, max_items: 1)
        end
      end

      rrset = res.resource_record_sets.find { |rrset| rrset.name.chomp(".") == name && rrset.type.to_sym == type }

      if rrset
        import_rrset(rrset)
      else
        @cache[name][type] = []
      end
    end

    def blank_cache
      @cache = Hash.new do |oh, ok|
        oh[ok] = Hash.new { |ih, ik| ih[ik] = [] }
      end
    end

    private

    def progname
      @logger_progname ||= "DDNSSD::Backend::Route53(#{@zone_id})"
    end

    def all_resource_record_sets
      res = Struct.new(:is_truncated, :next_record_name, :next_record_type).new(true, nil, nil)

      while res.is_truncated
        res = retryable do
          @route53_stats.measure(op: "list") do
            @route53.list_resource_record_sets(hosted_zone_id: @zone_id, start_record_name: res.next_record_name, start_record_type: res.next_record_type)
          end
        end
        res.resource_record_sets.each { |rrset| yield rrset }
      end
    rescue StandardError => ex
      @logger.error(progname) { (["Error while enumerating all_resource_record_sets: #{ex.message} (#{ex.class})"] + ex.backtrace).join("  \n") }
    end

    def import_rrset(rrset)
      @cache[rrset.name.chomp(".")][rrset.type.to_sym] = rrset.resource_records.map do |rr|
        rrdata = if rrset.type == "TXT"
          Shellwords.shellwords(rr.value)
        else
          rr.value.split(/\s+/).map { |v| v =~ /\A\d+\z/ ? v.to_i : v }
        end

        DDNSSD::DNSRecord.new(rrset.name.chomp("."), rrset.ttl, rrset.type.to_sym, *rrdata)
      end
    end
  end

  def initialize(config)
    super

    @zone_id = config.backend_config["ZONE_ID"]

    if @zone_id.nil? || @zone_id.empty?
      raise DDNSSD::Config::InvalidEnvironmentError,
            "DDNSSD_ROUTE53_ZONE_ID cannot be empty or missing"
    end

    # Route53 isn't region-based, but the client still needs to be passed
    # the region parameter.  Go AWS!
    @route53 = Aws::Route53::Client.new(region: "fml")
    @route53_stats = Frankenstein::Request.new(:ddnssd_route53, description: "route53", registry: @config.metrics_registry)

    @record_cache = RecordCache.new(@zone_id, @route53, @route53_stats, @logger)
  end

  def dns_records
    @record_cache.refresh_all

    %i{A AAAA SRV PTR TXT CNAME}.map do |type|
      @record_cache.all_of_type(type)
    end.flatten
  end

  private

  def progname
    @logger_progname ||= "DDNSSD::Backend::Route53(#{@zone_id})"
  end

  def set_record(rr)
    @logger.debug(progname) { "-> set_record(#{rr.inspect})" }
    do_change(change_for("UPSERT", [rr]))
    @record_cache.set(rr)
    @logger.debug(progname) { "<- set_record(#{rr.inspect})" }
  end

  def add_record(rr)
    @logger.debug(progname) { "-> add_record(#{rr.inspect})" }

    tries_left = 10

    begin
      tries_left -= 1

      existing_records = @record_cache.get(rr.name, rr.type)

      changes = if existing_records.empty?
        [change_for("CREATE", [rr])]
      else
        [change_for("DELETE", existing_records), change_for("CREATE", (existing_records + [rr]).uniq)]
      end

      do_change(*changes)

      @record_cache.add(rr)
      @logger.debug(progname) { "<- add_record(#{rr.inspect})" }
    rescue Aws::Route53::Errors::InvalidChangeBatch => ex
      if tries_left > 0
        @logger.debug(progname) { "Received InvalidChangeBatch; refreshing record set for #{rr.name} #{rr.type}" }

        @record_cache.refresh(rr.name, rr.type)

        @logger.debug(progname) { "record set for #{rr.name} #{rr.type} is now #{@record_cache.get(rr.name, rr.type).inspect}" }
        retry
      else
        @logger.error(progname) { "Cannot get this add_record change to apply, because #{ex.message}: #{changes.inspect}. Giving up." }
      end
    end
  end

  def remove_record(rr)
    @logger.debug(progname) { "-> remove_record(#{rr.inspect})" }

    tries_left = 10

    begin
      tries_left -= 1
      changes = change_to_remove_record_from_set(@record_cache.get(rr.name, rr.type), rr)
      @logger.debug(progname) { "change_to_remove_record_from_set => #{changes.inspect}" }
      do_change(*changes) unless changes.empty?
      @record_cache.remove(rr)
      @logger.debug(progname) { "<- remove_record(#{rr.inspect})" }
    rescue Aws::Route53::Errors::InvalidChangeBatch => ex
      if tries_left > 0
        @logger.debug(progname) { "Received InvalidChangeBatch; refreshing record set for #{rr.name} #{rr.type}" }

        @record_cache.refresh(rr.name, rr.type)
        retry
      else
        @logger.error(progname) { "Cannot get this remove_record change to apply, because #{ex.message}: #{changes.inspect}. Giving up." }
      end
    end
  end

  def remove_srv_record(srv_rr)
    @logger.debug(progname) { "-> remove_srv_record(#{srv_rr.inspect})" }

    tries_left = 10

    begin
      tries_left -= 1

      existing_records = @record_cache.get(srv_rr.name, srv_rr.type).dup

      if existing_records.empty?
        # Shouldn't happen!
        #:nocov:
        @logger.warn(progname) { "no existing record to remove for #{srv_rr.inspect}" }
        changes = []
        #:nocov:
      elsif existing_records == [srv_rr]
        changes = [change_for("DELETE", existing_records)]

        txt = @record_cache.get(srv_rr.name, :TXT)
        unless txt.empty?
          @logger.debug(progname) { "Removing associated TXT record" }
          changes << change_for("DELETE", txt)
        else
          # Shouldn't happen...
          #:nocov:
          @logger.warn(progname) { "TXT record for #{srv_rr.name} is missing?!?" }
          #:nocov:
        end

        ptrs = @record_cache.get(srv_rr.parent_name, :PTR)
        ptr = ptrs.find { |ptr| ptr.value == srv_rr.name }

        if ptr
          @logger.debug(progname) { "Removing associated PTR record #{ptr.inspect}" }
          changes += change_to_remove_record_from_set(ptrs, ptr)
        end
      else
        changes = change_to_remove_record_from_set(existing_records, srv_rr)
      end

      unless existing_records.empty?
        do_change(*changes) unless changes.empty?
        @record_cache.remove(srv_rr)

        if existing_records == [srv_rr]
          # We nuked these
          @record_cache.get(srv_rr.name, :TXT).each { |txt| @record_cache.remove(txt) }
          @record_cache.remove(ptr) if ptr
        end
      end

      @logger.debug(progname) { "<- remove_srv_record(#{srv_rr.inspect})" }
    rescue Aws::Route53::Errors::InvalidChangeBatch => ex
      if tries_left > 0
        @logger.debug(progname) { "Received InvalidChangeBatch; refreshing record set for #{srv_rr.name} #{srv_rr.type}/TXT" }

        @record_cache.refresh(srv_rr.name, srv_rr.type)
        @record_cache.refresh(srv_rr.name, :TXT)
        @record_cache.refresh(srv_rr.parent_name, :PTR)

        retry
      else
        @logger.error(progname) { "Cannot get this remove_srv_record change to apply, because #{ex.message}: #{changes.inspect}. Giving up." }
      end
    end
  end

  def change_to_remove_record_from_set(rrset, rr)
    @logger.debug(progname) { "change_to_remove_record_from_set(#{rrset.inspect}, #{rr.inspect})" }

    if rrset.any? { |s| s.name != rr.name }
      # Purely an (in)sanity check
      #:nocov:
      raise InvalidChangeRequest,
        "One or more entries in rrset #{rrset.inspect} have a different name to #{rr}."
      #:nocov:
    end

    if rrset.nil?
      # *Really* shouldn't happen...
      #:nocov:
      raise InvalidChangeRequest,
        "rrset passed was nil!"
      #:nocov:
    elsif rrset.empty?
      # *Shouldn't* happen...
      #:nocov:
      @logger.warn(progname) { "Attempted to delete #{rr.inspect} from empty rrset." }
      []
      #:nocov:
    elsif rrset.reject { |er| er.value == rr.value }.empty?
      [change_for("DELETE", rrset)]
    else
      [change_for("DELETE", rrset), change_for("CREATE", rrset.reject { |er| er.value == rr.value })]
    end
  end

  def do_change(*changes)
    begin
      retryable do
        @route53_stats.measure(op: "change") do
          @route53.change_resource_record_sets(hosted_zone_id: @zone_id, change_batch: { changes: changes })
        end
      end
    rescue Aws::Route53::Errors::MalformedInput => ex
      #:nocov:
      @logger.error { (["Please report this bug: route53 reports MalformedInput error on changes: #{changes.inspect}"] + ex.backtrace).join("\n  ") }
      #:nocov:
    end
  end

  def change_for(action, rrset)
    {
      action: action,
      resource_record_set: {
        name: rrset.first.name,
        type: rrset.first.type.to_s,
        ttl: rrset.first.ttl,
        resource_records: rrset.map { |rr| { value: rr.value } }
      }
    }
  end
end
