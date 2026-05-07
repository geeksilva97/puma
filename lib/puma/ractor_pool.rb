# frozen_string_literal: true
#
# Puma::RactorPool — drop-in (mostly) replacement for Puma::ThreadPool that
# uses Ractors instead of OS threads. Built for the Ruby Conf 2026 experiment.
#
# DESIGN NOTES (read this before believing the diff is small):
#
# Puma's ThreadPool sits inside a single Server process and pulls Puma::Client
# objects off a queue. Each Client wraps an IO + a Puma::IOBuffer + a parsed
# env hash. The ThreadPool's worker block (set by Server) is
# `process_client(processor, client)`, which uses the C HttpParser, the
# Reactor for read-buffering, the Rack app, and Puma's response writer.
#
# Ractors break this model in three places:
#
#   1. Puma::Client itself can't cross a Ractor boundary
#      (Puma::IOBuffer is not Ractor-copyable; the actual error is
#      `Ractor::Error: can not copy Puma::IOBuffer object`).
#
#   2. The Rack app is a Proc with a non-shareable self; you can't `Ractor.send`
#      a Proc, and `Ractor.make_shareable` raises Ractor::IsolationError.
#
#   3. The block ThreadPool takes (`process_client`) closes over `self`
#      (the Server) and many ivars. None of that is shareable.
#
# Workaround used here (Option B in the experiment plan):
#
#   * The Ractor receives only the raw TCPSocket (which IS Ractor-sendable).
#   * Each Ractor independently loads the Rack app from a rackup file path
#     (the path is a frozen String — shareable).
#   * Each Ractor runs a *minimal* HTTP/1.1 request handler using Puma's
#     C HttpParser (declared Ractor-safe via rb_ext_ractor_safe(true)) and
#     writes a Rack-compliant response itself. No Reactor, no keep-alive,
#     no hijack, no SSL, no early hints. PoC scope.
#
# That means the per-request code path inside the Ractor is *not* the same
# code path as in the ThreadPool worker. We reuse Puma::HttpParser; we do
# NOT reuse Puma::Server#process_client / Puma::Response#prepare_response.
# This is documented honestly in RESULTS.md.

require 'socket'
require 'etc'

require_relative 'detect'

