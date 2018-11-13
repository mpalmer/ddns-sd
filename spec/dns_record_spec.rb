require_relative './spec_helper'

require 'ddnssd/dns_record'

describe DDNSSD::DNSRecord do
  let(:record) { DDNSSD::DNSRecord.new("foo.example.com", 42, :A, "192.0.2.42") }

  describe "#name" do
    it "returns the record's name" do
      expect(record.name).to eq("foo.example.com")
    end

    context "when passed a Resolv::DNS::Name" do
      let(:record) { DDNSSD::DNSRecord.new(Resolv::DNS::Name.create("foo.example.com"), 42, :A, "192.0.2.42") }

      it "returns the string name" do
        expect(record.name).to eq("foo.example.com")
      end
    end
  end

  describe "#ttl" do
    it "returns the record's TTL" do
      expect(record.ttl).to eq(42)
    end
  end

  describe '#new' do
    context "with an A record" do
      let(:record) { DDNSSD::DNSRecord.new("foo.example.com", 42, :A, "192.0.2.42") }

      describe '#name' do
        it 'is the absolute name' do
          expect(record.name).to eq('foo.example.com')
        end
      end

      describe "#data" do
        it "is the appropriate class" do
          expect(record.data).to be_a(Resolv::DNS::Resource::IN::A)
        end

        it "holds the provided address" do
          expect(record.data.address.to_s).to eq("192.0.2.42")
        end
      end

      describe "#value" do
        it "returns the address" do
          expect(record.value).to eq("192.0.2.42")
        end
      end
    end

    context "with a AAAA record" do
      let(:record) { DDNSSD::DNSRecord.new("foo.example.com", 42, :AAAA, "2001:db8::42") }

      describe '#name' do
        it 'is the absolute name' do
          expect(record.name).to eq('foo.example.com')
        end
      end

      describe "#data" do
        it "is the appropriate class" do
          expect(record.data).to be_a(Resolv::DNS::Resource::IN::AAAA)
        end

        it "holds the provided address" do
          expect(record.data.address.to_s).to eq("2001:DB8::42")
        end
      end

      describe "#value" do
        it "returns the address" do
          expect(record.value).to eq("2001:DB8::42")
        end
      end
    end

    context "with a SRV record" do
      let(:record) { DDNSSD::DNSRecord.new("_bar._foo._tcp.example.com", 42, :SRV, 2, 4, 8, "bar.example.com") }

      describe '#name' do
        it 'is the absolute name' do
          expect(record.name).to eq('_bar._foo._tcp.example.com')
        end
      end

      describe "#data" do
        it "is the appropriate class" do
          expect(record.data).to be_a(Resolv::DNS::Resource::IN::SRV)
        end

        it "holds the provided priority" do
          expect(record.data.priority).to eq(2)
        end

        it "holds the provided weight" do
          expect(record.data.weight).to eq(4)
        end

        it "holds the provided port" do
          expect(record.data.port).to eq(8)
        end

        it "holds the provided target" do
          expect(record.data.target.to_s).to eq("bar.example.com")
        end
      end

      describe "#value" do
        it "returns the consolidated record data" do
          expect(record.value).to eq("2 4 8 bar.example.com")
        end
      end
    end

    context "with a PTR record" do
      let(:record) { DDNSSD::DNSRecord.new("_foo._tcp.example.com", 42, :PTR, "_bar._foo._tcp.example.com") }

      describe '#name' do
        it 'is the absolute name' do
          expect(record.name).to eq('_foo._tcp.example.com')
        end
      end

      describe "#data" do
        it "is the appropriate class" do
          expect(record.data).to be_a(Resolv::DNS::Resource::IN::PTR)
        end

        it "holds the provided name" do
          expect(record.data.name).to eq("_bar._foo._tcp.example.com")
        end
      end

      describe "#value" do
        it "returns the target" do
          expect(record.value).to eq("_bar._foo._tcp.example.com")
        end
      end
    end

    context "with a TXT record" do
      let(:record) { DDNSSD::DNSRecord.new("_bar._foo._tcp.example.com", 42, :TXT, 'something "funny"', "this too") }

      describe '#name' do
        it 'is the absolute name' do
          expect(record.name).to eq('_bar._foo._tcp.example.com')
        end
      end

      describe "#data" do
        it "is the appropriate class" do
          expect(record.data).to be_a(Resolv::DNS::Resource::IN::TXT)
        end

        it "holds the provided strings" do
          expect(record.data.strings).to eq(['something "funny"', "this too"])
        end
      end

      describe "#value" do
        it "returns the quoted strings" do
          expect(record.value).to eq('"something \"funny\"" "this too"')
        end
      end
    end

    context "with a CNAME record" do
      let(:record) { DDNSSD::DNSRecord.new("something.example.com", 42, :CNAME, "guy-incognito.example.com") }

      describe '#name' do
        it 'is the absolute name' do
          expect(record.name).to eq('something.example.com')
        end
      end

      describe "#data" do
        it "is the appropriate class" do
          expect(record.data).to be_a(Resolv::DNS::Resource::IN::CNAME)
        end

        it "holds the provided name" do
          expect(record.data.name).to eq("guy-incognito.example.com")
        end
      end

      describe "#value" do
        it "returns the target" do
          expect(record.value).to eq("guy-incognito.example.com")
        end
      end
    end

    context "with a mystery record" do
      let(:record) { DDNSSD::DNSRecord.new("example.com", 60, :NS, "ns1.example.com") }

      describe "#value" do
        it "raises an exception" do
          expect { record.value }.to raise_error(RuntimeError)
        end
      end
    end
  end

  describe '#new_relative_from_absolute' do
    let(:base_domain) { "example.com" }

    context "with an A record" do
      let(:record) { DDNSSD::DNSRecord.new_relative_from_absolute(base_domain, "foo.example.com", 42, :A, "192.0.2.42") }

      describe '#name' do
        it 'is the absolute name' do
          expect(record.name).to eq('foo')
        end
      end

      describe "#data" do
        it "is the appropriate class" do
          expect(record.data).to be_a(Resolv::DNS::Resource::IN::A)
        end

        it "holds the provided address" do
          expect(record.data.address.to_s).to eq("192.0.2.42")
        end
      end

      describe "#value" do
        it "returns the address" do
          expect(record.value).to eq("192.0.2.42")
        end
      end
    end

    context "with a AAAA record" do
      let(:record) { DDNSSD::DNSRecord.new_relative_from_absolute(base_domain, "foo.example.com", 42, :AAAA, "2001:db8::42") }

      describe '#name' do
        it 'is the absolute name' do
          expect(record.name).to eq('foo')
        end
      end

      describe "#data" do
        it "is the appropriate class" do
          expect(record.data).to be_a(Resolv::DNS::Resource::IN::AAAA)
        end

        it "holds the provided address" do
          expect(record.data.address.to_s).to eq("2001:DB8::42")
        end
      end

      describe "#value" do
        it "returns the address" do
          expect(record.value).to eq("2001:DB8::42")
        end
      end
    end

    context "with a SRV record" do
      let(:record) { DDNSSD::DNSRecord.new_relative_from_absolute(base_domain, "_bar._foo._tcp.example.com", 42, :SRV, 2, 4, 8, "bar.example.com") }

      describe '#name' do
        it 'is the absolute name' do
          expect(record.name).to eq('_bar._foo._tcp')
        end
      end

      describe "#data" do
        it "is the appropriate class" do
          expect(record.data).to be_a(Resolv::DNS::Resource::IN::SRV)
        end

        it "holds the provided priority" do
          expect(record.data.priority).to eq(2)
        end

        it "holds the provided weight" do
          expect(record.data.weight).to eq(4)
        end

        it "holds the provided port" do
          expect(record.data.port).to eq(8)
        end

        it "holds the provided target" do
          expect(record.data.target.to_s).to eq("bar")
        end
      end

      describe "#value" do
        it "returns the consolidated record data" do
          expect(record.value).to eq("2 4 8 bar")
        end
      end
    end

    context "with a PTR record" do
      let(:record) { DDNSSD::DNSRecord.new_relative_from_absolute(base_domain, "_foo._tcp.example.com", 42, :PTR, "_bar._foo._tcp.example.com") }

      describe '#name' do
        it 'is the absolute name' do
          expect(record.name).to eq('_foo._tcp')
        end
      end

      describe "#data" do
        it "is the appropriate class" do
          expect(record.data).to be_a(Resolv::DNS::Resource::IN::PTR)
        end

        it "holds the provided name" do
          expect(record.data.name).to eq("_bar._foo._tcp")
        end
      end

      describe "#value" do
        it "returns the target" do
          expect(record.value).to eq("_bar._foo._tcp")
        end
      end
    end

    context "with a TXT record" do
      let(:record) { DDNSSD::DNSRecord.new_relative_from_absolute(base_domain, "_bar._foo._tcp.example.com", 42, :TXT, 'something "funny"', "this too") }

      describe '#name' do
        it 'is the absolute name' do
          expect(record.name).to eq('_bar._foo._tcp')
        end
      end

      describe "#data" do
        it "is the appropriate class" do
          expect(record.data).to be_a(Resolv::DNS::Resource::IN::TXT)
        end

        it "holds the provided strings" do
          expect(record.data.strings).to eq(['something "funny"', "this too"])
        end
      end

      describe "#value" do
        it "returns the quoted strings" do
          expect(record.value).to eq('"something \"funny\"" "this too"')
        end
      end
    end

    context "with a CNAME record" do
      let(:record) { DDNSSD::DNSRecord.new_relative_from_absolute(base_domain, "something.example.com", 42, :CNAME, "guy-incognito.example.com") }

      describe '#name' do
        it 'is the absolute name' do
          expect(record.name).to eq('something')
        end
      end

      describe "#data" do
        it "is the appropriate class" do
          expect(record.data).to be_a(Resolv::DNS::Resource::IN::CNAME)
        end

        it "holds the provided name" do
          expect(record.data.name).to eq("guy-incognito")
        end
      end

      describe "#value" do
        it "returns the target" do
          expect(record.value).to eq("guy-incognito")
        end
      end
    end

    context "with a mystery record" do
      let(:record) { DDNSSD::DNSRecord.new_relative_from_absolute(base_domain, "example.com", 60, :NS, "ns1.example.com") }

      describe "#value" do
        it "raises an exception" do
          expect { record.value }.to raise_error(RuntimeError)
        end
      end
    end
  end
end
