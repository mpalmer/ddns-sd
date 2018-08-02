require 'docker-api'
require 'resolv'
require 'yaml'

module ExampleMethods
  def container_fixture(name)
    data = YAML.load_file(File.expand_path("../fixtures/container_data/#{name}.yml", __FILE__))
    Docker::Container.send(:new, Docker::Connection.new("unix:///", {}), data)
  end

  def container_fixtures(*names)
    names.map { |n| container_fixture(n) }
  end

  def dns_record_fixture(name)
    data = YAML.load_file(File.expand_path("../fixtures/dns_records/#{name}.yml", __FILE__))
    data.map { |d| DDNSSD::DNSRecord.new(d["name"], d["ttl"], d["type"], *d["data"]) }
  end

  def dns_record_fixtures(*names)
    names.map { |n| dns_record_fixture(n) }.flatten(1)
  end

  def route53_response_fixture(name)
    YAML.load_file(File.expand_path("../fixtures/route53_responses/#{name}.yml", __FILE__))
  end

  def azure_response_fixture(name)
    client = Azure::Dns::Mgmt::V2018_03_01_preview::DnsManagementClient.new
    json = File.read(File.expand_path("../fixtures/azure_responses/#{name}.json", __FILE__))
    request_mapper = Azure::Dns::Mgmt::V2018_03_01_preview::Models::RecordSet.mapper
    JSON.parse(json).map { |v| client.deserialize(request_mapper, v) }
  end
end
