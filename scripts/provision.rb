#!/usr/bin/env ruby
# frozen_string_literal: true

# Provisions Cloudflare DNS for merged denizens claims.
#
# Runs on push to main. Diffs the merge, then for each changed domains/*.json:
#   - added/modified -> reconcile DNS records for <name>.devis.im idempotently
#     (look up by name, delete stale, create missing, patch proxied). Honors `proxied`.
#   - deleted        -> tear down all DNS records for the name + any matching
#     name@devis.im email routing rule.
#   - email.enabled on an added file -> post a "submit your forwarding address"
#     comment on the PR linking to EMAIL_FORM_URL (skipped if the var is unset).
#
# URL records are deferred (logged + skipped) — Cloudflare has no native URL DNS
# type; redirect support lands in a follow-up.
#
# Failure isolation: one bad file is logged and recorded but does not stop the
# batch. Exits non-zero if any file errored. Never logs the token or any email.
#
# Env:
#   CF_API_TOKEN, CF_ZONE_ID         Cloudflare credentials (GitHub Secrets)
#   ZONE_NAME                        apex zone, default "devis.im"
#   BEFORE_SHA, AFTER_SHA            push range to diff
#   REPO, GH_TOKEN, EMAIL_FORM_URL   for finding the PR + posting the email comment

require "json"
require "net/http"
require "uri"

