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
#   REPO, AFTER_SHA, GH_TOKEN        for finding the PR + posting the email comment
#   EMAIL_FORM_URL                   private intake form URL (optional; comment skipped if blank)

require "json"
require "net/http"
require "uri"

CF_API = "https://api.cloudflare.com/client/v4"
GH_API = "https://api.github.com"
ZERO_SHA = "0000000000000000000000000000000000000000"
PROXIABLE = %w[CNAME A AAAA].freeze

def required(key)
  v = ENV[key]
  if v.nil? || v.empty?
    warn "Missing required env: #{key}"
    exit 1
  end
  v
end

TOKEN = required("CF_API_TOKEN")
ZONE_ID = required("CF_ZONE_ID")
ZONE_NAME = ENV["ZONE_NAME"] || "devis.im"
BEFORE_SHA = ENV["BEFORE_SHA"].to_s
AFTER_SHA = ENV["AFTER_SHA"].to_s.empty? ? "HEAD" : ENV["AFTER_SHA"]

# --- HTTP -------------------------------------------------------------------

def cf(method, path, body = nil)
  uri = URI("#{CF_API}#{path}")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  klass = { get: Net::HTTP::Get, post: Net::HTTP::Post, patch: Net::HTTP::Patch, delete: Net::HTTP::Delete }.fetch(method)
  req = klass.new(uri)
  req["Authorization"] = "Bearer #{TOKEN}"
  req["Content-Type"] = "application/json"
  req.body = body.to_json if body
  res = http.request(req)
  json = JSON.parse(res.body) rescue nil
  unless res.code.to_i.between?(200, 299) && json && json["success"] != false
    errs = (json && json["errors"] || []).map { |e| "#{e['code']}: #{e['message']}" }.join("; ")
    raise "Cloudflare #{method.upcase} #{path} -> #{res.code} #{errs.empty? ? 'unknown error' : errs}"
  end
  json["result"]
end

def gh(method, path, body = nil)
  uri = URI("#{GH_API}#{path}")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  klass = { get: Net::HTTP::Get, post: Net::HTTP::Post }.fetch(method)
  req = klass.new(uri)
  req["Authorization"] = "Bearer #{ENV['GH_TOKEN']}"
  req["Accept"] = "application/vnd.github+json"
  req["X-GitHub-Api-Version"] = "2022-11-28"
  req["Content-Type"] = "application/json"
  req.body = body.to_json if body
  res = http.request(req)
  [res.code.to_i, (JSON.parse(res.body) rescue nil)]
end

# --- diff -------------------------------------------------------------------

def changed_domain_files
  if BEFORE_SHA.empty? || BEFORE_SHA == ZERO_SHA
    # New branch / unknown base: treat every domain file as added.
    out = `git ls-tree -r --name-only #{AFTER_SHA} domains/`.lines.map { |l| "A\t#{l.strip}" }
  else
    # --no-renames: each domains/<name>.json is its own claim. A delete+add of
    # identical content must stay two events (D + A), never collapse to a rename.
    out = `git diff --no-renames --name-status #{BEFORE_SHA} #{AFTER_SHA} -- domains/`.lines
  end

  out.filter_map do |line|
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

# --- desired-state mapping --------------------------------------------------

def desired_records(name, record, proxied)
  fqdn = "#{name}.#{ZONE_NAME}"
  recs = []
  add = lambda do |type, content, can_proxy|
    recs << { "type" => type, "name" => fqdn, "content" => content, "proxied" => (can_proxy ? !!proxied : false), "ttl" => 1 }
  end

  add.call("CNAME", record["CNAME"], true) if record.key?("CNAME")
  Array(record["A"]).each { |ip| add.call("A", ip, true) } if record["A"].is_a?(Array)
  Array(record["AAAA"]).each { |ip| add.call("AAAA", ip, true) } if record["AAAA"].is_a?(Array)
  if record.key?("TXT")
    vals = record["TXT"].is_a?(Array) ? record["TXT"] : [record["TXT"]]
    vals.each { |v| add.call("TXT", v, false) }
  end
  if record.key?("URL")
    puts "  · URL record for #{fqdn} deferred (redirect support not yet implemented) — skipped"
  end
  recs
