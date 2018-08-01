require 'azure_mgmt_dns'
require 'shellwords'

require 'ddnssd/backend'
require 'ddnssd/config'
require 'ddnssd/dns_record'
require 'ddnssd/error'

include Azure::Dns::Mgmt::V2018_03_01_preview
include Azure::Dns::Mgmt::V2018_03_01_preview::Models

class DDNSSD::Backend::Azure < DDNSSD::Backend
  class RetryError < DDNSSD::Error; end
  class InvalidChangeRequest < DDNSSD::Error; end

  module Retryable
    def retryable
      next_timeout = 0.1
      tries_left = 10

      begin
        tries_left -= 1
        yield
      rescue StandardError => ex
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

  module RecordSetHelper
    def get_records_from_record_set(rrset)
      @logger.debug("converting from azure records of type: #{rrset.type}")
      @logger.debug("converting from azure records list: #{rrset.inspect}")
      case rrset.type
      when "Microsoft.Network/dnszones/A" then rrset.arecords.map { |r| { type: "A", value: r.ipv4address } }
      when "Microsoft.Network/dnszones/AAAA" then rrset.aaaa_records.map { |r| { type: "AAAA", value: r.ipv6address } }
      when "Microsoft.Network/dnszones/MX" then rrset.mx_records.map { |r| { type: "MX", value: "#{ r.preference } #{ r.exchange }" }}
      when "Microsoft.Network/dnszones/NS" then rrset.ns_records.map { |r| { type: "NS", value: r.nsdname } }
      when "Microsoft.Network/dnszones/PTR" then rrset.ptr_records.map { |r| { type: "PTR", value: r.ptrdname } }
      when "Microsoft.Network/dnszones/SRV" then rrset.srv_records.map { |r| { type: "SRV", value: "#{ r.priority } #{ r.weight } #{ r.port } #{ r.target }" } }
      when "Microsoft.Network/dnszones/TXT" then rrset.txt_records.map { |r| { type: "TXT", value: r.value } }
      when "Microsoft.Network/dnszones/CNAME" then rrset.cname_record.map { |r| { type: "CNAME", value: r.cname } }
      when "Microsoft.Network/dnszones/SOA" then rrset.soa_record.map { |r| { type: "SOA", value: "#{ r.host } #{ r.email } #{ r.serial_number } #{ r.refresh_time } #{ r.retry_time } #{ r.expire_time } #{ r.minimum_ttl }" } }
      when "Microsoft.Network/dnszones/CAA" then rrset.caa_records.map { |r| { type: "CAA", value: "#{ r.flags } #{ r.tag } #{ r.value }" } }
      else []
      end
    end

    def get_azure_recordset_format(records)
      r = records.first
      rrset = RecordSet.new
      rrset.ttl = r.ttl
      rrset.name = r.name.sub(Regexp.new(".#{@zone_name}"), "")
      rrset.type = r.type.to_s
      @logger.debug("converting to azure records of type: #{rrset.type}")
      @logger.debug("converting to azure records list: #{records.inspect}")
      case records.first.type.to_s
      when "A" then rrset.arecords = records.map { |r|
                      ar = ARecord.new
                      ar.ipv4address = r.value
                      ar }
      when "AAAA" then rrset.aaaa_records = records.map { |r|
                         ar = AaaaRecord.new
                         ar.ipv6address = r.value
                         ar  }
      when "MX" then rrset.mx_records = records.map { |r|
                       v = r.value.split(" ")
                       ar = MxRecord.new
                       ar.preference = v[0]
                       ar.exchange = v[1]
                       ar }
      when "NS" then rrset.ns_records = records.map { |r|
                       ar = NsRecord.new
                       ar.nsdname = r.value
                       ar }
      when "PTR" then rrset.ptr_records = records.map { |r|
                        ar = PtrRecord.new
                        ar.ptrdname = r.value
                        ar }
      when "SRV" then rrset.srv_records = records.map { |r|
                        v = r.value.split(" ")
                        ar = SrvRecord.new
                        ar.priority = v[0]
                        ar.weight = v[1]
                        ar.port = v[2]
                        ar.target = v[3]
                        ar }
      when "TXT" then rrset.txt_records = records.map { |r|
                        ar = TxtRecord.new
                        ar.value = Shellwords.shellwords(r.value).reject { |v| v.empty? }
                        @logger.debug("txt record value: #{ar.value.inspect}")
                        ar }
      when "CNAME" then rrset.cname_record = records.map { |r|
                          ar = CnameRecord.new
                          ar.cname = r.value
                          ar }
      when "SOA" then rrset.soa_record = records.map { |r|
                        v = r.value.split(" ")
                        ar = SoaRecord.new
                        ar.host = v[0]
                        ar.email = v[1]
                        ar.serial_number = v[2]
                        ar.refresh_time = v[3]
                        ar.retry_time = v[4]
                        ar.expire_time = v[5]
                        ar.minimum_ttl = v[6]
                        ar }
      when "CAA" then rrset.caa_records = records.map { |r|
                        v = r.value.split(" ")
                        ar = CaaRecord.new
                        ar.flags = v[0]
                        ar.tag = v[1]
                        ar.value = v[2]
                        ar }
      end
      rrset
    end
  end

  include Retryable
  include RecordSetHelper

  class RecordCache
    include Retryable
    include RecordSetHelper

    def initialize(client, resource_group_name, zone_name, logger)
      @client, @resource_group_name, @zone_name, @logger = client, resource_group_name, zone_name, logger

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
      rrset = retryable do
        @client.record_sets.get(@resource_group_name, @zone_name, name, type)
      end

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
      @logger_progname ||= "DDNSSD::Backend::Azure(#{@zone_name})"
    end

    def all_resource_record_sets
      res = @client.record_sets.list_by_dns_zone(@resource_group_name, @zone_name)
      res.each { |rrset| yield rrset }

    rescue StandardError => ex
      @logger.error(progname) { (["Error while enumerating all_resource_record_sets: #{ex.message} (#{ex.class})"] + ex.backtrace).join("  \n") }
    end

    def import_rrset(rrset)
      @cache[rrset.name.chomp(".")][rrset.type.to_sym] = get_records_from_record_set(rrset).map do |rr|
        rrdata = if rrset.type == "TXT"
          rr.value
        else
          rr.value.split(/\s+/).map { |v| v =~ /\A\d+\z/ ? v.to_i : v }
        end

        DDNSSD::DNSRecord.new(rrset.name.chomp("."), rrset.ttl, rrset.type.to_sym, *rrdata)
      end
    end
  end

  def initialize(config)
    super

    @zone_name = config.base_domain
    @resource_group_name = config.backend_config["RESOURCE_GROUP_NAME"]
    @access_token = config.backend_config["ACCESS_TOKEN"]

    if @resource_group_name.nil? || @resource_group_name.empty?
      raise DDNSSD::Config::InvalidEnvironmentError,
            "DDNSSD_AZURE_RESOURCE_GROUP_NAME cannot be empty or missing"
    end
    if @access_token.nil? || @access_token.empty?
      raise DDNSSD::Config::InvalidEnvironmentError,
            "DDNSSD_AZURE_ACCESS_TOKEN cannot be empty or missing"
    end

    account = JSON.parse(@access_token)
    credentials = MsRest::TokenCredentials.new(account["accessToken"])

    @client = DnsManagementClient.new(credentials)
    @client.subscription_id = account["subscription"]

    @record_cache = RecordCache.new(@client, @resource_group_name, @zone_name, @logger)
  end

  def dns_records
    @record_cache.refresh_all

    %i{A AAAA SRV PTR TXT CNAME}.map do |type|
      @record_cache.all_of_type(type)
    end.flatten
  end

  private

  def progname
    @logger_progname ||= "DDNSSD::Backend::Azure(#{@zone_name})"
  end

  def set_record(rr)
    @logger.debug(progname) { "-> set_record(#{rr.inspect})" }
    update [rr]
    @record_cache.set(rr)
    @logger.debug(progname) { "<- set_record(#{rr.inspect})" }
  end

  def add_record(rr)
    @logger.debug(progname) { "-> add_record(#{rr.inspect})" }

    tries_left = 10

    begin
      tries_left -= 1

      existing_records = @record_cache.get(rr.name, rr.type)

      if existing_records.empty?
        update [rr]
      else
        update (existing_records + [rr]).uniq
      end

      @record_cache.add(rr)
      @logger.debug(progname) { "<- add_record(#{rr.inspect})" }
    rescue StandardError => ex
      @logger.debug(ex.backtrace)
      if tries_left > 0
        @logger.debug(progname) { "Received InvalidChangeBatch; refreshing record set for #{rr.name} #{rr.type}" }

        @record_cache.refresh(rr.name, rr.type)

        @logger.debug(progname) { "record set for #{rr.name} #{rr.type} is now #{@record_cache.get(rr.name, rr.type).inspect}" }
        retry
      else
        @logger.error(progname) { "Cannot get this add_record change to apply, because #{ex.message}. Giving up." }
      end
    end
  end

  def remove_record(rr)
    @logger.debug(progname) { "-> remove_record(#{rr.inspect})" }

    tries_left = 10

    begin
      tries_left -= 1
      change_to_remove_record_from_set(@record_cache.get(rr.name, rr.type), rr)
      @record_cache.remove(rr)
      @logger.debug(progname) { "<- remove_record(#{rr.inspect})" }
    rescue StandardError => ex
      if tries_left > 0
        @logger.debug(progname) { "Received InvalidChangeBatch; refreshing record set for #{rr.name} #{rr.type}" }

        @record_cache.refresh(rr.name, rr.type)
        retry
      else
        @logger.error(progname) { "Cannot get this remove_record change to apply, because #{ex.message}. Giving up." }
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
        #:nocov:
      elsif existing_records == [srv_rr]
        delete existing_records

        txt = @record_cache.get(srv_rr.name, :TXT)
        unless txt.empty?
          @logger.debug(progname) { "Removing associated TXT record" }
          delete txt
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
          change_to_remove_record_from_set(ptrs, ptr)
        end
      else
        change_to_remove_record_from_set(existing_records, srv_rr)
      end

      unless existing_records.empty?
        @record_cache.remove(srv_rr)

        if existing_records == [srv_rr]
          # We nuked these
          @record_cache.get(srv_rr.name, :TXT).each { |txt| @record_cache.remove(txt) }
          @record_cache.remove(ptr) if ptr
        end
      end

      @logger.debug(progname) { "<- remove_srv_record(#{srv_rr.inspect})" }
    rescue StandardError => ex

      if tries_left > 0
        @logger.debug(progname) { "Received InvalidChangeBatch; refreshing record set for #{srv_rr.name} #{srv_rr.type}/TXT" }

        @record_cache.refresh(srv_rr.name, srv_rr.type)
        @record_cache.refresh(srv_rr.name, :TXT)
        @record_cache.refresh(srv_rr.parent_name, :PTR)

        retry
      else
        @logger.error(progname) { "Cannot get this remove_srv_record change to apply, because #{ex.message}. Giving up." }
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
      delete rrset
    else
      update rrset.reject { |er| er.value == rr.value }
    end
  end

  def update(records)
    records = get_azure_recordset_format(records)
    @client.record_sets.create_or_update(@resource_group_name, @zone_name, records.name, records.type, records)
  end

  def delete(records)
    r = records.first
    @client.record_sets.delete(@resource_group_name, @zone_name, r.name, r.type.to_s)
  end
end