class Provisioner
  CF_API = "https://api.cloudflare.com/client/v4"
  GH_API = "https://api.github.com"
  ZERO_SHA = "0000000000000000000000000000000000000000"
  PROXIABLE = %w[CNAME A AAAA].freeze

  def initialize(env: ENV)
    @env = env
    @zone_name = env["ZONE_NAME"] || "devis.im"
    @before = env["BEFORE_SHA"].to_s
    @after = env["AFTER_SHA"].to_s.empty? ? "HEAD" : env["AFTER_SHA"]
  end

  # CLI entrypoint: validates credentials, then provisions.
  def run
    @token = require_env("CF_API_TOKEN")
    @zone_id = require_env("CF_ZONE_ID")
    provision
  end

  # --- diff ----------------------------------------------------------------

  def changed_domain_files
    lines =
      if @before.empty? || @before == ZERO_SHA
        # New branch / unknown base: treat every domain file as added.
        `git ls-tree -r --name-only #{@after} domains/`.lines.map { |l| "A\t#{l.strip}" }
      else
        # --no-renames: each domains/<name>.json is its own claim. A delete+add of
        # identical content must stay two events (D + A), never collapse to a rename.
        `git diff --no-renames --name-status #{@before} #{@after} -- domains/`.lines
      end

    lines.filter_map do |line|
      line = line.strip
      next if line.empty?

      parts = line.split("\t")
      code = parts[0][0]
      path = parts.last
      next unless path.end_with?(".json")
      next if path == "domains/example.json"

      status = case code
               when "A", "C" then "added"
               when "M", "R" then "modified"
               when "D" then "deleted"
               end
      next unless status

      { "path" => path, "status" => status, "name" => path.sub(%r{\Adomains/}, "").sub(/\.json\z/, "") }
    end
  end

  # --- desired-state mapping ----------------------------------------------

  def desired_records(name, record, proxied)
    fqdn = "#{name}.#{@zone_name}"
    recs = []
    add = lambda do |type, content, can_proxy|
      recs << { "type" => type, "name" => fqdn, "content" => content, "proxied" => (can_proxy ? !!proxied : false), "ttl" => 1 }
    end

    add.call("CNAME", record["CNAME"], true) if record.key?("CNAME")
    record["A"].each { |ip| add.call("A", ip, true) } if record["A"].is_a?(Array)
    record["AAAA"].each { |ip| add.call("AAAA", ip, true) } if record["AAAA"].is_a?(Array)
    if record.key?("TXT")
      vals = record["TXT"].is_a?(Array) ? record["TXT"] : [record["TXT"]]
      vals.each { |v| add.call("TXT", v, false) }
    end
    log "  · URL record for #{fqdn} deferred (redirect support not yet implemented) — skipped" if record.key?("URL")
    recs
  end

  def same_record?(existing, desired)
    existing["type"] == desired["type"] && existing["content"] == desired["content"]
  end

  # --- operations ----------------------------------------------------------

  def list_by_name(fqdn)
    cf(:get, "/zones/#{@zone_id}/dns_records?name=#{URI.encode_www_form_component(fqdn)}&per_page=100")
  end

  def reconcile(name, data)
    fqdn = "#{name}.#{@zone_name}"
    desired = desired_records(name, data["record"] || {}, data["proxied"])
    existing = list_by_name(fqdn)

    # Delete stale first (also resolves CNAME-vs-other-type conflicts before create).
    existing.reject { |e| desired.any? { |d| same_record?(e, d) } }.each do |e|
      cf(:delete, "/zones/#{@zone_id}/dns_records/#{e['id']}")
      log "  − deleted stale #{e['type']} #{fqdn}"
    end

    desired.each do |d|
      match = existing.find { |e| same_record?(e, d) }
      if match.nil?
        cf(:post, "/zones/#{@zone_id}/dns_records", d)
        log "  + created #{d['type']} #{fqdn}#{PROXIABLE.include?(d['type']) ? " (proxied=#{d['proxied']})" : ''}"
      elsif PROXIABLE.include?(d["type"]) && match["proxied"] != d["proxied"]
        cf(:patch, "/zones/#{@zone_id}/dns_records/#{match['id']}", { "proxied" => d["proxied"] })
        log "  ~ updated #{d['type']} #{fqdn} (proxied -> #{d['proxied']})"
      else
        log "  = unchanged #{d['type']} #{fqdn}"
      end
    end
  end

  def teardown(name)
    fqdn = "#{name}.#{@zone_name}"
    list_by_name(fqdn).each do |e|
      cf(:delete, "/zones/#{@zone_id}/dns_records/#{e['id']}")
      log "  − deleted #{e['type']} #{fqdn}"
    end

    alias_addr = "#{name}@#{@zone_name}"
    begin
      rules = cf(:get, "/zones/#{@zone_id}/email/routing/rules?per_page=100")
      rule = (rules || []).find { |r| (r["matchers"] || []).any? { |m| m["field"] == "to" && m["value"] == alias_addr } }
      if rule
        cf(:delete, "/zones/#{@zone_id}/email/routing/rules/#{rule['tag'] || rule['id']}")
        log "  − deleted email routing rule for #{alias_addr}"
      end
    rescue => e
      log "  ! could not check/remove routing rule for #{alias_addr}: #{e.message}"
    end
  end

  # --- email-setup comment -------------------------------------------------

  def comment_email_setup(names)
    return if names.empty?

    form_url = @env["EMAIL_FORM_URL"].to_s
    if form_url.empty?
      log "EMAIL_FORM_URL not set — skipping email-setup comment."
      return
    end
    repo = @env["REPO"].to_s
    if repo.empty? || @env["GH_TOKEN"].to_s.empty?
      log "REPO/GH_TOKEN not set — skipping email-setup comment."
      return
    end

    _, prs = gh(:get, "/repos/#{repo}/commits/#{@after}/pulls")
    unless prs.is_a?(Array) && !prs.empty?
      log "No PR associated with #{@after} — cannot post email-setup comment."
      return
    end
    pr = prs.first["number"]

    names.each do |name|
      link = "#{form_url}?name=#{URI.encode_www_form_component(name)}"
      body = "<!-- denizens-email-setup -->\n" \
             "### 📨 Set up `#{name}@devis.im` forwarding\n\n" \
             "Your subdomain is live. To finish email forwarding, submit your forwarding " \
             "address privately here: #{link}\n\n" \
             "You'll then get a verification email from Cloudflare — click the link in it " \
             "to activate forwarding. **Never** post your forwarding address in this repo."
      gh(:post, "/repos/#{repo}/issues/#{pr}/comments", { body: body })
      log "  ✉ posted email-setup comment for #{name}"
    end
  end

  # --- batch ---------------------------------------------------------------

  def provision
    files = changed_domain_files
    if files.empty?
      log "No domain changes to provision."
      return 0
    end

    email_comments = []
    failures = []

    files.each do |f|
      log "\n▶ #{f['status']}: #{f['name']}"
      begin
        if f["status"] == "deleted"
          teardown(f["name"])
          next
        end
        data = JSON.parse(File.read(f["path"]))
        reconcile(f["name"], data)
        email_comments << f["name"] if f["status"] == "added" && data.dig("email", "enabled") == true
      rescue => e
        warn "  ✗ #{f['name']}: #{e.message}"
        failures << f["name"]
      end
    end

    comment_email_setup(email_comments)

    log "\nDone. #{files.length - failures.length}/#{files.length} provisioned" \
        "#{failures.empty? ? '' : ", failed: #{failures.join(', ')}"}"
    failures.empty? ? 0 : 1
  end

  # --- HTTP ----------------------------------------------------------------

  def cf(method, path, body = nil)
    json = http_json(URI("#{CF_API}#{path}"), method, body) { |req| req["Authorization"] = "Bearer #{@token}" }
    res_code, parsed = json
    unless res_code.between?(200, 299) && parsed && parsed["success"] != false
      errs = ((parsed && parsed["errors"]) || []).map { |e| "#{e['code']}: #{e['message']}" }.join("; ")
      raise "Cloudflare #{method.upcase} #{path} -> #{res_code} #{errs.empty? ? 'unknown error' : errs}"
    end
    parsed["result"]
  end

  def gh(method, path, body = nil)
    http_json(URI("#{GH_API}#{path}"), method, body) do |req|
      req["Authorization"] = "Bearer #{@env['GH_TOKEN']}"
      req["Accept"] = "application/vnd.github+json"
      req["X-GitHub-Api-Version"] = "2022-11-28"
    end
  end

  private

  def http_json(uri, method, body)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    klass = { get: Net::HTTP::Get, post: Net::HTTP::Post, patch: Net::HTTP::Patch, delete: Net::HTTP::Delete }.fetch(method)
    req = klass.new(uri)
    req["Content-Type"] = "application/json"
    yield req if block_given?
    req.body = body.to_json if body
    res = http.request(req)
    [res.code.to_i, (JSON.parse(res.body) rescue nil)]
  end

  def require_env(key)
    v = @env[key]
    raise "Missing required env: #{key}" if v.nil? || v.empty?

    v
  end

  def log(msg)
    puts msg
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    exit Provisioner.new.run
  rescue => e
    warn "Fatal: #{e.message}"
    exit 1
  end
end