end

def same_record?(existing, desired)
  existing["type"] == desired["type"] && existing["content"] == desired["content"]
end

# --- operations -------------------------------------------------------------

def list_by_name(fqdn)
  cf(:get, "/zones/#{ZONE_ID}/dns_records?name=#{URI.encode_www_form_component(fqdn)}&per_page=100")
end

def reconcile(name, data)
  fqdn = "#{name}.#{ZONE_NAME}"
  desired = desired_records(name, data["record"] || {}, data["proxied"])
  existing = list_by_name(fqdn)

  # Delete stale first (also resolves CNAME-vs-other-type conflicts before create).
  existing.reject { |e| desired.any? { |d| same_record?(e, d) } }.each do |e|
    cf(:delete, "/zones/#{ZONE_ID}/dns_records/#{e['id']}")
    puts "  − deleted stale #{e['type']} #{fqdn}"
  end

  desired.each do |d|
    match = existing.find { |e| same_record?(e, d) }
    if match.nil?
      cf(:post, "/zones/#{ZONE_ID}/dns_records", d)
      puts "  + created #{d['type']} #{fqdn}#{PROXIABLE.include?(d['type']) ? " (proxied=#{d['proxied']})" : ''}"
    elsif PROXIABLE.include?(d["type"]) && match["proxied"] != d["proxied"]
      cf(:patch, "/zones/#{ZONE_ID}/dns_records/#{match['id']}", { "proxied" => d["proxied"] })
      puts "  ~ updated #{d['type']} #{fqdn} (proxied -> #{d['proxied']})"
    else
      puts "  = unchanged #{d['type']} #{fqdn}"
    end
  end
end

def teardown(name)
  fqdn = "#{name}.#{ZONE_NAME}"
  list_by_name(fqdn).each do |e|
    cf(:delete, "/zones/#{ZONE_ID}/dns_records/#{e['id']}")
    puts "  − deleted #{e['type']} #{fqdn}"
  end

  alias_addr = "#{name}@#{ZONE_NAME}"
  begin
    rules = cf(:get, "/zones/#{ZONE_ID}/email/routing/rules?per_page=100")
    rule = (rules || []).find { |r| (r["matchers"] || []).any? { |m| m["field"] == "to" && m["value"] == alias_addr } }
    if rule
      cf(:delete, "/zones/#{ZONE_ID}/email/routing/rules/#{rule['tag'] || rule['id']}")
      puts "  − deleted email routing rule for #{alias_addr}"
    end
  rescue => e
    puts "  ! could not check/remove routing rule for #{alias_addr}: #{e.message}"
  end
end

# --- email-setup comment ----------------------------------------------------

def comment_email_setup(names)
  return if names.empty?

  form_url = ENV["EMAIL_FORM_URL"].to_s
  if form_url.empty?
    puts "EMAIL_FORM_URL not set — skipping email-setup comment."
    return
  end
  repo = ENV["REPO"].to_s
  if repo.empty? || ENV["GH_TOKEN"].to_s.empty?
    puts "REPO/GH_TOKEN not set — skipping email-setup comment."
    return
  end

  _, prs = gh(:get, "/repos/#{repo}/commits/#{AFTER_SHA}/pulls")
  if !prs.is_a?(Array) || prs.empty?
    puts "No PR associated with #{AFTER_SHA} — cannot post email-setup comment."
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
    puts "  ✉ posted email-setup comment for #{name}"
  end
end

# --- main -------------------------------------------------------------------

def main
  files = changed_domain_files
  if files.empty?
    puts "No domain changes to provision."
    return
  end

  email_comments = []
  failures = []

  files.each do |f|
    puts "\n▶ #{f['status']}: #{f['name']}"
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

  puts "\nDone. #{files.length - failures.length}/#{files.length} provisioned" \
       "#{failures.empty? ? '' : ", failed: #{failures.join(', ')}"}"
  exit 1 unless failures.empty?
end

main if $PROGRAM_NAME == __FILE__
