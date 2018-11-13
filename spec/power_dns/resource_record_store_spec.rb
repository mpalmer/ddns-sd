require_relative '../spec_helper'

require 'ddnssd/backend/power_dns'
require 'ddnssd/power_dns/resource_record_store'

describe DDNSSD::PowerDNS::ResourceRecordStore do
  uses_logger
  after(:each) { pdns_db_clean }

  let(:config) { DDNSSD::Config.new(power_dns_test_config, logger: logger) }
  let(:backend) { DDNSSD::Backend::PowerDNS.new(config) }
  let(:rr_store) { DDNSSD::PowerDNS::ResourceRecordStore.new(backend, 'example.com', logger) }
  let(:a_record) { DDNSSD::DNSRecord.new('power.sd.example.com', 42, :A, '192.0.2.42') }

  describe '#add' do
    context 'no existing record' do
      it 'adds a new row to the db' do
        count = rr_store.add(a_record)
        expect(count).to eq(1)

        rows = rr_store.lookup(name: a_record.name)
        expect(rows.size).to eq(1)
        r = rows.first
        expect(r.name).to eq('power.sd.example.com')
        expect(r.ttl).to eq(42)
        expect(r.type).to eq('A')
        expect(r.content).to eq('192.0.2.42')
      end

      it 'makes name lowercase' do
        count = rr_store.add(
          DDNSSD::DNSRecord.new('SHOUT.sd.example.com', 42, :A, '192.0.2.42')
        )
        expect(count).to eq(1)
      end
    end

    context 'existing record' do
      let!(:existing) { rr_store.add(a_record) }

      it 'does nothing' do
        allow(logger).to receive(:warn).with(instance_of(String))

        count = rr_store.add(a_record)
        expect(count).to eq(0)

        rows = rr_store.lookup(name: a_record.name)
        expect(rows.size).to eq(1)
      end
    end
  end

  describe '#remove' do
    context 'with matching record' do
      let!(:existing) { rr_store.add(a_record) }

      it 'deletes the record' do
        count = rr_store.remove(a_record)
        expect(count).to eq(1)
        rows = rr_store.lookup(name: a_record.name)
        expect(rows.size).to eq(0)
      end
    end

    context 'with no matching record' do
      it 'deletes nothing' do
        count = rr_store.remove(a_record)
        expect(count).to eq(0)
        rows = rr_store.lookup(name: a_record.name)
        expect(rows.size).to eq(0)
      end
    end
  end

end
