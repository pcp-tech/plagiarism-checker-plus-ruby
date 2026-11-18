# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "openssl"
require_relative "../lib/plagiarism_checker_plus"

class FakeTransport
  attr_reader :calls

  def initialize(responses)
    @responses = responses
    @calls = []
  end

  def call(method, url, headers, body)
    @calls << [method, url, headers, body]
    status, headers_out, payload = @responses.shift
    PlagiarismCheckerPlus::Response.new(status, headers_out, payload.nil? ? "" : JSON.generate(payload))
  end
end

class ClientTest < Minitest::Test
  def client(transport)
    PlagiarismCheckerPlus::Client.new(api_key: "pcp_test", transport: transport)
  end

  def test_create_scan
    t = FakeTransport.new([[202, {}, { "id" => "s1", "status" => "processing" }]])
    assert_equal "s1", client(t).create_scan("text", ["plagiarism"], name: "draft")["id"]
    method, url, headers, body = t.calls.first
    assert_equal "POST", method
    assert_equal "https://app.plagiarismcheckerplus.com/api/public/v1/scans", url
    assert_equal "Bearer pcp_test", headers["Authorization"]
    assert_equal({ "text" => "text", "tools" => ["plagiarism"], "name" => "draft" }, JSON.parse(body))
  end

  def test_query_parameters
    t = FakeTransport.new([[200, {}, { "id" => "s1" }], [200, {}, { "data" => [] }]])
    c = client(t)
    c.get_scan("s1", include_text: true)
    c.list_scans(page: 2, limit: 5)
    assert t.calls[0][1].end_with?("/scans/s1?include_text=true")
    assert t.calls[1][1].end_with?("/scans?page=2&limit=5")
  end

  def test_error_code_and_details
    billing = "https://app.plagiarismcheckerplus.com/developers/billing"
    t = FakeTransport.new([[402, {}, { "error" => { "code" => "key_cap_reached", "message" => "Cap reached",
                                                    "monthlyWordCap" => 5000, "billingUrl" => billing } }]])
    error = assert_raises(PlagiarismCheckerPlus::Error) { client(t).create_scan("text", ["plagiarism"]) }
    assert_equal 402, error.status
    assert_equal PlagiarismCheckerPlus::ErrorCodes::KEY_CAP_REACHED, error.code
    assert_equal 5000, error.details["monthlyWordCap"]
    assert_equal "trial_exhausted", PlagiarismCheckerPlus::ErrorCodes::TRIAL_EXHAUSTED
    assert_equal "plan_required", PlagiarismCheckerPlus::ErrorCodes::PLAN_REQUIRED
  end

  def test_webhook_signature
    secret = "whsec_test_secret"
    body = '{"id":"evt_1","type":"scan.completed","data":{}}'
    ts = 1_800_000_000
    sign = ->(t, b, k = secret) { OpenSSL::HMAC.hexdigest("SHA256", k, "#{t}.#{b}") }
    header = "t=#{ts},v1=#{sign.call(ts, body)}"
    w = PlagiarismCheckerPlus::Webhook
    assert_equal "PCP-Signature", w::SIGNATURE_HEADER
    assert w.verify_signature(secret, header, body, now: ts + 10)
    assert w.verify_signature(secret, "t=#{ts},v1=#{sign.call(ts, body, 'other')},v1=#{sign.call(ts, body)}", body, now: ts)
    refute w.verify_signature("whsec_wrong", header, body, now: ts)
    refute w.verify_signature(secret, header, "#{body} ", now: ts)
    refute w.verify_signature(secret, header, body, now: ts + 301)
    refute w.verify_signature(secret, header, body, now: ts - 301)
    assert w.verify_signature(secret, header, body, now: ts + 500, tolerance: 600)
    refute w.verify_signature(secret, "t=#{ts}", body, now: ts)
    refute w.verify_signature(secret, nil, body, now: ts)
  end

  def test_wait_honours_retry_after
    t = FakeTransport.new([
      [200, {}, { "id" => "s1", "status" => "processing" }],
      [429, { "Retry-After" => "3" }, { "error" => { "code" => "rate_limited", "message" => "Slow down" } }],
      [200, {}, { "id" => "s1", "status" => "completed" }]
    ])
    waits = []
    scan = client(t).wait_for_scan("s1", interval: 1.0, sleeper: ->(s) { waits << s })
    assert_equal "completed", scan["status"]
    assert_equal [1.0, 3.0], waits
  end

  def test_wait_times_out
    t = FakeTransport.new([[200, {}, { "id" => "s1", "status" => "processing" }]])
    assert_raises(PlagiarismCheckerPlus::ScanTimeoutError) do
      client(t).wait_for_scan("s1", timeout: 0.01, interval: 1.0, sleeper: ->(_) {})
    end
  end
end
