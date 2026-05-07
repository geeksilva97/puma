# frozen_string_literal: true
# Realistic-shape Rack app for the Puma vs. Puma-Ractor benchmark.
#
# Mimics what a typical Rails JSON action does, *without* needing Rails.
# Per request, we do roughly ~0.5–1 ms of pure-Ruby CPU work so the GVL
# actually matters in the comparison:
#
#   1. Build a moderate hash (~30+ keys, mix of strings/ints/nested arrays).
#   2. JSON.generate the hash.
#   3. SHA256 the JSON (request-id style).
#   4. Small string transform on a paragraph of lorem ipsum (downcase + gsub).
#   5. Return the JSON with a Content-Type: application/json header.
#
# Ractor-safety:
#   - Only stdlib (json, digest, securerandom).
#   - The proc closes over the module-level frozen LOREM constant; frozen
#     strings are shareable. No outer mutable state captured.
#   - JSON / Digest / SecureRandom are required at the top, which inside a
#     Ractor still works because they're stdlib (Digest in particular is
#     loaded once and its constants are frozen).

require 'json'
require 'digest'
require 'securerandom'

LOREM = (
  "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do " \
  "eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim " \
  "ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut " \
  "aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit " \
  "in voluptate velit esse cillum dolore eu fugiat nulla pariatur."
).freeze

run ->(env) {
  # Build a "user with orders" style payload.
  user_id = SecureRandom.hex(8)
  orders = Array.new(40) do |i|
    {
      'id'         => "ord_#{i}_#{SecureRandom.hex(4)}",
      'sku'        => "SKU-#{1000 + i}",
      'qty'        => (i % 5) + 1,
      'price_cents'=> 1999 + (i * 137),
      'currency'   => 'USD',
      'tags'       => ['promo', 'fresh', "lane-#{i % 3}"],
      'created_at' => "2026-05-0#{(i % 9) + 1}T12:0#{i % 9}:00Z"
    }
  end

  payload = {
    'user' => {
      'id'         => user_id,
      'email'      => "user_#{user_id}@example.com",
      'name'       => "User #{user_id[0, 6]}",
      'role'       => 'customer',
      'verified'   => true,
      'created_at' => '2024-01-15T08:30:00Z',
      'updated_at' => '2026-04-20T14:11:42Z',
      'address' => {
        'line1'   => '123 Ractor Lane',
        'line2'   => 'Apt 4',
        'city'    => 'San Francisco',
        'region'  => 'CA',
        'country' => 'US',
        'zip'     => '94107'
      },
      'preferences' => {
        'newsletter' => true,
        'sms'        => false,
        'theme'      => 'dark',
        'locale'     => 'en-US',
        'timezone'   => 'America/Los_Angeles'
      },
      'stats' => {
        'orders_count'  => orders.size,
        'lifetime_cents'=> orders.sum { |o| o['price_cents'] * o['qty'] },
        'last_login_at' => '2026-05-04T22:18:09Z',
        'login_count'   => 142,
        'favourites'    => ['running', 'hiking', 'cycling']
      }
    },
    'orders'    => orders,
    'meta' => {
      'request_path' => env['PATH_INFO'] || '/',
      'method'       => env['REQUEST_METHOD'] || 'GET',
      'server'       => 'puma-experiment',
      'version'      => '1.0.0',
      'timestamp'    => Time.now.to_i,
      'trace_id'     => SecureRandom.hex(8)
    }
  }

  json = JSON.generate(payload)

  # SHA256 of the JSON (request id / etag style). Re-hash a few times to
  # simulate signing + downstream tracing IDs that real apps compute.
  digest = Digest::SHA256.hexdigest(json)
  6.times { digest = Digest::SHA256.hexdigest(digest) }

  # String transform — downcase + a couple gsubs on a paragraph of
  # lorem ipsum. Repeat enough times that we're firmly in pure-Ruby
  # territory. This is the per-request CPU cost dial.
  transformed = LOREM
  120.times do
    transformed = transformed.downcase.gsub('lorem', 'ractor').gsub(/\s+/, ' ')
  end
  _ = transformed.length  # used so the optimiser doesn't elide the work

  headers = {
    'content-type'   => 'application/json',
    'content-length' => json.bytesize.to_s,
    'x-request-id'   => digest[0, 32]
  }

  [200, headers, [json]]
}
