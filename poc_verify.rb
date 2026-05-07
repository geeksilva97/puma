#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Response-shape verifier for poc_realistic_app.ru.
#
# Usage: ruby poc_verify.rb [URL]
#   default URL: http://127.0.0.1:9292/
#
# Sends N=3 GETs and asserts, on every response:
#   - HTTP 200
#   - Content-Type: application/json
#   - Content-Length matches body.bytesize (when header present)
#   - Body parses as JSON
#   - Body matches the realistic app's schema (user, orders[40], meta)
#
# Cross-request:
#   - user.id varies across responses (guards against a Ractor / fork /
#     middleware caching the first response and serving it to everyone).
#
# Exits 0 on success, non-zero on any failure. Used by
# poc_bench_threeway.sh to fail fast before benching a broken server.

require 'net/http'
require 'uri'
require 'json'

url = ARGV[0] || 'http://127.0.0.1:9292/'
n   = 3
uri = URI(url)

ids = []
n.times do |i|
  res = Net::HTTP.get_response(uri)

  unless res.code == '200'
    abort "[FAIL] req #{i + 1}: expected 200, got #{res.code}"
  end

  ct = res['content-type'] || ''
  unless ct.include?('application/json')
    abort "[FAIL] req #{i + 1}: expected JSON, got Content-Type=#{ct.inspect}"
  end

  cl = res['content-length']
  if cl && cl.to_i != res.body.bytesize
    abort "[FAIL] req #{i + 1}: Content-Length=#{cl} but body=#{res.body.bytesize}"
  end

  body = begin
    JSON.parse(res.body)
  rescue JSON::ParserError => e
    abort "[FAIL] req #{i + 1}: body is not valid JSON: #{e.message}"
  end

  user = body['user'] or abort "[FAIL] req #{i + 1}: missing 'user'"
  unless user['id'].is_a?(String) && user['id'].match?(/\A[0-9a-f]{16}\z/)
    abort "[FAIL] req #{i + 1}: user.id malformed: #{user['id'].inspect}"
  end

  orders = body['orders'] or abort "[FAIL] req #{i + 1}: missing 'orders'"
  unless orders.is_a?(Array) && orders.length == 40
    got = orders.is_a?(Array) ? orders.length : orders.class
    abort "[FAIL] req #{i + 1}: orders must be 40-element array, got #{got}"
  end

  o0 = orders.first
  %w[id sku qty price_cents currency tags created_at].each do |k|
    o0.key?(k) or abort "[FAIL] req #{i + 1}: orders[0] missing key #{k.inspect}"
  end

  meta = body['meta'] or abort "[FAIL] req #{i + 1}: missing 'meta'"
  unless meta['request_path'] == '/'
    abort "[FAIL] req #{i + 1}: meta.request_path=#{meta['request_path'].inspect}, expected '/'"
  end

  ids << user['id']
end

if ids.uniq.length != ids.length
  abort "[FAIL] user.id repeated across #{n} requests: #{ids.inspect} — possible cached/stuck response"
end

puts "[OK] #{n} reqs, schema valid, ids unique: #{ids.join(', ')}"
