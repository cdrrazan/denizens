#!/usr/bin/env ruby
# frozen_string_literal: true

# Validates a denizens domain-claim pull request.
#
# Enforces the "Validation checklist" in CLAUDE.md:
#   - exactly one changed file, under domains/, ending in .json
#   - filename (the claimed name) is lowercase [a-z0-9-], no leading/trailing hyphen
#   - file validates against schema.json
#   - CNAME is not combined with A/AAAA
#   - name is not reserved (reserved.json)
#   - name is not already taken (no such file at the PR base)
#   - owner.github equals the PR author
#   - no forwarding email anywhere in the file (only owner.email, a public contact, is allowed)
#   - edits/deletes are only allowed on the author's own file
#
# Inputs (env):
#   CHANGED_FILES_JSON  path to JSON: [{ "filename":, "status": }] (added|modified|removed|renamed)
#   PR_AUTHOR           the PR author's GitHub login
#   BASE_SHA            base commit sha (to read prior file state for ownership/taken checks)
#   REPO                "owner/repo" (for posting the sticky comment)
#   PR_NUMBER           pull request number
#   GH_TOKEN            token with pull-requests:write (to post the comment)
#   COMMENT_PATH        where to also write the markdown report (default: comment.md)
#
# Exit code: 0 if all checks pass (or nothing to validate), 1 if any check fails.

require "json"
require "net/http"
require "uri"
require "ipaddr"
require "json_schemer"

