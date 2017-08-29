require_relative './spec_helper'
require 'logger'
require 'yaml'

require 'ddnssd/config'
require 'ddnssd/docker_watcher'

describe DDNSSD::DockerWatcher do
  uses_logger

  def test_event(type: "container", action:, id:, time: 987654321)
    Docker::Event.new(Type: type, Action: action, id: id, time: time)
  end

  let(:env) do
    {
      "DDNSSD_BASE_DOMAIN" => "example.com",
      "DDNSSD_BACKEND"     => "test_queue",
      "DDNSSD_HOSTNAME"    => "speccy",
      "DOCKER_HOST"        => "unix:///var/run/test.sock"
    }
  end
  let(:config) { DDNSSD::Config.new(env, logger: logger) }

  let(:queue)   { Queue.new }
  let(:watcher) { DDNSSD::DockerWatcher.new(queue: queue, config: config) }

  describe ".new" do
    it "takes a queue and a docker socket URL" do
      expect(watcher).to be_a(DDNSSD::DockerWatcher)
    end
  end

  describe "#run" do
    let(:containers) { container_fixtures("published_port80") }

    let(:mock_conn) { instance_double(Docker::Connection) }

    before(:each) do
      # This one's for the container_fixture calls
      allow(Docker::Connection).to receive(:new).with("unix:///", {}).and_call_original
      # This is the real one
      allow(Docker::Connection).to receive(:new).with("unix:///var/run/test.sock", thread_safe_sockets: false, read_timeout: 3600).and_return(mock_conn)

      # I'm a bit miffed we have to do this; to my mind, a double should
      # lie a little
      allow(mock_conn).to receive(:is_a?).with(Docker::Connection).and_return(true)
      allow(Docker::Event).to receive(:since).and_raise(DDNSSD::DockerWatcher::Terminate)
      allow(Docker::Container).to receive(:all).with({}, mock_conn).and_return(containers)
      allow(Docker::Container).to receive(:get).with("asdfasdfpub80", {}, mock_conn).and_return(container_fixture("published_port80"))
      allow(Time).to receive(:now).and_return(Time.at(1234567890))
    end

    it "connects to the specified socket with a long read timeout" do
      watcher.run

      expect(Docker::Connection).to have_received(:new).with("unix:///var/run/test.sock", read_timeout: 3600, thread_safe_sockets: false)
    end

    it "requests a current container list" do
      watcher.run

      expect(Docker::Container).to have_received(:all).with({}, mock_conn)
    end

    it "sends a list of all containers to the queue" do
      watcher.run

      expect(queue.length).to eq(1)
      item = queue.pop

      expect(item.first).to eq(:containers)
      expect(item.last).to be_an(Array)
      expect(item.last.first).to be_a(DDNSSD::Container)
    end

    it "doesn't send back containers that disappear between the all and the get" do
      expect(Docker::Container).to receive(:all).with({}, mock_conn).and_return(container_fixtures("published_port80", "published_port22", "exposed_port80"))
      expect(Docker::Container).to receive(:get).with("asdfasdfpub80", {}, mock_conn).and_return(container_fixture("published_port80"))
      expect(Docker::Container).to receive(:get).with("asdfasdfpub22", {}, mock_conn).and_raise(Docker::Error::NotFoundError)
      expect(Docker::Container).to receive(:get).with("asdfasdfexposed80", {}, mock_conn).and_return(container_fixture("exposed_port80"))

      watcher.run
      expect(queue.length).to eq(1)
      item = queue.pop

      expect(item.first).to be(:containers)

      expect(item.last.length).to eq(2)
      expect(item.last.all? { |i| i.port_exposed?("80/tcp") }).to be(true)
    end

    it "watches for events since the startup time" do
      expect(Docker::Event).to receive(:since).with(1234567890, {}, mock_conn)

      watcher.run
    end

    it "emits a started event when a container is started" do
      expect(Docker::Event).to receive(:since).with(1234567890, {}, mock_conn).and_yield(test_event(action: "start", id: "asdfasdfpub80"))
      expect(Docker::Container).to receive(:get).with("asdfasdfpub80", {}, mock_conn).and_return(container_fixture("published_port80"))

      watcher.run

      expect(queue.length).to eq(2)
      queue.pop
      item = queue.pop

      expect(item.first).to eq(:started)
      expect(item.last).to be_a(DDNSSD::Container)
      expect(item.last.name).to eq("pub80")
    end

    it "emits a stopped when a container dies" do
      expect(Docker::Event).to receive(:since).with(1234567890, {}, mock_conn).and_yield(test_event(action: "die", id: "asdfasdfpub80"))

      watcher.instance_variable_set(:@containers, "asdfasdfpub80" => :not_a_container)
      watcher.run

      expect(queue.length).to eq(2)
      queue.pop
      item = queue.pop

      expect(item.first).to eq(:stopped)
      expect(item.last).to be_a(DDNSSD::Container)
      expect(item.last.name).to eq("pub80")
    end

    it "ignores uninteresting events" do
      expect(Docker::Event).to receive(:since).with(1234567890, {}, mock_conn).and_yield(test_event(type: "container", action: "spindle", id: "zomg"))

      watcher.run

      expect(queue.length).to eq(1)
    end

    it "continues where it left off after timeout" do
      # This is the first round of Event calls; get an event and then timeout
      expect(Docker::Event).to receive(:since).with(1234567890, {}, mock_conn).and_yield(test_event(action: "create", id: "nope")).and_raise(Docker::Error::TimeoutError)
      # This is the retry, and terminate
      expect(Docker::Event).to receive(:since).with(987654321, {}, mock_conn).and_raise(DDNSSD::DockerWatcher::Terminate)

      watcher.run
    end

    it "delays then retries on socket error" do
      expect(Docker::Event).to receive(:since).with(1234567890, {}, mock_conn).and_raise(Excon::Error::Socket)
      expect(watcher).to receive(:sleep).with(1)
      expect(Docker::Event).to receive(:since).with(1234567890, {}, mock_conn).and_raise(DDNSSD::DockerWatcher::Terminate)

      watcher.run
    end

    it "logs unknown exceptions in the event processing loop" do
      expect(Docker::Event).to receive(:since).with(1234567890, {}, mock_conn).and_raise(RuntimeError, "ZOMG")
      expect(logger).to receive(:error)
      expect(watcher).to receive(:sleep).with(1)
      expect(Docker::Event).to receive(:since).with(1234567890, {}, mock_conn).and_raise(DDNSSD::DockerWatcher::Terminate)

      watcher.run
    end

    it "logs an error and terminates on Docker connection failure" do
      expect(Docker::Connection).to receive(:new).and_raise(RuntimeError)
      expect(logger).to receive(:error)
      expect(queue).to receive(:push).with([:terminate])

      watcher.run
    end
  end
end
