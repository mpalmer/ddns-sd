require 'docker-api'

require 'ddnssd/container'

module DDNSSD
  class DockerWatcher
    # Raise this exception in the thread to signal termination
    class Terminate < Exception; end

    def initialize(queue:, config:)
      @queue, @config = queue, config

      @docker_host = @config.docker_host
      @logger = @config.logger

      @event_count = @config.metrics_registry.counter(:ddnssd_docker_event_total, "How many docker events we have seen and processed")
      @event_count.increment({ type: "ignored" }, 0)
      @event_count.increment({ type: "started" }, 0)
      @event_count.increment({ type: "stopped" }, 0)

      @event_errors = @config.metrics_registry.counter(:ddnssd_docker_event_exceptions_total, "How many exceptions have been raised for handling docker events")

      @op_mutex = Mutex.new
    end

    def run
      # So, you're going to love this... Docker::Event is a chunked-encoding
      # never-ending shitstream, and Docker gets really upset if you try to
      # send another request at it when its trying to stream events at you.
      # That's fair enough.  BUT, Excon caches file descriptors on a
      # per-Unix-socket basis, across all `Excon::Connection` objects, which
      # causes other requests made while `/events` response is still "in
      # progress" to be sent down THE SAME CONNECTION, causing everything to
      # explode.  Everything goes to shit, and the only indication of this is
      # that Excon raises an IOError exception.
      #
      # Instead, the only option is to turn off thread-safe socket caching in
      # Excon, which works in Docker::Connection because it creates a new Excon
      # connection on *every* request (which normally would be derpy as fuck,
      # but it saves our bacon this time).
      #
      # Bug report at https://github.com/excon/excon/issues/640.
      @conn = Docker::Connection.new(@docker_host, read_timeout: 3600, thread_safe_sockets: false)

      refresh_containers

      begin
        loop { process_event }
      rescue Docker::Error::TimeoutError
        retry
      rescue Excon::Error::Socket => ex
        @logger.debug(progname) { (["Got socket error while listening for events: #{ex.message} (#{ex.class})"] + ex.backtrace).join("\n  ") }
        sleep 1
        retry
      rescue DDNSSD::DockerWatcher::Terminate
        return
      rescue StandardError => ex
        @event_errors.increment(class: ex.class.to_s)

        @logger.error(progname) { (["#{ex.message} (#{ex.class})"] + ex.backtrace).join("\n  ") }
        sleep 1
        retry
      end
    rescue StandardError => ex
      @logger.error(progname) { (["Fatal error: #{ex.message} (#{ex.class}).  Terminating."] + ex.backtrace).join("\n  ") }
      @queue.push [:terminate]
    end

    # Async stuff is a right shit to test, and frankly the sorts of bugs that
    # crop up in this stuff are the sort of concurrency shitshows that don't
    # reliably get found by testing anyway.  So...
    #:nocov:
    def run!
      @op_mutex.synchronize do
        return if @runner_thread

        @runner_thread = Thread.new { self.run }
      end
    end

    def shutdown
      @op_mutex.synchronize do
        return if @runner_thread.nil?

        @runner_thread.raise(DDNSSD::DockerWatcher::Terminate)
        @runner_thread.join
        @runner_thread = nil
      end
    end
    #:nocov:

    private

    def progname
      @logger_progname ||= "DDNSSD::DockerWatcher(#{@docker_host.inspect})"
    end

    def refresh_containers
      @logger.info(progname) { "Refreshing all container data" }
      @last_event_time = Time.now.to_i

      @containers = {}

      # Docker's `.all` method returns wildly different data in each
      # container's `.info` structure to what `.get` returns (the API endpoints
      # have completely different schemas), and the `.all` response is missing
      # something things we rather want, so to get everything we need, this
      # individual enumeration is unfortunately necessary -- and, of course,
      # because a container can cease to exist between when we get the list and
      # when we request it again, it all gets far more complicated than it
      # should need to be.
      #
      # Thanks, Docker!
      Docker::Container.all({}, @conn).each do |c|
        begin
          @containers[c.id] = DDNSSD::Container.new(Docker::Container.get(c.id, {}, @conn), @config)
        rescue Docker::Error::NotFoundError
          nil
        end
      end.compact

      @queue.push([:containers, @containers.values])
    end

    def process_event
      @logger.debug(progname) { "Asking for events since #{@last_event_time}" }
      pe_start = Time.now.to_f

      Docker::Event.since(@last_event_time, {}, @conn) do |event|
        @last_event_time = event.time

        @logger.debug(progname) { "#{pe_start}: Docker event@#{event.timeNano}: #{event.Type}.#{event.Action} on #{event.ID}" }

        next unless event.Type == "container"

        queue_item = if event.Action == "start"
          @event_count.increment(type: "started")
          [:started, @containers[event.ID] = DDNSSD::Container.new(Docker::Container.get(event.ID, {}, @conn), @config)]
        elsif event.Action == "die" && @containers[event.ID]
          @event_count.increment(type: "stopped")
          [:stopped, @containers[event.ID]]
        else
          @event_count.increment(type: "ignored")
          nil
        end

        next if queue_item.nil? || queue_item.last.nil?

        @queue.push(queue_item)
      end
    end
  end
end
