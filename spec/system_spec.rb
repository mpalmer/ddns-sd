require_relative './spec_helper'

require 'ddnssd/system'
require 'ddnssd/backend/test_queue'

describe DDNSSD::System do
  uses_logger

  let(:base_env) do
    { "DDNSSD_HOSTNAME"        => "speccy",
      "DDNSSD_BASE_DOMAIN"     => "example.com",
      "DDNSSD_BACKEND"         => "test_queue",
      "DDNSSD_HOST_IP_ADDRESS" => "192.0.2.42"
    }
  end
  let(:env) { base_env }

  let(:system) { DDNSSD::System.new(env, logger: logger) }

  describe ".new" do
    it "passes the env+logger through to the config" do
      expect(DDNSSD::Config).to receive(:new).with(env, logger: logger).and_call_original

      DDNSSD::System.new(env, logger: logger)
    end
  end

  describe "#config" do
    it "returns the config" do
      expect(system.config).to be_a(DDNSSD::Config)
    end
  end

  let(:mock_queue) { instance_double(Queue) }
  let(:mock_watcher) { instance_double(DDNSSD::DockerWatcher) }
  let(:mock_backend) { instance_double(DDNSSD::Backend::TestQueue) }

  before(:each) do
    allow(DDNSSD::DockerWatcher).to receive(:new).with(queue: mock_queue, config: instance_of(DDNSSD::Config)).and_return(mock_watcher)
    allow(Queue).to receive(:new).and_return(mock_queue)
    allow(mock_queue).to receive(:pop).and_return([:terminate])
    allow(mock_watcher).to receive(:run!)
    allow(DDNSSD::Backend::TestQueue).to receive(:new).with(instance_of(DDNSSD::Config)).and_return(mock_backend)
    allow(mock_queue).to receive(:push)
    allow(mock_watcher).to receive(:shutdown)
    allow(mock_backend).to receive(:publish_record)
  end

  describe "#shutdown" do
    it "sends the special :terminate message" do
      expect(mock_queue).to receive(:push).with([:terminate])

      system.shutdown
    end

    it "tells the watcher to shutdown" do
      expect(mock_watcher).to receive(:shutdown)

      system.shutdown
    end
  end

  describe "#run" do
    context "initialization" do
      it "creates a queue" do
        expect(Queue).to receive(:new)

        system.run
      end

      it "listens on the queue" do
        expect(mock_queue).to receive(:pop)

        system.run
      end

      it "fires up a docker watcher" do
        expect(DDNSSD::DockerWatcher).to receive(:new).with(queue: mock_queue, config: instance_of(DDNSSD::Config))
        expect(mock_watcher).to receive(:run!)

        system.run
      end

      context "if enable_metrics is true" do
        let(:env) { base_env.merge("DDNSSD_ENABLE_METRICS" => "yes") }
        let(:mock_metrics_server) { instance_double(Frankenstein::Server) }

        it "fires up the metrics server" do
          expect(Frankenstein::Server).to receive(:new).with(port: 9218, logger: logger, registry: instance_of(Prometheus::Client::Registry)).and_return(mock_metrics_server)
          expect(mock_metrics_server).to receive(:run)

          system.run
        end
      end
    end

    describe ":containers message" do
      before(:each) do
        expect(mock_backend).to receive(:dns_records).and_return(dns_records)
        expect(mock_queue).to receive(:pop).and_return([:containers, containers])
        allow(mock_backend).to receive(:publish_record)
      end

      context "when there's a new container" do
        let(:dns_records) { dns_record_fixtures("exposed_port80", "other_machine") + [DDNSSD::DNSRecord.new("example.com", 60, :NS, "ns1.example.com")] }
        let(:containers) { container_fixtures("exposed_port80", "published_port80").map { |dc| DDNSSD::Container.new(dc, system.config) } }

        it "adds records for the new container" do
          dns_record_fixture("published_port80").each do |rr|
            expect(mock_backend).to receive(:publish_record).with(eq(rr)).ordered
          end

          system.run
        end

        it "publishes the host's IP address" do
          expect(mock_backend).to receive(:publish_record).with(DDNSSD::DNSRecord.new("speccy.example.com", 60, :A, "192.0.2.42"))

          system.run
        end
      end

      context "when a container has been removed" do
        let(:dns_records) { dns_record_fixtures("exposed_port80", "published_port80", "other_machine") }
        let(:containers) { container_fixtures("published_port80").map { |dc| DDNSSD::Container.new(dc, system.config) } }

        it "removes the records from the removed container" do
          dns_record_fixture("exposed_port80").each do |rr|
            next if [Resolv::DNS::Resource::IN::TXT, Resolv::DNS::Resource::IN::PTR].include?(rr.data.class)

            expect(mock_backend).to receive(:suppress_record).with(eq(rr))
          end

          system.run
        end
      end

      context "when a container has changed" do
        let(:dns_records) { dns_record_fixtures("published_port80") }
        let(:containers) do
          docker_container = container_fixture("published_port80")
          docker_container.info["NetworkSettings"]["Ports"]["80/tcp"].first["HostPort"] = "1337"

          [DDNSSD::Container.new(docker_container, system.config)]
        end

        it "removes the obsolete record and adds a new one" do
          expect(mock_backend)
            .to receive(:suppress_record)
            .with(eq(DDNSSD::DNSRecord.new("pub80._http._tcp.example.com", 60, :SRV, 0, 0, 8080, "speccy.example.com")))
          expect(mock_backend)
            .to receive(:publish_record)
            .with(eq(DDNSSD::DNSRecord.new("pub80._http._tcp.example.com", 60, :SRV, 0, 0, 1337, "speccy.example.com")))

          system.run
        end
      end

      context "when DDNSSD_RECORD_TTL has changed" do
        let(:env) { base_env.merge("DDNSSD_RECORD_TTL" => "42") }
        let(:dns_records) { dns_record_fixtures("published_port80") }
        let(:containers) { container_fixtures("published_port80").map { |dc| DDNSSD::Container.new(dc, system.config) } }

        it "removes the records with the wrong TTL and adds new ones with the right TTL" do
          dns_record_fixture("published_port80").each do |rr|
            next if [Resolv::DNS::Resource::IN::TXT, Resolv::DNS::Resource::IN::PTR].include?(rr.data.class)

            expect(mock_backend).to receive(:suppress_record).with(eq(rr))
          end

          dns_record_fixture("published_port80").each do |rr|
            rr.instance_variable_set(:@ttl, 42)
            expect(mock_backend).to receive(:publish_record).with(eq(rr))
          end

          system.run
        end
      end
    end

    describe "message processing" do
      let(:a_record) { DDNSSD::DNSRecord.new("a.example.com", 60, :A, "192.0.2.42") }
      let(:srv_record) { DDNSSD::DNSRecord.new("srv.example.com", 60, :SRV, 0, 0, 80, "a.example.com") }
      let(:ptr_record) { DDNSSD::DNSRecord.new("ptr.example.com", 60, :PTR, "srv.example.com") }
      let(:container) { Struct.new(:dns_records).new([a_record, srv_record, ptr_record]) }

      describe ":started" do
        it "tells the backend there are some new DNS records" do
          expect(mock_queue).to receive(:pop).and_return([:started, container])

          expect(mock_backend).to receive(:publish_record).with(a_record).ordered
          expect(mock_backend).to receive(:publish_record).with(srv_record).ordered
          expect(mock_backend).to receive(:publish_record).with(ptr_record).ordered

          system.run
        end
      end

      describe ":stopped" do
        it "tells the backend to remove some records in reverse order" do
          expect(mock_queue).to receive(:pop).and_return([:stopped, container])

          expect(mock_backend).to receive(:suppress_record).with(srv_record).ordered
          expect(mock_backend).to receive(:suppress_record).with(a_record).ordered

          system.run
        end
      end
    end

    describe "unknown message" do
      it "logs an error" do
        expect(mock_queue).to receive(:pop).and_return("whaddya mean this ain't a valid message?!?")

        expect(logger).to receive(:error)

        system.run
      end
    end
  end
end
