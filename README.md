# Plagiarism Checker Plus for Ruby

Official client for the [Plagiarism Checker Plus API](https://plagiarismcheckerplus.com/integrations/api). Ruby 2.7+, standard library only.

Get a free API key in the [developer portal](https://app.plagiarismcheckerplus.com/developers). Test keys are free and unlimited, and every free account gets 2,000 live API words once, with no card. See [API pricing](https://plagiarismcheckerplus.com/api-pricing).

## Install

```sh
gem install plagiarism_checker_plus
```

## Quick start

Get a free API key at https://app.plagiarismcheckerplus.com/developers (test keys are free and unlimited).

```ruby
require "plagiarism_checker_plus"

client = PlagiarismCheckerPlus::Client.new(api_key: ENV.fetch("PCP_API_KEY"))

begin
  created = client.create_scan(essay_text, %w[plagiarism ai_detect], name: "essay-draft-1") # 50+ words for AI detection
  scan = client.wait_for_scan(created["id"])

  puts "Test key: these are sample results." if scan["sandbox"]
  plagiarism = scan.dig("results", "plagiarism") || {}
  puts "Matched: #{plagiarism['score']}%"
  (plagiarism["sources"] || []).each { |source| puts source["url"] }

  # A likelihood, not proof that the text was written by AI.
  puts "AI likelihood: #{scan.dig('results', 'aiDetection', 'score')}%"
rescue PlagiarismCheckerPlus::Error => e
  details = e.details # the response's error object, with any detail fields
  case e.code
  when PlagiarismCheckerPlus::ErrorCodes::TEXT_TOO_SHORT
    puts "Send at least 30 words for plagiarism, 50 for AI detection."
  when PlagiarismCheckerPlus::ErrorCodes::TRIAL_EXHAUSTED
    puts "Free API trial used up. Buy words or choose an API plan: #{details['billingUrl']}"
  when PlagiarismCheckerPlus::ErrorCodes::INSUFFICIENT_WORDS
    puts "Need #{details['wordsNeeded']} words, #{details['wordsAvailable']} available. Top up: #{details['billingUrl']}"
  when PlagiarismCheckerPlus::ErrorCodes::KEY_CAP_REACHED
    puts "This key reached its monthly cap of #{details['monthlyWordCap']} words."
  else
    raise
  end
end
```

## Test keys, free trial and pricing

- **Test keys** (`pcp_test_...`) are free and unlimited on every plan, including free. They never run a check: `create_scan` returns as usual and `get_scan` returns `completed` with fixed sample results in the same shape as a real scan, marked `"sandbox": true`. Use them to build and test your integration.
- **Free API trial**: each free account gets 2,000 API words once for live keys (`pcp_...`), with no card. When the trial cannot cover a request, the API returns `402 trial_exhausted` and nothing is charged.
- **Paid app plans** (Student, Personal, Team) use their plan words for API calls.
- **API plans**: Starter $29/month (300,000 words), Growth $99/month (1,500,000 words), Scale $399/month (7,500,000 words).
- **Pay as you go**: words from $6 (50,000 words, $0.12 per 1,000 words). Purchased words never expire.

A scan costs its word count once per tool: 800 words checked for plagiarism and AI costs 1,600 words. Prices: [API pricing](https://plagiarismcheckerplus.com/api-pricing). Keys, usage, billing and webhooks: [developer portal](https://app.plagiarismcheckerplus.com/developers). `get_account` returns what is left in `trial` and `balances`, plus `autoTopup` and this key's `key.mode` and `key.monthlyWordCap`.

The rate limit is 60 requests a minute per key on paid app plans and for accounts with an API plan or purchased API words, and 10 a minute otherwise (free trial, test keys on the free plan).

## Webhooks

Instead of polling, register an https endpoint in the [developer portal](https://app.plagiarismcheckerplus.com/developers) to receive `scan.completed` and `scan.failed` for checks made with live keys. Each delivery carries

```
PCP-Signature: t=<unix seconds>,v1=<hex HMAC-SHA256(secret, "<t>.<raw body>")>
```

`PlagiarismCheckerPlus::Webhook.verify_signature(secret, header, raw_body, tolerance: 300)` checks it with the endpoint's signing secret (`whsec_...`). Pass the raw request body, before JSON parsing. It compares in constant time and rejects timestamps more than 300 seconds from now (the tolerance is configurable).

```ruby
require "json"
require "sinatra"
require "plagiarism_checker_plus"

post "/webhooks/pcp" do
  raw = request.body.read # raw body, before JSON parsing
  header = request.env["HTTP_PCP_SIGNATURE"]
  halt 400, "Invalid signature" unless PlagiarismCheckerPlus::Webhook.verify_signature(ENV.fetch("PCP_WEBHOOK_SECRET"), header, raw)

  event = JSON.parse(raw)
  case event["type"]
  when "scan.completed" then puts "Scan done: #{event.dig('data', 'scan', 'id')}"
  when "scan.failed" then puts "Scan failed: #{event.dig('data', 'scan', 'id')}"
  end
  200
end
```

An event can be delivered more than once (retries). Use its `id` to ignore repeats.

## Methods

| Method | API call |
|---|---|
| `create_scan(text, tools, name: nil)` | `POST /scans` |
| `get_scan(id, include_text: false)` | `GET /scans/{id}` |
| `list_scans(page: nil, limit: nil)` | `GET /scans` |
| `get_account` | `GET /account` |
| `wait_for_scan(id, timeout: 300, interval: 2, max_interval: 10)` | Polls until `completed` or `failed` |
| `Webhook.verify_signature(secret, header, body, tolerance: 300, now: nil)` | Checks a webhook's `PCP-Signature` (no API call) |

`wait_for_scan` grows the delay by 1.5x up to `max_interval`, waits for `Retry-After` on `429`, and raises `ScanTimeoutError` when `timeout` passes.

Failed calls raise `PlagiarismCheckerPlus::Error` with `status`, `code` (such as `trial_exhausted`, `insufficient_words`, `text_too_short`), `retry_after`, `body` and `details` (the response's error object).

Run the tests with `ruby -Ilib test/test_client.rb`.

## Error codes

Failed calls raise `PlagiarismCheckerPlus::Error`. It carries the HTTP status and the API error code (constants in `PlagiarismCheckerPlus::ErrorCodes`):

| Code | Status | Meaning |
|---|---|---|
| `invalid_request`, `invalid_json` | 400 | The request body or parameters are not valid. |
| `text_too_short` | 400 | Plagiarism needs at least 30 words, AI detection at least 50. Nothing is charged. |
| `doc_too_long` | 400 | The text is longer than the account allows per check. |
| `unauthorized`, `invalid_api_key`, `key_revoked` | 401 | Missing, unknown or revoked API key. |
| `trial_exhausted` | 402 | The free API trial (2,000 words) cannot cover this request. Includes `wordsNeeded`, `trialRemaining`, `trialTotal` and `billingUrl`. Buy words or choose an API plan; test keys stay free. Nothing is charged. |
| `insufficient_words` | 402 | Not enough words across all sources. Includes `wordsNeeded`, `wordsAvailable`, `balances` and `billingUrl`. Nothing is charged. |
| `key_cap_reached` | 402 | This key's monthly word cap would be exceeded. Includes `wordsNeeded`, `monthlyWordCap` and `usedThisMonth`. Raise the cap in the developer portal. |
| `email_unverified` | 403 | Verify the account's email address first. |
| `forbidden` | 403 | The key cannot access this resource. |
| `not_found` | 404 | No such scan for this key. |
| `rate_limited` | 429 | Too many requests. The client exposes `Retry-After` as `retry_after`. |
| `internal_error` | 500 | Something went wrong on our side. |
| `workers_unavailable` | 503 | Checks are temporarily unavailable. Retry later. |
| `plan_required` | 403 | **Deprecated, no longer returned.** Free accounts now get a free API trial and free test keys. `ErrorCodes::PLAN_REQUIRED` is kept so existing code still works. |

`wait_for_scan` raises `PlagiarismCheckerPlus::ScanTimeoutError` when it runs out of time. A scan whose status is `failed` is returned, not raised, so check `status`.

## Notes

- **An AI score is a likelihood, not proof** that someone used AI. A similarity score does not decide on its own whether text is plagiarism. Review the result yourself, and do not use either score alone to accuse anyone.
- Test-key scans carry `"sandbox": true` and contain sample data, not a real check.
- Each tool you run is billed at the full word count.
- Plagiarism Checker API overview: https://plagiarismcheckerplus.com/integrations/api
- AI Detector API overview: https://plagiarismcheckerplus.com/ai-detector-api
- API pricing: https://plagiarismcheckerplus.com/api-pricing
- API reference (try requests in the browser): https://app.plagiarismcheckerplus.com/api-docs
- Developer portal (keys, usage, billing, webhooks): https://app.plagiarismcheckerplus.com/developers
- The OpenAPI spec this client follows is in [`spec/openapi.json`](spec/openapi.json).

## Other languages

| Language | Repository | Install |
|---|---|---|
| JavaScript / TypeScript | [plagiarism-checker-plus-js](https://github.com/pcp-tech/plagiarism-checker-plus-js) | `npm install plagiarism-checker-plus` |
| Python | [plagiarism-checker-plus-python](https://github.com/pcp-tech/plagiarism-checker-plus-python) | `pip install plagiarism-checker-plus` |
| PHP | [plagiarism-checker-plus-php](https://github.com/pcp-tech/plagiarism-checker-plus-php) | `composer require plagiarismcheckerplus/sdk` |
| **Ruby** (this repository) | [plagiarism-checker-plus-ruby](https://github.com/pcp-tech/plagiarism-checker-plus-ruby) | `gem install plagiarism_checker_plus` |
| Go | [plagiarism-checker-plus-go](https://github.com/pcp-tech/plagiarism-checker-plus-go) | `go get github.com/pcp-tech/plagiarism-checker-plus-go` |
| Java | [plagiarism-checker-plus-java](https://github.com/pcp-tech/plagiarism-checker-plus-java) | Maven `com.plagiarismcheckerplus:sdk` |
| C# / .NET | [plagiarism-checker-plus-dotnet](https://github.com/pcp-tech/plagiarism-checker-plus-dotnet) | `dotnet add package PlagiarismCheckerPlus` |

## License

MIT. Copyright (c) 2026 Plagiarism Checker Plus.
