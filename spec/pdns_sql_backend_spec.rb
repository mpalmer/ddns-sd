# frozen_string_literal: true
require_relative './spec_helper'

require 'ddnssd/backend/pdns_sql'

describe DDNSSD::Backend::PdnsSql do
  uses_logger

  let(:base_env) do
    {
      "DDNSSD_HOSTNAME"              => "speccy",
      "DDNSSD_BACKEND"               => "pdns_sql",
      "DDNSSD_BASE_DOMAIN"           => "example.com",
      "DDNSSD_PDNS_SQL_DATABASE_URL" => "sqlite:///test.db",
    }
  end

  let(:env)       { base_env }
  let(:config)    { DDNSSD::Config.new(env, logger: logger) }
  let(:backend)   { DDNSSD::Backend::PdnsSql.new(config) }
  let(:db)        { Sequel.sqlite }
  let(:domain_id) { db[:domains].select(:id).where(name: env["DDNSSD_BASE_DOMAIN"]).first[:id] }

  before(:each) do
    # Mocking out this call with a real database seems a bit weird, but there's
    # a method to the mystery.  Every SQLite memory database connection is a
    # separate logical database, so you *really* want to make sure you're
    # talking to the same connection every time.  As an added complication, we
    # need to create the schema (and possibly insert a whole bunch of data)
    # before the test, and yet still be guaranteed that the code under test
    # will *definitely* get the same database handle.  Hence this slightly
    # roundabout and unusual-looking approach.
    allow(Sequel).to receive(:connect).with("sqlite:///test.db").and_return(db)

    create_schema
  end

  def create_schema
    # These table definitions will probably *not* work on a real PowerDNS gSQL
    # installation; they're just the minimum necessary to work with the test
    # suite.
    db.create_table(:domains) do
      primary_key :id
      String  :name, null: false, unique: true
      String  :type, null: false

      constraint :c_lowercase_name, Sequel.lit("name = LOWER(name)")
    end

    db.create_table(:records) do
      primary_key :id
      String  :name, index: true
      String  :type
      String  :content, text: true, size: 65535
      Integer :ttl
      Integer :prio

      constraint :c_lowercase_name, Sequel.lit("name = LOWER(name)")
      foreign_key :domain_id, :domains, key: :id, on_delete: :cascade, index: true, null: false
    end

    domain = env["DDNSSD_BASE_DOMAIN"]
    id = db[:domains].insert(name: domain, type: "NATIVE")
    db[:records].insert(
      domain_id: id,
      name: domain,
      type: "SOA",
      ttl: 60,
      content: "#{domain} hostmaster.#{domain} 1 3600 600 604800 5",
    )
  end

  def preload_db(record_list = nil)
    domain = env["DDNSSD_BASE_DOMAIN"]

    record_list ||= [
      ["abcd1234.flingle.#{domain}", 42, :A,     '192.0.2.42'],
      ["flingle6.#{domain}",         42, :AAAA,  '2001:db8::42'],
      ["flinglec.#{domain}",         42, :CNAME, "host42.#{domain}"],
      ["faff._http._tcp.#{domain}",  42, :SRV,   "0 0 80 host1.#{domain}"],
      ["faff._http._tcp.#{domain}",  42, :SRV,   "0 0 80 host2.#{domain}"],
      ["faff._http._tcp.#{domain}",  42, :TXT,   'funny'],
      ["_http._tcp.#{domain}",       42, :PTR,   "faff._http._tcp.#{domain}"],
      [domain,                       42, :NS,    "ns1.#{domain}"],
    ]

    record_list.each { |r| load_db(r) }
  end

  def load_db(record)
    name, ttl, type, content = record

    db[:records].insert(
      domain_id: domain_id,
      name:      name,
      ttl:       ttl,
      type:      type.to_s,
      content:   content,
    )
  end

  describe '.new' do
    %w(DATABASE_URL).each do |config_var|
      context "without #{config_var}" do
        let(:env) { base_env.reject { |k, v| k == "DDNSSD_PDNS_SQL_#{config_var}" } }

        it "raises an exception" do
          expect { backend }.to raise_error(DDNSSD::Config::InvalidEnvironmentError)
        end
      end
    end
  end

  describe '#dns_records' do
    before(:each) { preload_db }

    it "returns a list of DDNSSD::DNSRecord objects" do
      expect(backend.dns_records).to be_an(Array)
      expect(backend.dns_records.all? { |rr| DDNSSD::DNSRecord === rr }).to be(true)
    end

    it "returns A records" do
      expect(backend.dns_records.any? { |rr| rr.type == :A }).to be(true)
    end

    it "A records are relative" do
      expect(backend.dns_records.find { |rr| rr.type == :A }.name).to eq('abcd1234.flingle')
    end

    it "returns AAAA records" do
      expect(backend.dns_records.any? { |rr| rr.type == :AAAA }).to be(true)
    end

    it "AAAA records are relative" do
      expect(backend.dns_records.find { |rr| rr.type == :AAAA }.name).to eq('flingle6')
    end

    it "returns CNAME records" do
      expect(backend.dns_records.any? { |rr| rr.type == :CNAME }).to be(true)
    end

    it "CNAME records are relative" do
      rr = backend.dns_records.find { |rr| rr.type == :CNAME }
      expect(rr.name).to eq('flinglec')
      expect(rr.data.name.to_s).to eq('host42')
    end

    it "returns SRV records" do
      expect(backend.dns_records.any? { |rr| rr.type == :SRV }).to be(true)
    end

    it "SRV records are relative" do
      records = backend.dns_records.select { |rr| rr.type == :SRV }
      records.each do |rr|
        expect(rr.name).to eq('faff._http._tcp')
        expect(rr.data.target.to_s.end_with?('.example.com')).to eq(false)
      end
    end

    it "returns TXT records" do
      expect(backend.dns_records.any? { |rr| rr.type == :TXT }).to be(true)
    end

    it "A records are relative" do
      expect(backend.dns_records.find { |rr| rr.type == :TXT }.name).to eq('faff._http._tcp')
    end

    it "returns PTR records" do
      expect(backend.dns_records.any? { |rr| rr.type == :PTR }).to be(true)
    end

    it "PTR records are relative" do
      rr = backend.dns_records.find { |rr| rr.type == :PTR }
      expect(rr.name).to eq('_http._tcp')
      expect(rr.data.name.to_s).to eq('faff._http._tcp')
    end

    it "does not return SOA records" do
      expect(backend.dns_records.any? { |rr| rr.type == :SOA }).to be(false)
    end

    it "does not return NS records" do
      expect(backend.dns_records.any? { |rr| rr.type == :NS }).to be(false)
    end

    it "skips records with values that aren't in our base domain" do
      allow(logger).to receive(:warn)
      load_db(["_http._tcp.example.com.", 42, :PTR, "faff.eggsamples.com"])
      expect(backend.dns_records.any? { |rr| rr.value&.end_with?('eggsamples.com') }).to be(false)
    end
  end

  describe '#publish_record' do
    context "with an NS record" do
      it "raises an exception" do
        expect {
          backend.publish_record(
            DDNSSD::DNSRecord.new("example.com", 60, :NS, "ns1.example.com")
          )
        }.to raise_error(DDNSSD::Backend::InvalidRequest)
      end
    end

    context "with an A record" do
      let(:dns_record) { DDNSSD::DNSRecord.new("flingle", 42, :A, "192.0.2.42") }

      it "inserts a new A record" do
        backend.publish_record(dns_record)
        records = db[:records].where(name: "flingle.example.com").all
        expect(records.count).to eq(1)
        new_record = records.first
        expect(new_record).to_not be_nil
        expect(new_record[:ttl]).to eq(42)
        expect(new_record[:type]).to eq('A')
        expect(new_record[:content]).to eq(dns_record.data.address.to_s)
        expect(new_record[:domain_id]).to eq(domain_id)
      end

      it "replaces an existing A record" do
        load_db(["flingle.example.com", 123, :A, "192.0.2.123"])

        backend.publish_record(dns_record)
        records = db[:records].where(name: "flingle.example.com").all
        expect(records.count).to eq(1)
        new_record = records.first
        expect(new_record).to_not be_nil
        expect(new_record[:ttl]).to eq(42)
        expect(new_record[:type]).to eq('A')
        expect(new_record[:content]).to eq(dns_record.data.address.to_s)
        expect(new_record[:domain_id]).to eq(domain_id)
      end

      it "logs unhandled exceptions and keeps running" do
        allow(db).to receive(:[]).and_raise('Splat!')
        expect(logger).to receive(:error) do |progname, &blk|
          expect(blk.call).to match("Splat")
        end
        expect { backend.publish_record(dns_record) }.to_not raise_error
      end
    end

    context "with an AAAA record" do
      let(:dns_record) { DDNSSD::DNSRecord.new("flingle", 42, :AAAA, "2001:db8::42") }

      it "inserts a new AAAA record" do
        backend.publish_record(dns_record)
        records = db[:records].where(name: "flingle.example.com").all
        expect(records.count).to eq(1)
        new_record = records.first
        expect(new_record).to_not be_nil
        expect(new_record[:ttl]).to eq(42)
        expect(new_record[:type]).to eq('AAAA')
        expect(new_record[:content]).to eq(dns_record.data.address.to_s.downcase)
        expect(new_record[:domain_id]).to eq(domain_id)
      end

      it "replaces an existing AAAA record" do
        load_db(["flingle.example.com", 123, :AAAA, "2001:db8::123"])

        backend.publish_record(dns_record)
        records = db[:records].where(name: "flingle.example.com").all
        expect(records.count).to eq(1)
        new_record = records.first
        expect(new_record).to_not be_nil
        expect(new_record[:ttl]).to eq(42)
        expect(new_record[:type]).to eq('AAAA')
        expect(new_record[:content]).to eq(dns_record.data.address.to_s.downcase)
        expect(new_record[:domain_id]).to eq(domain_id)
      end
    end

    context "with a CNAME record" do
      let(:dns_record) { DDNSSD::DNSRecord.new("db", 42, :CNAME, "sql.host27") }

      it "inserts a new CNAME record" do
        backend.publish_record(dns_record)
        records = db[:records].where(name: "db.example.com").all
        expect(records.count).to eq(1)
        new_record = records.first
        expect(new_record).to_not be_nil
        expect(new_record[:ttl]).to eq(42)
        expect(new_record[:type]).to eq('CNAME')
        expect(new_record[:content]).to eq("sql.host27.example.com")
        expect(new_record[:domain_id]).to eq(domain_id)
      end

      it "replaces an existing CNAME record" do
        load_db(["db.example.com", 123, :CNAME, "redis.host123.example.com"])

        backend.publish_record(dns_record)
        records = db[:records].where(name: "db.example.com").all
        expect(records.count).to eq(1)
        new_record = records.first
        expect(new_record).to_not be_nil
        expect(new_record[:ttl]).to eq(42)
        expect(new_record[:type]).to eq('CNAME')
        expect(new_record[:content]).to eq("sql.host27.example.com")
        expect(new_record[:domain_id]).to eq(domain_id)
      end
    end

    context "with a TXT record" do
      let(:dns_record) { DDNSSD::DNSRecord.new("faff._http._tcp", 42, :TXT, 'something "funny"', "this too") }

      it "inserts a new TXT record" do
        dns_record = DDNSSD::DNSRecord.new("faff._http._tcp", 42, :TXT, 'something "funny"', "this too")
        backend.publish_record(dns_record)
        records = db[:records].where(name: "faff._http._tcp.example.com").all
        expect(records.count).to eq(1)
        new_record = records.first
        expect(new_record).to_not be_nil
        expect(new_record[:ttl]).to eq(42)
        expect(new_record[:type]).to eq('TXT')
        expect(new_record[:content]).to eq('"something \"funny\"" "this too"')
        expect(new_record[:domain_id]).to eq(domain_id)
      end

      it "replaces an existing TXT record" do
        load_db(["faff._http._tcp.example.com", 123, :TXT, '"nothing important"'])

        dns_record = DDNSSD::DNSRecord.new("faff._http._tcp", 42, :TXT, 'something "funny"', "this too")
        backend.publish_record(dns_record)
        records = db[:records].where(name: "faff._http._tcp.example.com").all
        expect(records.count).to eq(1)
        new_record = records.first
        expect(new_record).to_not be_nil
        expect(new_record[:ttl]).to eq(42)
        expect(new_record[:type]).to eq('TXT')
        expect(new_record[:content]).to eq('"something \"funny\"" "this too"')
        expect(new_record[:domain_id]).to eq(domain_id)
      end
    end

    context "with a SRV record" do
      let(:dns_record) {
        DDNSSD::DNSRecord.new("faff._http._tcp", 42, :SRV, 0, 0, 80, "faff.host22")
      }

      context "no existing recordset" do
        it "creates a new SRV record" do
          backend.publish_record(dns_record)

          records = db[:records].where(name: "faff._http._tcp.example.com").all
          expect(records.count).to eq(1)
          new_record = records.first
          expect(new_record).to_not be_nil
          expect(new_record[:ttl]).to eq(42)
          expect(new_record[:type]).to eq('SRV')
          expect(new_record[:content]).to eq("0 0 80 faff.host22.example.com")
          expect(new_record[:domain_id]).to eq(domain_id)
        end
      end

      context "with existing records for the name/type" do
        before do
          preload_db(
            [
              ["faff._http._tcp.example.com", 42, :SRV, "0 0 80 faff.host1.example.com"],
              ["faff._http._tcp.example.com", 42, :SRV, "0 0 8080 host3.example.com"],
            ]
          )
        end

        it 'adds a SRV record to the existing recordset' do
          backend.publish_record(dns_record)

          records = db[:records].where(name: 'faff._http._tcp.example.com').all
          expect(records.count).to eq(3)
          records.each do |rr|
            expect(rr[:ttl]).to eq(42)
            expect(rr[:type]).to eq('SRV')
            expect(rr[:domain_id]).to eq(domain_id)
          end
          expect(records.map { |rr| rr[:content] }).to contain_exactly(
            '0 0 80 faff.host1.example.com',
            '0 0 8080 host3.example.com',
            '0 0 80 faff.host22.example.com'
          )
        end

        it 'does nothing when the record already exists' do
          allow(logger).to receive(:warn).with(instance_of(String))

          existing = DDNSSD::DNSRecord.new("faff._http._tcp", 42, :SRV, 0, 0, 8080, "host3")

          backend.publish_record(existing)

          records = db[:records].where(name: 'faff._http._tcp.example.com').all
          expect(records.count).to eq(2)
          records.each do |rr|
            expect(rr[:ttl]).to eq(42)
            expect(rr[:type]).to eq('SRV')
            expect(rr[:domain_id]).to eq(domain_id)
          end
          expect(records.map { |rr| rr[:content] }).to contain_exactly(
            '0 0 80 faff.host1.example.com',
            '0 0 8080 host3.example.com'
          )
        end
      end
    end

    context 'with a PTR record' do
      let(:dns_record) do
        DDNSSD::DNSRecord.new('_http._tcp', 42, :PTR, 'faff._http._tcp')
      end

      context 'with no existing recordset' do
        it 'creates a new PTR record' do
          backend.publish_record(dns_record)

          records = db[:records].where(name: "_http._tcp.example.com").all
          expect(records.count).to eq(1)
          rr = records.first
          expect(rr[:ttl]).to eq(42)
          expect(rr[:content]).to eq('faff._http._tcp.example.com')
        end
      end

      context 'with existing records for the name/type' do
        before do
          preload_db(
            [
              ["_http._tcp.example.com", 42, :PTR, "xyzzy._http._tcp.example.com"],
              ["_http._tcp.example.com", 42, :PTR, "argle._http._tcp.example.com"],
            ]
          )
        end

        it 'creates a new PTR record' do
          backend.publish_record(dns_record)

          records = db[:records].where(type: "PTR", name: '_http._tcp.example.com').all
          expect(records.count).to eq(3)
          records.each do |rr|
            expect(rr[:ttl]).to eq(42)
            expect(rr[:type]).to eq('PTR')
            expect(rr[:domain_id]).to eq(domain_id)
          end
          expect(records.map { |rr| rr[:content] }).to contain_exactly(
            'xyzzy._http._tcp.example.com',
            'argle._http._tcp.example.com',
            'faff._http._tcp.example.com'
          )
        end

        it 'does nothing when the record already exists' do
          allow(logger).to receive(:warn).with(instance_of(String))

          existing = DDNSSD::DNSRecord.new("_faff._tcp", 42, :PTR, "xyzzy._http._tcp")

          backend.publish_record(existing)

          records = db[:records].where(type: "PTR", name: '_http._tcp.example.com').all
          expect(records.count).to eq(2)
          records.each do |rr|
            expect(rr[:ttl]).to eq(42)
            expect(rr[:type]).to eq('PTR')
            expect(rr[:domain_id]).to eq(domain_id)
          end
          expect(records.map { |rr| rr[:content] }).to contain_exactly(
            'xyzzy._http._tcp.example.com',
            'argle._http._tcp.example.com',
          )
        end
      end
    end
  end

  describe '#suppress_record' do
    context 'with a NS record' do
      it 'raises an error' do
        expect {
          backend.suppress_record(DDNSSD::DNSRecord.new("example.com", 60, :NS, "ns1.example.com"))
        }.to raise_error(DDNSSD::Backend::InvalidRequest)
      end
    end

    context 'with an A record' do
      let(:dns_record) {
        DDNSSD::DNSRecord.new('abcd1234.flingle', 42, :A, '192.0.2.42')
      }

      context 'with no other records in the set' do
        before do
          load_db(["abcd1234.flingle.example.com", 42, :A, "192.0.2.42"])
        end

        it 'deletes the record set' do
          backend.suppress_record(dns_record)
          records = db[:records].where(type: "A", name: 'abcd1234.flingle.example.com').all
          expect(records.count).to eq(0)
        end

        it "logs exceptions and keeps running" do
          allow(db).to receive(:[]).and_raise('Zonk!')
          expect(logger).to receive(:error) do |progname, &blk|
            expect(blk.call).to match(/Zonk/)
          end
          expect { backend.suppress_record(dns_record) }.to_not raise_error
        end
      end

      context 'with other records in the set' do
        before(:each) do
          ['192.0.2.1', '192.0.2.42', '192.0.2.180'].each do |content|
            load_db(["abcd1234.flingle.example.com", 42, :A, content])
          end
        end

        it 'removes just the one record' do
          backend.suppress_record(dns_record)
          records = db[:records].where(type: "A", name: 'abcd1234.flingle.example.com').all
          expect(records.count).to eq(2)
          expect(records.map { |rr| rr[:content] }).to contain_exactly('192.0.2.1', '192.0.2.180')
        end
      end

      context 'record already gone' do
        before(:each) do
          ['192.0.2.1', '192.0.2.180'].each do |content|
            load_db(["abcd1234.flingle.example.com", 42, :A, content])
          end
        end

        it 'changes nothing' do
          backend.suppress_record(dns_record)
          records = db[:records].where(type: "A", name: 'abcd1234.flingle.example.com').all
          expect(records.count).to eq(2)
          expect(records.map { |rr| rr[:content] }).to contain_exactly('192.0.2.1', '192.0.2.180')
        end
      end
    end

    context 'with an AAAA record' do
      let(:dns_record) {
        DDNSSD::DNSRecord.new('flingle', 42, :AAAA, '2001:db8::42')
      }

      context 'with no other records in the set' do
        before do
          load_db(["flingle.example.com", 42, :AAAA, "2001:db8::42"])
        end

        it 'deletes the record set' do
          backend.suppress_record(dns_record)
          records = db[:records].where(type: "AAAA", name: 'flingle.example.com').all
          expect(records.count).to eq(0)
        end
      end

      context 'with other records in the set' do
        before(:each) do
          ['2001:db8::1', '2001:db8::42', '2001:db8::180'].each do |content|
            load_db(['flingle.example.com', 42, :AAAA, content])
          end
        end

        it 'removes the record' do
          backend.suppress_record(dns_record)
          records = db[:records].where(type: "AAAA", name: 'flingle.example.com').all
          expect(records.count).to eq(2)
          expect(records.map { |rr| rr[:content] }).to contain_exactly('2001:db8::1', '2001:db8::180')
        end
      end

      context 'record already gone' do
        before(:each) do
          ['2001:db8::1', '2001:db8::180'].each do |content|
            load_db(['flingle.example.com', 42, :AAAA, content])
          end
        end

        it 'changes nothing' do
          backend.suppress_record(dns_record)
          records = db[:records].where(type: "AAAA", name: 'flingle.example.com').all
          expect(records.count).to eq(2)
          expect(records.map { |rr| rr[:content] }).to contain_exactly('2001:db8::1', '2001:db8::180')
        end
      end
    end

    context 'with a CNAME record' do
      let(:dns_record) {
        DDNSSD::DNSRecord.new('flingle', 42, :CNAME, 'host42')
      }

      context 'with no other records in the set' do
        before do
          load_db(["flingle.example.com", 42, :CNAME, "host42.example.com"])
        end

        it 'deletes the record set' do
          backend.suppress_record(dns_record)
          records = db[:records].where(type: "CNAME", name: 'flingle.example.com').all
          expect(records.count).to eq(0)
        end
      end

      context 'with other records in the set' do
        before(:each) do
          ['host1.example.com', 'host42.example.com', 'host180.example.com'].each do |value|
            load_db(['flingle.example.com', 42, :CNAME, value])
          end
        end

        it 'removes the record' do
          backend.suppress_record(dns_record)
          records = db[:records].where(type: "CNAME", name: 'flingle.example.com').all
          expect(records.count).to eq(2)
          expect(records.map { |rr| rr[:content] }).to contain_exactly('host1.example.com', 'host180.example.com')
        end
      end

      context 'record already gone' do
        before(:each) do
          ['host1.example.com', 'host180.example.com'].each do |content|
            load_db(['flingle.example.com', 42, :CNAME, content])
          end
        end

        it 'changes nothing' do
          backend.suppress_record(dns_record)
          records = db[:records].where(type: "CNAME", name: 'flingle.example.com').all
          expect(records.count).to eq(2)
          expect(records.map { |rr| rr[:content] }).to contain_exactly('host1.example.com', 'host180.example.com')
        end
      end
    end

    context 'with a SRV record' do
      let(:dns_record) do
        DDNSSD::DNSRecord.new('faff._http._tcp', 42, :SRV, 0, 0, 8080, 'host2')
      end

      context 'with other SRV records present' do
        before do
          [
            ["0 0 8080 host1.example.com"],
            ["0 0 8080 host2.example.com"],
          ].each do |value|
            load_db(['faff._http._tcp.example.com', 42, :SRV, value])
          end
        end

        it 'deletes the SRV record' do
          # missing TXT record can log a warning
          allow(logger).to receive(:warn).with(instance_of(String))

          backend.suppress_record(dns_record)

          records = db[:records].where(type: "SRV", name: 'faff._http._tcp.example.com').all
          expect(records.count).to eq(1)
          expect(records.map { |rr| rr[:content] }).to contain_exactly('0 0 8080 host1.example.com')
        end

        it 'does nothing if SRV record does not exist' do
          allow(logger).to receive(:warn).with(instance_of(String))

          backend.suppress_record(
            DDNSSD::DNSRecord.new('faff._http._tcp', 42, :SRV, 0, 0, 80, 'host3')
          )

          records = db[:records].where(type: "SRV", name: 'faff._http._tcp.example.com').all
          expect(records.count).to eq(2)
          expect(records.map { |rr| rr[:content] }).to contain_exactly('0 0 8080 host1.example.com', '0 0 8080 host2.example.com')
        end

        context 'and associated TXT and PTR records' do
          before do
            preload_db([
              ["faff._http._tcp.example.com", 42, :TXT, '"fastplease"'],
              ["_http._tcp.example.com", 42, :PTR, "faff._http._tcp.example.com"]
            ])
          end

          it 'should only delete the SRV record' do
            backend.suppress_record(dns_record)

            records = db[:records].where(type: "SRV", name: 'faff._http._tcp.example.com').all
            expect(records.count).to eq(1)
            expect(records.map { |rr| rr[:content] }).to contain_exactly('0 0 8080 host1.example.com')

            txt_records = db[:records].where(type: "TXT", name: 'faff._http._tcp.example.com').all
            expect(txt_records.count).to eq(1)
            expect(txt_records.first[:content]).to eq('"fastplease"')

            ptr_records = db[:records].where(type: "PTR", name: '_http._tcp.example.com').all
            expect(ptr_records.count).to eq(1)
            expect(ptr_records.first[:content]).to eq('faff._http._tcp.example.com')
          end
        end
      end

      context 'with no other SRV records present' do
        let(:srv_record) {
          DDNSSD::DNSRecord.new('faff._http._tcp', 42, :SRV, 0, 0, 80, 'host1')
        }

        before do
          preload_db([
            ["faff._http._tcp.example.com", 42, :SRV, "0 0 80 host1.example.com"],
            ["faff._http._tcp.example.com", 42, :TXT, 'wrecka stow'],
            ["_http._tcp.example.com",      42, :PTR, "faff._http._tcp.example.com"],
          ])
        end

        context 'with no other PTR records' do
          it 'deletes the SRV, TXT, and PTR records' do
            backend.suppress_record(srv_record)

            expect(db[:records].where(type: "SRV", name: 'faff._http._tcp.example.com').count).to eq(0)
            expect(db[:records].where(type: "TXT", name: 'faff._http._tcp.example.com').count).to eq(0)
            expect(db[:records].where(type: "PTR", name: '_http._tcp.example.com').count).to eq(0)
          end

          it 'retries on transaction conflict' do
            call_count = 0

            original_method = db.method(:[])
            allow(db).to receive(:[]) do |tbl|
              call_count += 1
              if call_count == 3
                raise Sequel::SerializationFailure
              else
                original_method.call(tbl)
              end
            end

            expect(Kernel).to receive(:sleep)
            expect(logger).to_not receive(:error)
            expect { backend.suppress_record(srv_record) }.to_not raise_error

            expect(db[:records].where(type: "SRV", name: 'faff._http._tcp.example.com').count).to eq(0)
            expect(db[:records].where(type: "TXT", name: 'faff._http._tcp.example.com').count).to eq(0)
            expect(db[:records].where(type: "PTR", name: '_http._tcp.example.com').count).to eq(0)
          end

          it 'rolls back on exceptions' do
            call_count = 0

            original_method = db.method(:[])
            allow(db).to receive(:[]) do |tbl|
              call_count += 1
              if call_count == 3
                raise "Flibbety!"
              else
                original_method.call(tbl)
              end
            end

            expect(logger).to receive(:error) do |p, &b|
              expect(b.call).to match(/Flibbety/)
            end
            expect { backend.suppress_record(srv_record) }.to_not raise_error

            expect(db[:records].where(type: "SRV", name: 'faff._http._tcp.example.com').count).to eq(1)
            expect(db[:records].where(type: "TXT", name: 'faff._http._tcp.example.com').count).to eq(1)
            expect(db[:records].where(type: "PTR", name: '_http._tcp.example.com').count).to eq(1)
          end
        end

        context 'with other PTR records' do
          before do
            preload_db([
              ['_http._tcp.example.com',        42, :PTR, 'blargh._http._tcp.example.com'],
              ['blargh._http._tcp.example.com', 42, :SRV, "0 0 80 host7.example.com"],
              ['blargh._http._tcp.example.com', 42, :TXT, 'fastplease'],
            ])
          end

          it "deletes just our SRV, TXT and PTR records" do
            backend.suppress_record(srv_record)
            expect(db[:records].where(type: "SRV", name: 'faff._http._tcp.example.com').count).to eq(0)
            expect(db[:records].where(type: "TXT", name: 'faff._http._tcp.example.com').count).to eq(0)
            ptr_records = db[:records].where(type: "PTR", name: '_http._tcp.example.com')
            expect(ptr_records.count).to eq(1)
            expect(ptr_records.first[:content]).to eq('blargh._http._tcp.example.com')
            expect(db[:records].where(type: "SRV", name: 'blargh._http._tcp.example.com').count).to eq(1)
            expect(db[:records].where(type: "TXT", name: 'blargh._http._tcp.example.com').count).to eq(1)
          end
        end
      end
    end

    context 'with a TXT record' do
      it "logs an error" do
        expect { backend.suppress_record(DDNSSD::DNSRecord.new("x.example.com", 60, :TXT, "")) }.to raise_error(DDNSSD::Backend::InvalidRequest)
      end
    end

    context 'with a PTR record' do
      it "logs an error" do
        expect { backend.suppress_record(DDNSSD::DNSRecord.new("x.example.com", 60, :PTR, "faff.example.com")) }.to raise_error(DDNSSD::Backend::InvalidRequest)
      end
    end
  end
end