module Puma
  class RactorPool
    class ForceShutdown < RuntimeError; end

    attr_reader :spawned, :waiting, :trim_requested

    # Match the ThreadPool constructor's shape so Server can swap us in with
    # a minimal change. The block is intentionally ignored — see DESIGN NOTES.
    def initialize(name, options = {}, server: nil, &_block)
      @name    = name
      @server  = server
      @options = options

      @min = Integer(options[:min_threads] || 0)
      @max = Integer(options[:max_threads] || Etc.nprocessors)

      # The Server may pass us a rackup path or a pre-resolved app. Procs
      # can't cross Ractor boundaries, so each Ractor reloads the rackup file
      # for itself.
      @rackup_path = options[:ractor_rackup_path]

      @ractors = []
      @rr      = 0
      @spawned = 0
      @waiting = 0
      @trim_requested = 0
      @shutdown = false

      spawn_ractors(@max)
    end

    # Public stats hash, same keys ThreadPool uses where applicable.
    def stats
      { backlog: 0,
        running: @spawned,
        pool_capacity: @max,
        busy_threads: 0,
        io_threads: 0,
        backlog_max: 0 }
    end

    def reset_max; end
    def backlog; 0; end
    def backlog_max; 0; end
    def pool_capacity; @max; end
    def busy_threads; 0; end

    # Hand a Puma::Client off to a Ractor. Because Client itself can't cross,
    # we extract the raw IO + peerip and send those. The Ractor reconstructs
    # what it needs.
    def <<(client)
      raise "shutting down" if @shutdown
      io = client.respond_to?(:io) ? client.io : client
      # Round-robin dispatch. With N=nprocessors Ractors and a busy listener,
      # the kernel + the Ractor mailbox give us enough backpressure that we
      # don't need a userspace queue.
      r = @ractors[@rr]
      @rr = (@rr + 1) % @ractors.length
      r.send(io, move: true)
      self
    rescue Ractor::ClosedError
      # Ractor died; just drop the connection. PoC.
      io.close rescue nil
    end

    def wait_until_not_full; end
    def wait_while_out_of_band_running; end
    def with_force_shutdown(&blk); blk.call; end
    def with_mutex(&blk); blk.call; end
    def auto_trim!(*); end
    def auto_reap!(*); end
    def trim(*); end
    def reap; end

    # Best-effort drain. Each Ractor exits when it sees :__shutdown__.
    def shutdown(_timeout = nil)
      @shutdown = true
      @ractors.each do |r|
        begin
          r.send(:__shutdown__)
        rescue Ractor::ClosedError
          # already gone
        end
      end
      @ractors.each do |r|
        begin
          r.value
        rescue StandardError, Ractor::RemoteError
          # workers may raise on shutdown; we don't care for PoC
        end
      end
      @spawned = 0
      @ractors = []
    end

    private

    def spawn_ractors(n)
      rackup_path = @rackup_path
      # Read the rackup file in the main thread; the *source string* is
      # shareable (frozen). Each Ractor eval's it in its own context.
      # We can't use Rack::Builder.parse_file inside a Ractor — Rack's own
      # constants (Rack::BUILDER_TOPLEVEL_BINDING) are non-shareable, which
      # raises `Ractor::IsolationError: can not access non-shareable objects
      # in constant Rack::BUILDER_TOPLEVEL_BINDING by non-main ractor`.
      rackup_src = (rackup_path && File.exist?(rackup_path)) ? File.read(rackup_path).freeze : nil

      n.times do |i|
        r = Ractor.new(rackup_src, i, name: "puma-ractor-#{i}") do |src, idx|
          # ---- Inside the Ractor ----
          require 'puma'              # for Puma::HttpParser (C ext, ractor-safe)
          require 'stringio'

          # Hand-rolled rackup loader. Supports `run <app>` and basic
          # `use Middleware` (which we ignore — PoC). This is enough for
          # `run ->(env) { ... }` style apps.
          builder_app = nil
          builder_obj = Object.new
          builder_obj.define_singleton_method(:run) { |a| builder_app = a }
          builder_obj.define_singleton_method(:use)        { |*_a, **_kw, &_b| }
          builder_obj.define_singleton_method(:map)        { |*_a, **_kw, &_b| }
          builder_obj.define_singleton_method(:warmup)     { |*_a, **_kw, &_b| }

          if src
            builder_obj.instance_eval(src)
          end

          app = builder_app || lambda { |_env|
            body = "ractor-pool no-app fallback\n"
            [200, { 'content-type' => 'text/plain', 'content-length' => body.bytesize.to_s }, [body]]
          }

          parser = Puma::HttpParser.new
          buf    = ''.dup

          loop do
            io = Ractor.receive
            break if io == :__shutdown__

            begin
              # --- Read until parser is finished. HTTP/1.x request line + headers. ---
              parser.reset
              buf.clear
              loop do
                begin
                  chunk = io.read_nonblock(16_384)
                  break if chunk.nil? || chunk.empty?
                  buf << chunk
                rescue IO::WaitReadable
                  IO.select([io], nil, nil, 5) or raise "read timeout"
                  retry
                rescue EOFError
                  break
                end
                env = {}
                nread = parser.execute(env, buf, parser.nread)
                if parser.finished?
                  body_rest = buf.byteslice(nread, buf.bytesize - nread) || ''

                  input = body_rest.empty? ? StringIO.new('') : StringIO.new(body_rest)
                  env['rack.input']        = input
                  env['rack.errors']       = $stderr
                  env['rack.url_scheme']   = 'http'
                  env['SCRIPT_NAME']       = ''
                  env['PATH_INFO']       ||= env['REQUEST_PATH'] || '/'
                  env['QUERY_STRING']    ||= ''
                  env['SERVER_NAME']     ||= '127.0.0.1'
                  env['SERVER_PORT']     ||= '9292'
                  env['SERVER_PROTOCOL'] ||= 'HTTP/1.1'
                  env['HTTP_VERSION']    ||= env['SERVER_PROTOCOL']

                  status, headers, app_body = app.call(env)

                  out = +"HTTP/1.1 #{status} \r\n"
                  content_length = nil
                  headers.each do |k, v|
                    next if v.nil?
                    vs = v.to_s
                    if vs.include?("\n")
                      vs.split("\n").each { |line| out << "#{k}: #{line}\r\n" }
                    else
                      out << "#{k}: #{vs}\r\n"
                    end
                    content_length = vs if k.to_s.downcase == 'content-length'
                  end

                  if content_length
                    out << "\r\n"
                    io.write(out)
                    app_body.each { |c| io.write(c) }
                  else
                    chunks = []
                    app_body.each { |c| chunks << c }
                    joined = chunks.join
                    out << "Content-Length: #{joined.bytesize}\r\n\r\n#{joined}"
                    io.write(out)
                  end
                  app_body.close if app_body.respond_to?(:close)
                  break
                end
                if buf.bytesize > 80 * 1024
                  io.write "HTTP/1.1 413 Payload Too Large\r\nContent-Length: 0\r\n\r\n"
                  break
                end
              end
            rescue StandardError => e
              # Last-ditch error path.
              begin
                io.write "HTTP/1.1 500 Internal Server Error\r\nContent-Length: #{e.message.bytesize}\r\n\r\n#{e.message}"
              rescue StandardError
                # client gone
              end
            ensure
              io.close rescue nil
            end
          end
        end
        @ractors << r
        @spawned += 1
      end
    end

  end
end