class Validator
  MARKER = "<!-- denizens-validation -->"
  EMAIL_RE = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/
  NAME_RE = /\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/
  MAX_NAMES_PER_OWNER = 5

  attr_reader :results, :skip_message

  def initialize(env: ENV)
    @env = env
    @author = env["PR_AUTHOR"].to_s
    @base_sha = env["BASE_SHA"].to_s
    @comment_path = env["COMMENT_PATH"] || "comment.md"
    @results = []        # [{ ok:, label:, detail: }]
    @skip_message = nil
  end

  # CLI entrypoint: validate, write + post the comment, exit with the verdict.
  def run
    validate
    body = comment_body
    File.write(@comment_path, body)
    post_sticky_comment(body)
    exit(passed? ? 0 : 1)
  end

  def passed?
    @results.all? { |r| r[:ok] }
  end

  # Runs every check. Populates @results / @skip_message. Never exits.
  def validate
    changed = JSON.parse(File.read(@env.fetch("CHANGED_FILES_JSON")))

    # Claim-relevant changes only: under domains/, *.json, excluding the example template.
    domain_changes = changed.select do |f|
      f["filename"].start_with?("domains/") &&
        f["filename"].end_with?(".json") &&
        f["filename"] != "domains/example.json"
    end

    if domain_changes.empty?
      @skip_message = "No domain claim changes detected — nothing to validate."
      return
    end

    # One PR, one name: the domain file must be the ONLY changed file.
    unless check(
      changed.length == 1,
      "One file per PR",
      changed.length == 1 ? "" : "This PR changes #{changed.length} files. A claim PR must change exactly one file under `domains/`. Files changed:\n" +
        changed.map { |f| "  - `#{f['filename']}` (#{f['status']})" }.join("\n")
    )
      return
    end

    file = domain_changes.first
    path = file["filename"]
    name = path.sub(%r{\Adomains/}, "").sub(/\.json\z/, "")

    # Filename / claimed-name format.
    check(
      NAME_RE.match?(name),
      "Valid name format",
      NAME_RE.match?(name) ? "Claiming `#{name}`." : "`#{name}` is invalid. Use lowercase letters, numbers, and hyphens only, with no leading or trailing hyphen."
    )

    # Reserved name.
    reserved = (JSON.parse(File.read("reserved.json"))["reserved"] rescue [])
    check(
      !reserved.include?(name),
      "Name not reserved",
      reserved.include?(name) ? "`#{name}` is reserved (see reserved.json) and cannot be claimed." : ""
    )

    status = file["status"] # added | modified | removed | renamed
    base_content = read_at_base(path)

    # Name not already taken (only meaningful for new claims).
    if %w[added renamed].include?(status)
      check(
        base_content.nil?,
        "Name available",
        base_content.nil? ? "" : "`#{name}` already exists in the registry and cannot be re-claimed."
      )

      # Per-owner cap: count every claim this author holds (the checkout includes
      # all merged files plus this new one) and reject if it would exceed the cap.
      owned = count_owned_names(@author)
      check(
        owned <= MAX_NAMES_PER_OWNER,
        "Within name limit (#{MAX_NAMES_PER_OWNER})",
        owned <= MAX_NAMES_PER_OWNER ? "" : "`#{@author}` would hold #{owned} names; the limit is #{MAX_NAMES_PER_OWNER}. Release a name (delete its file in a PR) before claiming another."
      )
    end

    # Ownership for edits/deletes: the existing file's owner must be the PR author.
    if %w[modified removed renamed].include?(status)
      prior_owner = (JSON.parse(base_content).dig("owner", "github") if base_content) rescue nil
      owns = prior_owner && !@author.empty? && prior_owner.downcase == @author.downcase
      check(
        owns,
        "Owns the file being changed",
        owns ? "" : "Only the owner may edit or release a name. `#{path}` is owned by `#{prior_owner || 'unknown'}`, but this PR is by `#{@author.empty? ? 'unknown' : @author}`."
      )
    end

    # Deletions have no head file to schema-check; ownership above is the gate.
    return if status == "removed"

    # Read the head version of the file.
    begin
      raw = File.read(path)
      data = JSON.parse(raw)
    rescue => e
      check(false, "Valid JSON", "`#{path}` is not valid JSON: #{e.message}")
      return
    end
    check(true, "Valid JSON")

    # CNAME cannot be combined with A/AAAA (clearer than the raw schema error).
    rec = data["record"] || {}
    cname_conflict = rec.key?("CNAME") && (rec.key?("A") || rec.key?("AAAA"))
    check(
      !cname_conflict,
      "CNAME not combined with A/AAAA",
      cname_conflict ? "`record` uses `CNAME` together with `A`/`AAAA`. Use `CNAME` for hosted platforms, or `A`/`AAAA` for a raw server IP — not both." : ""
    )

    # URL redirect records aren't provisioned yet — reject so a claim can't merge
    # into a dead, non-resolving subdomain. (Schema still accepts URL for forward-compat.)
    uses_url = rec.key?("URL")
    check(
      !uses_url,
      "Supported record type",
      uses_url ? "`URL` (redirect) records aren't supported yet — the subdomain would merge but never resolve. Use `CNAME` for hosted platforms, or `A`/`AAAA` for a raw server IP." : ""
    )

    # Record must declare at least one usable target, else the subdomain merges
    # but resolves to nothing.
    has_target = (rec.keys & %w[CNAME A AAAA TXT]).any?
    check(
      has_target,
      "Record has a target",
      has_target ? "" : "`record` has no usable target. Add a `CNAME` (a hostname), `A`/`AAAA` (IP addresses), or `TXT`."
    )

    # CNAME must be a hostname, not an IP literal (an IP is a valid hostname
    # syntactically, so the schema's `format: hostname` lets it slip through).
    if rec.key?("CNAME")
      cname_is_ip = ip_literal?(rec["CNAME"].to_s)
      check(
        !cname_is_ip,
        "CNAME is a hostname",
        cname_is_ip ? "`CNAME` must be a hostname (e.g. `yourname.github.io`), not an IP address. For a raw server IP use `A` (IPv4) or `AAAA` (IPv6)." : ""
      )
    end

    # A / AAAA must be non-empty arrays of public, routable IPs of the right
    # family. Rejects loopback/private/link-local/multicast/unspecified — a public
    # subdomain pointing at 127.0.0.1 / 10.x / ::1 is broken or abusive.
    { "A" => :v4, "AAAA" => :v6 }.each do |key, fam|
      next unless rec.key?(key)
      vals = rec[key]
      if !vals.is_a?(Array) || vals.empty?
        check(false, "#{key} addresses valid", "`#{key}` must be a non-empty array of #{fam == :v4 ? 'IPv4' : 'IPv6'} addresses.")
        next
      end
      bad = vals.reject { |v| routable_ip?(v.to_s, fam) }
      check(
        bad.empty?,
        "#{key} addresses valid",
        bad.empty? ? "" : "`#{key}` has invalid or non-public address(es): #{bad.map { |b| "`#{b}`" }.join(', ')}. Use a public #{fam == :v4 ? 'IPv4' : 'IPv6'} address (no loopback, private, link-local, or multicast ranges)."
      )
    end

    # Schema validation. (The data's own "$schema" pointer is allowed by the schema.)
    begin
      schemer = JSONSchemer.schema(JSON.parse(File.read("schema.json")))
      errors = schemer.validate(data).to_a
      check(
        errors.empty?,
        "Matches schema.json",
        errors.empty? ? "" : errors.map { |e|
          ptr = e["data_pointer"].to_s.empty? ? "/" : e["data_pointer"]
          "  - `#{ptr}` failed `#{e['type']}` check"
        }.uniq.join("\n")
      )
    rescue => e
      check(false, "Matches schema.json", "Could not run schema validation: #{e.message}")
    end

    # owner.github equals PR author.
    owner_github = data.dig("owner", "github").to_s
    matches = !owner_github.empty? && !@author.empty? && owner_github.downcase == @author.downcase
    check(
      matches,
      "owner.github matches PR author",
      matches ? "" : "`owner.github` is `#{owner_github.empty? ? '(missing)' : owner_github}` but this PR is by `#{@author.empty? ? 'unknown' : @author}`. You can only claim a name for yourself."
    )

    # No forwarding email anywhere. Only owner.email (a public contact) is allowed.
    public_contact = data.dig("owner", "email").to_s.downcase
    found = raw.scan(EMAIL_RE).map(&:downcase)
    offending = found.uniq.reject { |e| e == public_contact }
    check(
      offending.empty?,
      "No forwarding email in file",
      offending.empty? ? "" : "Found email address(es) that must not appear in this public repo: #{offending.map { |e| "`#{e}`" }.join(', ')}. Your forwarding address is submitted privately after merge — never put it in the file. (`owner.email`, if set, is a *public* contact only.)"
    )
  end

  # Read a file's content at the base commit, or nil if it doesn't exist there.
  def read_at_base(path)
    return nil if @base_sha.empty?

    out = `git show #{@base_sha}:#{path} 2>/dev/null`
    $?.success? ? out : nil
  end

  def comment_body
    if @skip_message
      "#{MARKER}\n### ✅ Claim validation\n\n#{@skip_message}\n"
    else
      header = passed? ? "### ✅ Claim validation passed" : "### ❌ Claim validation failed"
      lines = @results.map do |r|
        icon = r[:ok] ? "✅" : "❌"
        detail = r[:detail].empty? ? "" : "\n    #{r[:detail].gsub("\n", "\n    ")}"
        "- #{icon} **#{r[:label]}**#{detail}"
      end
      footer = if passed?
                 "\nAll checks passed. A maintainer will review and merge."
               else
                 "\nPlease fix the items marked ❌ and push to this PR — checks will re-run automatically."
               end
      "#{MARKER}\n#{header}\n\n#{lines.join("\n")}\n#{footer}\n"
    end
  end

  def post_sticky_comment(body)
    repo = @env["REPO"].to_s
    pr = @env["PR_NUMBER"].to_s
    return if repo.empty? || pr.empty? || @env["GH_TOKEN"].to_s.empty?

    _, comments = gh(:get, "/repos/#{repo}/issues/#{pr}/comments?per_page=100")
    existing = (comments || []).find { |c| c["body"]&.include?(MARKER) }
    if existing
      gh(:patch, "/repos/#{repo}/issues/comments/#{existing['id']}", { body: body })
    else
      gh(:post, "/repos/#{repo}/issues/#{pr}/comments", { body: body })
    end
  end

  def gh(method, path, body = nil)
    uri = URI("https://api.github.com#{path}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    klass = { get: Net::HTTP::Get, post: Net::HTTP::Post, patch: Net::HTTP::Patch }.fetch(method)
    req = klass.new(uri)
    req["Authorization"] = "Bearer #{@env['GH_TOKEN']}"
    req["Accept"] = "application/vnd.github+json"
    req["X-GitHub-Api-Version"] = "2022-11-28"
    req["Content-Type"] = "application/json"
    req.body = body.to_json if body
    res = http.request(req)
    [res.code.to_i, (JSON.parse(res.body) rescue nil)]
  end

  # Count how many domain files (on disk — merged claims plus the one in this PR)
  # belong to the given GitHub owner, case-insensitively. Malformed files are
  # skipped (they fail their own checks elsewhere).
  def count_owned_names(author)
    return 0 if author.to_s.empty?

    Dir.glob("domains/*.json").count do |f|
      next false if f == "domains/example.json"

      owner = JSON.parse(File.read(f)).dig("owner", "github").to_s
      !owner.empty? && owner.casecmp?(author)
    rescue StandardError
      false
    end
  end

  # True if the string parses as an IPv4/IPv6 literal (so it must NOT be a CNAME).
  def ip_literal?(str)
    IPAddr.new(str)
    true
  rescue IPAddr::Error
    false
  end

  # True only for a public, routable address of the expected family (:v4/:v6).
  # Rejects loopback, private (RFC1918 / ULA), link-local, multicast, unspecified.
  def routable_ip?(str, family)
    ip = IPAddr.new(str)
    return false unless family == (ip.ipv4? ? :v4 : :v6)
    return false if ip.loopback? || ip.private? || ip.link_local?
    return false if ip == IPAddr.new(family == :v4 ? "0.0.0.0" : "::")
    multicast = family == :v4 ? IPAddr.new("224.0.0.0/4") : IPAddr.new("ff00::/8")
    return false if multicast.include?(ip)
    true
  rescue IPAddr::Error
    false
  end

  private

  def check(ok, label, detail = "")
    @results << { ok: ok, label: label, detail: detail.to_s }
    ok
  end
end

Validator.new.run if $PROGRAM_NAME == __FILE__
