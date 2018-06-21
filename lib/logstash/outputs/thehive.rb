# encoding: utf-8
require "logstash/outputs/base"
require "logstash/namespace"
require "logstash/json"
require "uri"
require "logstash/plugin_mixins/http_client"
require "zlib"
require "awesome_print"

# An thehive output that does nothing.
class LogStash::Outputs::Thehive < LogStash::Outputs::Base
  include LogStash::PluginMixins::HttpClient

  concurrency :shared

  RETRYABLE_MANTICORE_EXCEPTIONS = [
    ::Manticore::Timeout,
    ::Manticore::SocketException,
    ::Manticore::ClientProtocolException,
    ::Manticore::ResolutionFailure,
    ::Manticore::SocketTimeout
  ]

  config_name "thehive"

  # TheHive URL
  config :url, :validate => :string, :required => :true

  # TheHive API Key
  config :key, :validate => :string, :required => :true

  config :title,       :validate => :string, :required => :true
  config :description, :validate => :string, :required => :true
  config :type,        :validate => :string, :required => :true
  config :source,      :validate => :string, :required => :true
  config :sourceRef,   :validate => :string, :required => :true
  config :severity,    :validate => :number, :default => 2
  config :tlp,         :validate => :number, :default => 2
  config :tags,        :validate => :array,  :default => []
  config :caseTemplate,:validate => :string, :default => ''
  config :artifacts,   :default => nil

  # Set this to false if you don't want this output to retry failed requests
  config :retry_failed, :validate => :boolean, :default => true
  
  # If encountered as response codes this plugin will retry these requests
  config :retryable_codes, :validate => :number, :list => true, :default => [429, 500, 502, 503, 504]
  
  # If you would like to consider some non-2xx codes to be successes 
  # enumerate them here. Responses returning these codes will be considered successes
  config :ignorable_codes, :validate => :number, :list => true

  def register
    @http_method = :post
    @content_type = "application/json"

    # We count outstanding requests with this queue
    # This queue tracks the requests to create backpressure
    # When this queue is empty no new requests may be sent,
    # tokens must be added back by the client on success
    @request_tokens = SizedQueue.new(@pool_max)
    @pool_max.times {|t| @request_tokens << true }

    @requests = Array.new

    @headers = {}
    @headers["Content-Type"]     = @content_type
    @headers["Content-Encoding"] = "gzip"
    @headers["Authorization"]   = "Bearer " + @key

    # Run named Timer as daemon thread
    @timer = java.util.Timer.new("TheHive Output #{self.params['id']}", true)
  end # def register

  def multi_receive(events)
    return if events.empty?
    send_events(events)
  end
  
  class RetryTimerTask < java.util.TimerTask
    def initialize(pending, event, attempt)
      @pending = pending
      @event = event
      @attempt = attempt
      super()
    end
    
    def run
      @pending << [@event, @attempt]
    end
  end

  def log_retryable_response(response)
    if (response.code == 429)
      @logger.debug? && @logger.debug("Encountered a 429 response, will retry. This is not serious, just flow control via HTTP")
    else
      @logger.warn("Encountered a retryable HTTP request in HTTP output, will retry", :code => response.code, :body => response.body)
    end
  end

  def log_error_response(response, url, event)
    log_failure(
              "Encountered non-2xx HTTP code #{response.code}",
              :response_code => response.code,
              :url => url,
              :event => event
            )
  end
  
  def send_events(events)
    successes = java.util.concurrent.atomic.AtomicInteger.new(0)
    failures  = java.util.concurrent.atomic.AtomicInteger.new(0)
    retries = java.util.concurrent.atomic.AtomicInteger.new(0)
    
    pending = Queue.new
    events.each {|e| pending << [e, 0]}

    while popped = pending.pop
      break if popped == :done
      
      event, attempt = popped
      
      send_event(event, attempt) do |action,event,attempt|
        begin 
          action = :failure if action == :retry && !@retry_failed
          
          case action
          when :success
            successes.incrementAndGet
          when :retry
            retries.incrementAndGet
            
            next_attempt = attempt+1
            sleep_for = sleep_for_attempt(next_attempt)
            @logger.info("Retrying http request, will sleep for #{sleep_for} seconds")
            timer_task = RetryTimerTask.new(pending, event, next_attempt)
            @timer.schedule(timer_task, sleep_for*1000)
          when :failure 
            failures.incrementAndGet
          else
            raise "Unknown action #{action}"
          end
          
          if action == :success || action == :failure 
            if successes.get+failures.get == events.size
              pending << :done
            end
          end
        rescue => e 
          # This should never happen unless there's a flat out bug in the code
          @logger.error("Error sending HTTP Request",
            :class => e.class.name,
            :message => e.message,
            :backtrace => e.backtrace)
          failures.incrementAndGet
          raise e
        end
      end
    end
  rescue => e
    @logger.error("Error in http output loop",
            :class => e.class.name,
            :message => e.message,
            :backtrace => e.backtrace)
    raise e
  end
  
  def sleep_for_attempt(attempt)
    sleep_for = attempt**2
    sleep_for = sleep_for <= 60 ? sleep_for : 60
    (sleep_for/2) + (rand(0..sleep_for)/2)
  end
  
  def send_event(event, attempt)
    body = map_event(event)
    ap body, :indent => -2
    body = LogStash::Json.dump(body)

    # Send the request
    url = event.sprintf(@url)
    headers = @headers

    # Compress the body
    body = gzip(body)

    # Create an async request
    request = client.background.send(@http_method, url, :body => body, :headers => headers)

    request.on_success do |response|
      begin
        if !response_success?(response)
          if retryable_response?(response)
            log_retryable_response(response)
            yield :retry, event, attempt
          else
            log_error_response(response, url, event)
            yield :failure, event, attempt
          end
        else
          yield :success, event, attempt
        end
      rescue => e 
        # Shouldn't ever happen
        @logger.error("Unexpected error in request success!",
          :class => e.class.name,
          :message => e.message,
          :backtrace => e.backtrace)
      end
    end

    request.on_failure do |exception|
      begin 
        will_retry = retryable_exception?(exception)
        log_failure("Could not fetch URL",
                    :url => url,
                    :method => @http_method,
                    :body => body,
                    :headers => headers,
                    :message => exception.message,
                    :class => exception.class.name,
                    :backtrace => exception.backtrace,
                    :will_retry => will_retry
        )
        
        if will_retry
          yield :retry, event, attempt
        else
          yield :failure, event, attempt
        end
      rescue => e 
        # Shouldn't ever happen
        @logger.error("Unexpected error in request failure!",
          :class => e.class.name,
          :message => e.message,
          :backtrace => e.backtrace)
        end
    end

    # Actually invoke the request in the background
    # Note: this must only be invoked after all handlers are defined, otherwise
    # those handlers are not guaranteed to be called!
    request.call 
  end

  def close
    @timer.cancel
    client.close
  end

  private
  
  def response_success?(response)
    code = response.code
    return true if @ignorable_codes && @ignorable_codes.include?(code)
    return code >= 200 && code <= 299
  end
  
  def retryable_response?(response)
    @retryable_codes.include?(response.code)
  end
  
  def retryable_exception?(exception)
    RETRYABLE_MANTICORE_EXCEPTIONS.any? {|me| exception.is_a?(me) }
  end

  # This is split into a separate method mostly to help testing
  def log_failure(message, opts)
    @logger.error("[TheHive Output Failure] #{message}", opts)
  end

  # gzip data
  def gzip(data)
    gz = StringIO.new
    gz.set_encoding("BINARY")
    z = Zlib::GzipWriter.new(gz)
    z.write(data)
    z.close
    gz.string
  end

  def convert_tags(tags, event)
      tags.map { |elem| event.sprintf(elem) }
  end

  def convert_artifacts(artifacts, event)
    return nil if artifacts == nil
    if artifacts.is_a?(Hash)
      artifacts = artifacts.reduce(LogStash::Event.new) do |acc, kv|
        k, v = kv
        acc.set("_hack" + event.sprintf(k), event.sprintf(v))
        acc
      end
      artifacts.get("_hack").values

    elsif artifacts.is_a?(String)
      event.get(artifacts)&.values

    else
      nil
    end
  end

  def map_event(event)
    {
      "caseTemplate" => event.sprintf(@caseTemplate),
      "type"         => event.sprintf(@type),
      "title"        => event.sprintf(@title),
      "description"  => event.sprintf(@description),
      "source"       => event.sprintf(@source),
      "sourceRef"    => event.sprintf(@sourceRef),
      "artifacts"    => convert_artifacts(@artifacts, event),
      "tags"         => convert_tags(@tags, event),
      "severity"     => @severity,
      "tlp"          => @tlp,
    }
  end
end
