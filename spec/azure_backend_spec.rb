require_relative './spec_helper'

require 'ddnssd/backend/azure'

include Azure::Dns::Mgmt::V2018_03_01_preview
include Azure::Dns::Mgmt::V2018_03_01_preview::Models

describe DDNSSD::Backend::Azure do
  uses_logger

  let(:base_env) do
    {
      "DDNSSD_HOSTNAME"        => "speccy",
      "DDNSSD_BACKEND"         => "azure",
      "DDNSSD_BASE_DOMAIN"     => "example.com",
      "DDNSSD_AZURE_RESOURCE_GROUP_NAME"     => "ddns-test",
      "DDNSSD_AZURE_ACCESS_TOKEN"     => { accessToken: "flibber",
                                           expiresOn: "2018-08-02 11:29:51.706962",
                                           subscription: "123123123-1234-1234-1234-1234123123123",
                                           tenant: "123123123-1234-1234-1234-1234123123123",
                                           tokenType: "Bearer"
                                         }.to_json,
    }
  end
  let(:env) { base_env }
  let(:config) { DDNSSD::Config.new(env, logger: logger) }

  let(:backend) { DDNSSD::Backend::Azure.new(config) }

  let(:az_client) { DnsManagementClient.new }

  before(:each) do
    allow(Azure::Dns::Mgmt::V2018_03_01_preview::DnsManagementClient).to receive(:new).and_return(az_client)
    allow(MsRest::TokenCredentials).to receive(:new).and_return(nil)
  end

  describe ".new" do
    context "without a RESOURCE_GROUP specified" do
      let(:env) { base_env.reject { |k, v| k == "DDNSSD_AZURE_RESOURCE_GROUP_NAME" } }

      it "raises an exception" do
        expect { backend }.to raise_error(DDNSSD::Config::InvalidEnvironmentError)
      end
    end

    context "without an ACCESS_TOKEN specified" do
      let(:env) { base_env.reject { |k, v| k == "DDNSSD_AZURE_ACCESS_TOKEN" } }

      it "raises an exception" do
        expect { backend }.to raise_error(DDNSSD::Config::InvalidEnvironmentError)
      end
    end
  end

  describe "#dns_records" do
    context "one page of records" do
      before(:each) do
        allow(az_client.record_sets).to receive(:list_by_dns_zone).and_return(azure_response_fixture("basic_response"))
      end

      it "asks for the records of the correct resource group and base domain" do
        expect(az_client.record_sets).to receive(:list_by_dns_zone).with(config.backend_config["RESOURCE_GROUP_NAME"], config.base_domain).and_return(azure_response_fixture("basic_response"))

        backend.dns_records
      end

      it "returns a list of DDNSSD::DNSRecord objects" do
        expect(backend.dns_records).to be_an(Array)
        expect(backend.dns_records.reject { |rr| DDNSSD::DNSRecord === rr }).to be_empty
        expect(backend.dns_records.all? { |rr| DDNSSD::DNSRecord === rr }).to be(true)
      end

      it "returns A records" do
        expect(backend.dns_records.any? { |rr| rr.type == :A }).to be(true)
      end

      it "returns AAAA records" do
        expect(backend.dns_records.any? { |rr| rr.type == :AAAA }).to be(true)
      end

      it "returns CNAME records" do
        expect(backend.dns_records.any? { |rr| rr.type == :CNAME }).to be(true)
      end

      it "returns SRV records" do
        expect(backend.dns_records.any? { |rr| rr.type == :SRV }).to be(true)
      end

      it "returns TXT records" do
        expect(backend.dns_records.any? { |rr| rr.type == :TXT }).to be(true)
      end

      it "returns PTR records" do
        expect(backend.dns_records.any? { |rr| rr.type == :PTR }).to be(true)
      end

      it "does not return SOA records" do
        expect(backend.dns_records.any? { |rr| rr.type == :SOA }).to be(false)
      end

      it "does not return NS records" do
        expect(backend.dns_records.any? { |rr| rr.type == :NS }).to be(false)
      end
    end

    context "on other errors" do
      before(:each) do
        allow(az_client.record_sets).to receive(:list_by_dns_zone).and_return("oogabooga")
        allow(logger).to receive(:error)
      end

      it "logs the error" do
        expect(logger).to receive(:error)

        backend.dns_records
      end

      it "returns an empty list" do
        expect(backend.dns_records).to be_empty
      end
    end
  end
end
