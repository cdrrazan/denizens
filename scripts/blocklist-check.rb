#!/usr/bin/env ruby
# frozen_string_literal: true

# Checks whether devis.im is listed on major domain blocklists (DNSBLs).
#
# Runs on a schedule (see .github/workflows/blocklist.yml). For each DNSBL it
# queries `<domain>.<dnsbl>` for an A record:
#   - NXDOMAIN / no answer        -> not listed (the healthy case)
#   - 127.0.x.x answer (a hit)    -> listed
#   - error sentinel (e.g. Spamhaus 127.255.255.x, URIBL 127.0.0.1) -> the
#     resolver is blocked/rate-limited, NOT a listing. Reported as "unknown",
#     never as a hit, so we don't cry wolf from a CI runner's public resolver.
#
# Exit code: 1 only if a real listing is found (so the workflow fails loudly and
# can open an issue); 0 if clean or only inconclusive. Never logs secrets.
#
# Env:
#   ZONE_NAME            domain to check, default "devis.im"
#   REPO, GH_TOKEN       optional — open a tracking issue on a real listing

require "json"
require "net/http"
require "uri"
require "resolv"

class BlocklistCheck
  GH_API = "https://api.github.com"
  ISSUE_MARKER = "<!-- denizens-blocklist -->"
  DNS_TIMEOUT = 5

  # Domain-oriented blocklists. Each entry's `error` matcher flags answers that
  # mean "resolver blocked / not a real listing" rather than a hit.
  DNSBLS = [
    { name: "Spamhaus DBL", zone: "dbl.spamhaus.org", error: ->(ip) { ip.start_with?("127.255.255.") } },
    { name: "SURBL multi",  zone: "multi.surbl.org",  error: ->(_ip) { false } },
    { name: "URIBL multi",  zone: "multi.uribl.com",  error: ->(ip) { ip == "127.0.0.1" || ip == "127.0.0.255" } }
  ].freeze

  def initialize(env: ENV)
    @env = env
    @domain = (env["ZONE_NAME"] || "devis.im").strip.downcase
  end

  # CLI entrypoint. Returns process exit code.
  def run
    results = check
    report(results)

    listed = results.select { |r| r[:status] == :listed }
    open_issue(listed) unless listed.empty?
    listed.empty? ? 0 : 1
  end

  # Queries every DNSBL. Returns [{ name:, zone:, status:, addresses: }].
  # status is :listed, :clean, or :unknown.
  def check
    DNSBLS.map do |bl|
      query = "#{@domain}.#{bl[:zone]}"
      addresses = resolve(query)

      status =
        if addresses.empty?
          :clean
        elsif addresses.all? { |ip| bl[:error].call(ip) }
          :unknown
        else
          :listed
        end

      { name: bl[:name], zone: bl[:zone], status: status, addresses: addresses }
    end
  end

  # Resolves A records for a name. NXDOMAIN -> []. Overridable in specs.
  def resolve(name)
    resolver = Resolv::DNS.new
    resolver.timeouts = DNS_TIMEOUT
    resolver.getresources(name, Resolv::DNS::Resource::IN::A).map { |r| r.address.to_s }
  rescue Resolv::ResolvError, Resolv::ResolvTimeout
    []
  ensure
    resolver&.close
  end

  # --- reporting -----------------------------------------------------------

  def report(results)
    log "Blocklist check for #{@domain}:"
    results.each do |r|
      mark = { listed: "LISTED", clean: "ok", unknown: "unknown (resolver blocked?)" }.fetch(r[:status])
      detail = r[:addresses].empty? ? "" : " [#{r[:addresses].join(', ')}]"
      log "  #{r[:status] == :listed ? '✗' : '·'} #{r[:name]} (#{r[:zone]}): #{mark}#{detail}"
    end

    listed = results.select { |r| r[:status] == :listed }
    if listed.empty?
      log "\nNo listings found."
    else
      log "\n⚠ #{@domain} is LISTED on: #{listed.map { |r| r[:name] }.join(', ')}"
    end
  end

  # --- issue tracking ------------------------------------------------------

  def open_issue(listed)
    repo = @env["REPO"].to_s
    if repo.empty? || @env["GH_TOKEN"].to_s.empty?
      log "REPO/GH_TOKEN not set — skipping issue creation."
      return
    end

    _, existing = gh(:get, "/repos/#{repo}/issues?state=open&per_page=100")
    if existing.is_a?(Array) && existing.any? { |i| i["body"].to_s.include?(ISSUE_MARKER) }
      log "Open blocklist issue already exists — not duplicating."
      return
    end

    body = "#{ISSUE_MARKER}\n" \
           "**`#{@domain}` is listed on a domain blocklist.**\n\n" \
           "Listed on: #{listed.map { |r| "#{r[:name]} (`#{r[:zone]}`)" }.join(', ')}\n\n" \
           "Reputation hit — mail forwarding may bounce or land in spam. " \
           "Investigate recent claims for abuse, request delisting, and review the " \
           "abuse-triage flow (`docs/abuse-triage.md`)."
    gh(:post, "/repos/#{repo}/issues", { title: "🚨 #{@domain} listed on a blocklist", body: body })
    log "Opened tracking issue."
  end

  def gh(method, path, body = nil)
    uri = URI("#{GH_API}#{path}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    klass = { get: Net::HTTP::Get, post: Net::HTTP::Post }.fetch(method)
    req = klass.new(uri)
    req["Authorization"] = "Bearer #{@env['GH_TOKEN']}"
    req["Accept"] = "application/vnd.github+json"
    req["X-GitHub-Api-Version"] = "2022-11-28"
    req["Content-Type"] = "application/json"
    req.body = body.to_json if body
    res = http.request(req)
    [res.code.to_i, (JSON.parse(res.body) rescue nil)]
  end

  private

  def log(msg)
    puts msg
  end
end

if $PROGRAM_NAME == __FILE__
  exit BlocklistCheck.new.run
end
