# frozen_string_literal: true
#
# Puma-Ractor PoC server.
#
# Architecture: single process, N worker Ractors share one bound TCPServer.
# Each Ractor independently calls server.accept (kernel handles the race),
# parses just-enough HTTP/1.1, writes a fixed echo response, closes the
# connection (no keep-alive — keeps the PoC simple).
#
# Inspired by Cowboy's "one acceptor per listener" model and Puma's accept
# loop, but without any thread pool — Ractors give us true parallelism, no
# GVL contention between them.

Warning[:experimental] = false

require 'socket'
require 'etc'

PORT      = Integer(ENV.fetch('PORT', 9292))
RACTORS   = Integer(ENV.fetch('RACTORS', Etc.nprocessors))
HOST      = ENV.fetch('HOST', '0.0.0.0')

server = TCPServer.new(HOST, PORT)
# Reuse port behavior is on by default for TCPServer in modern Ruby; we just
# make sure we can accept rapidly.
server.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, true)

# IO objects can cross Ractor boundaries via block args (they're "movable"
# enough — every Ractor reads the same fd). We DO NOT make_shareable here:
# that freezes the TCPServer, and accept mutates internal state, so frozen
# servers raise FrozenError on accept. Passing as a block arg is sufficient.

puts "Puma-Ractor PoC listening on :#{PORT} with #{RACTORS} ractors, pid=#{Process.pid}"
$stdout.flush

workers = RACTORS.times.map do |i|
  Ractor.new(server, i) do |srv, idx|
    # Fixed-length body (left-padded ractor index) so ab doesn't flag every
    # response from a different ractor as a "Length: failed" mismatch. The
    # actual ractor that handled the request is still observable via the
    # padded number — useful when curling manually.
    body = format("hello from ractor %02d pid=%010d\n", idx, Process.pid).freeze
    response = (
      "HTTP/1.1 200 OK\r\n" \
      "Content-Type: text/plain\r\n" \
      "Content-Length: #{body.bytesize}\r\n" \
      "Connection: close\r\n" \
      "\r\n" \
      "#{body}"
    ).freeze

    loop do
      begin
        client = srv.accept
      rescue IOError, Errno::EBADF
        break # server closed
      end

      begin
        # Read until \r\n\r\n or EOF. ab sends small requests; cap at 8 KiB.
        buf = +''
        while (chunk = client.readpartial(4096))
          buf << chunk
          break if buf.include?("\r\n\r\n") || buf.bytesize > 8192
        end
      rescue EOFError, Errno::ECONNRESET, IOError
        # client gone; just close
      end

      begin
        client.write(response)
      rescue Errno::EPIPE, Errno::ECONNRESET, IOError
        # client gone before we wrote
      ensure
        begin
          client.close
        rescue StandardError
          # ignore
        end
      end
    end
  end
end

shutting_down = false
trap(:INT) do
  next if shutting_down
  shutting_down = true
  # Closing the shared socket makes every Ractor's accept raise -> they exit.
  begin
    server.close
  rescue StandardError
    # ignore
  end
  warn "\nshutting down..."
end

# Park main thread until SIGINT closes the socket.
loop do
  break if server.closed?
  sleep 0.5
end

# Best-effort drain. Ractors that are mid-request will finish; ones blocked in
# accept already raised. We don't strictly need to take them — process exits.
workers.each do |r|
  begin
    r.value # Ruby 4.0 renamed Ractor#take -> #value
  rescue Ractor::RemoteError, Ractor::ClosedError
    # expected on shutdown
  end
end

puts "bye"
