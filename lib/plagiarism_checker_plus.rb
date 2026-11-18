# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "time"
require "uri"

# Client for the Plagiarism Checker Plus public API. Standard library only.
module PlagiarismCheckerPlus
  VERSION = "1.1.0"
  DEFAULT_BASE_URL = "https://app.plagiarismcheckerplus.com/api/public/v1"

  module ErrorCodes
    # Deprecated: no longer returned. Free accounts get a free API trial and free test keys.
    PLAN_REQUIRED = "plan_required"
    TEXT_TOO_SHORT = "text_too_short"
    DOC_TOO_LONG = "doc_too_long"
    # 402: not enough words across all sources (wordsNeeded, wordsAvailable, balances, billingUrl).
    INSUFFICIENT_WORDS = "insufficient_words"
    # 402: the free API trial cannot cover the request (wordsNeeded, trialRemaining, trialTotal, billingUrl).
    TRIAL_EXHAUSTED = "trial_exhausted"
    # 402: the key's monthly word cap would be exceeded (wordsNeeded, monthlyWordCap, usedThisMonth).
    KEY_CAP_REACHED = "key_cap_reached"
    INVALID_REQUEST = "invalid_request"
    INVALID_JSON = "invalid_json"
    UNAUTHORIZED = "unauthorized"
    INVALID_API_KEY = "invalid_api_key"
    KEY_REVOKED = "key_revoked"
    EMAIL_UNVERIFIED = "email_unverified"
    FORBIDDEN = "forbidden"
    NOT_FOUND = "not_found"
    RATE_LIMITED = "rate_limited"
    WORKERS_UNAVAILABLE = "workers_unavailable"
    INTERNAL_ERROR = "internal_error"
  end

  # A non-2xx response. +code+ is the API's error code, such as insufficient_words.
  # +details+ is the response's error object (wordsNeeded, billingUrl and other detail fields).
  class Error < StandardError
    attr_reader :status, :code, :retry_after, :body

    def initialize(message, status: 0, code: nil, retry_after: nil, body: nil)
      super(message)
      @status = status
      @code = code
      @retry_after = retry_after
      @body = body
    end

    # The response's error object: code, message and any detail fields, or {}.
    def details
      body.is_a?(Hash) && body["error"].is_a?(Hash) ? body["error"] : {}
    end
  end

  # Verifies webhook deliveries. Each one carries
  #   PCP-Signature: t=<unix seconds>,v1=<hex HMAC-SHA256(secret, "<t>.<raw body>")>
  module Webhook
    SIGNATURE_HEADER = "PCP-Signature"
    # How old a signed timestamp may be, in seconds, before it is rejected.
    DEFAULT_TOLERANCE = 300

    # Check a PCP-Signature header against the raw request body (before JSON parsing).
    # Returns false for a missing or malformed header, a wrong signature, or a timestamp
    # more than +tolerance+ seconds from +now+ (unix seconds, default the current time).
    # Signatures are compared in constant time.
    def self.verify_signature(secret, header, body, tolerance: DEFAULT_TOLERANCE, now: nil)
      return false if secret.nil? || secret.empty? || header.nil? || header.empty? || body.nil?

      timestamp = nil
      signatures = []
      header.to_s.split(",").each do |part|
        key, value = part.split("=", 2).map { |v| v.to_s.strip }
        next if value.nil? || value.empty?

        if key == "t" && value.match?(/\A\d+\z/)
          timestamp = value.to_i
        elsif key == "v1" && value.match?(/\A\h+\z/)
          signatures << value.downcase
        end
      end
      return false if timestamp.nil? || signatures.empty?
      return false if ((now || Time.now.to_i) - timestamp).abs > tolerance

      expected = OpenSSL::HMAC.hexdigest("SHA256", secret, "#{timestamp}.".b + body.to_s.b)
      signatures.any? { |signature| secure_compare(expected, signature) }
    end

    def self.secure_compare(a, b)
      return false unless a.bytesize == b.bytesize

      result = 0
      a.bytes.zip(b.bytes) { |x, y| result |= x ^ y }
      result.zero?
    end
    private_class_method :secure_compare
  end

  class ScanTimeoutError < StandardError; end

  # Response passed back by a transport.
  Response = Struct.new(:status, :headers, :body)

  # Default transport using Net::HTTP.
  class NetHttpTransport
    def initialize(timeout: 30)
      @timeout = timeout
    end

    def call(method, url, headers, body)
      uri = URI(url)
      request = Net::HTTPGenericRequest.new(method, !body.nil?, true, uri.request_uri, headers)
      request.body = body if body
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = @timeout
      http.read_timeout = @timeout
      response = http.request(request)
      Response.new(response.code.to_i, response.each_header.to_h, response.body.to_s)
    end
  end

  def self.parse_retry_after(value)
    return nil if value.nil? || value.to_s.empty?
    return [Float(value), 0.0].max if value.to_s.match?(/\A\d+(\.\d+)?\z/)

    [Time.httpdate(value.to_s) - Time.now, 0.0].max
  rescue ArgumentError
    nil
  end

  class Client
    # transport: anything responding to call(method, url, headers, body) -> Response.
    def initialize(api_key:, base_url: DEFAULT_BASE_URL, transport: NetHttpTransport.new)
      raise ArgumentError, "api_key is required" if api_key.nil? || api_key.empty?

      @api_key = api_key
      @base_url = base_url.chomp("/")
      @transport = transport
    end

    # Submit text. tools: any of "plagiarism" and "ai_detect".
    def create_scan(text, tools, name: nil)
      body = { text: text, tools: tools }
      body[:name] = name unless name.nil?
      request("POST", "/scans", body: body)
    end

    def get_scan(id, include_text: false)
      request("GET", "/scans/#{URI.encode_www_form_component(id)}", query: include_text ? { include_text: "true" } : nil)
    end

    def list_scans(page: nil, limit: nil)
      request("GET", "/scans", query: { page: page, limit: limit })
    end

    # Plan, word balances, free API trial ("trial"), "balances", "autoTopup" and this key's "key" mode and cap.
    def get_account
      request("GET", "/account")
    end

    # Poll until the scan is completed or failed, honouring Retry-After on 429.
    def wait_for_scan(id, timeout: 300, interval: 2.0, max_interval: 10.0, include_text: false, sleeper: method(:sleep))
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      delay = interval
      loop do
        wait = delay
        begin
          scan = get_scan(id, include_text: include_text)
          return scan if %w[completed failed].include?(scan["status"])

          delay = [delay * 1.5, max_interval].min
        rescue Error => e
          raise unless e.status == 429

          wait = e.retry_after || delay
        end
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait > deadline
          raise ScanTimeoutError, "Scan #{id} did not finish within #{timeout} seconds"
        end

        sleeper.call(wait)
      end
    end

    private

    def request(method, path, query: nil, body: nil)
      url = @base_url + path
      params = (query || {}).reject { |_, v| v.nil? }
      url += "?#{URI.encode_www_form(params)}" unless params.empty?
      headers = {
        "Authorization" => "Bearer #{@api_key}",
        "Accept" => "application/json",
        "User-Agent" => "plagiarism-checker-plus-ruby/#{VERSION}"
      }
      payload = nil
      unless body.nil?
        headers["Content-Type"] = "application/json"
        payload = JSON.generate(body)
      end
      response = @transport.call(method, url, headers, payload)
      data = response.body.to_s.empty? ? nil : (JSON.parse(response.body) rescue nil)
      return data || {} if response.status.between?(200, 299)

      error = data.is_a?(Hash) && data["error"].is_a?(Hash) ? data["error"] : {}
      retry_header = response.headers.find { |k, _| k.to_s.casecmp?("retry-after") }&.last
      raise Error.new(error["message"] || "HTTP #{response.status}",
                      status: response.status,
                      code: error["code"],
                      retry_after: PlagiarismCheckerPlus.parse_retry_after(retry_header),
                      body: data)
    end
  end
end
