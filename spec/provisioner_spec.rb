# frozen_string_literal: true

require "tmpdir"
require_relative "../scripts/provision"

RSpec.describe Provisioner do
  subject(:provisioner) { described_class.new(env: env) }

  let(:env) { { "ZONE_NAME" => "devis.im" } }

  # Record every cf() call and answer GETs from `responses` (matched by substring).
  def stub_cf(responses = {})
    calls = []
    allow(provisioner).to receive(:cf) do |method, path, _body = nil|
      calls << { method: method, path: path }
      key = responses.keys.find { |k| path.include?(k) }
      responses[key]
    end
    calls
  end

  describe "#desired_records" do
    it "maps CNAME to a single proxiable record honoring proxied=true" do
      recs = provisioner.desired_records("rajan", { "CNAME" => "rajan.github.io" }, true)
      expect(recs).to eq([
        { "type" => "CNAME", "name" => "rajan.devis.im", "content" => "rajan.github.io", "proxied" => true, "ttl" => 1 }
      ])
    end

    it "maps A and AAAA arrays to one record each, honoring proxied=false" do
      recs = provisioner.desired_records("srv", { "A" => ["1.1.1.1", "2.2.2.2"], "AAAA" => ["::1"] }, false)
      expect(recs.count { |r| r["type"] == "A" }).to eq(2)
      expect(recs.count { |r| r["type"] == "AAAA" }).to eq(1)
      expect(recs).to all(include("proxied" => false))
    end

    it "maps a TXT array to one record per value, never proxied" do
      recs = provisioner.desired_records("v", { "TXT" => %w[one two] }, true)
      expect(recs.map { |r| r["content"] }).to eq(%w[one two])
      expect(recs).to all(include("type" => "TXT", "proxied" => false))
    end

    it "accepts a single TXT string" do
      recs = provisioner.desired_records("v", { "TXT" => "verify=abc" }, false)
      expect(recs).to eq([
        { "type" => "TXT", "name" => "v.devis.im", "content" => "verify=abc", "proxied" => false, "ttl" => 1 }
      ])
    end

    it "defers URL records (produces nothing)" do
      recs = quietly { provisioner.desired_records("u", { "URL" => "https://example.com" }, true) }
      expect(recs).to be_empty
    end
  end

  describe "#same_record?" do
    it "matches on type and content only (ignores proxied)" do
      a = { "type" => "A", "content" => "1.2.3.4", "proxied" => true }
      b = { "type" => "A", "content" => "1.2.3.4", "proxied" => false }
      expect(provisioner.same_record?(a, b)).to be(true)
    end

    it "is false when type differs" do
      a = { "type" => "A", "content" => "x" }
      b = { "type" => "AAAA", "content" => "x" }
      expect(provisioner.same_record?(a, b)).to be(false)
    end
  end

  describe "#reconcile" do
    it "deletes stale records, leaves matches, and only patches a proxied flip" do
      existing = [
        { "id" => "rec-cname", "type" => "CNAME", "content" => "rajan.github.io", "proxied" => false },
        { "id" => "rec-staleA", "type" => "A", "content" => "9.9.9.9", "proxied" => false }
      ]
      calls = stub_cf("dns_records?name=" => existing)

      quietly { provisioner.reconcile("rajan", { "record" => { "CNAME" => "rajan.github.io" }, "proxied" => true }) }

      deletes = calls.select { |c| c[:method] == :delete }
      patches = calls.select { |c| c[:method] == :patch }
      posts = calls.select { |c| c[:method] == :post }
      expect(deletes.map { |c| c[:path] }).to contain_exactly(a_string_matching(%r{/dns_records/rec-staleA}))
      expect(patches.map { |c| c[:path] }).to contain_exactly(a_string_matching(%r{/dns_records/rec-cname}))
      expect(posts).to be_empty
    end

    it "creates a missing record and deletes nothing when none exist" do
      calls = stub_cf("dns_records?name=" => [])

      quietly { provisioner.reconcile("new", { "record" => { "A" => ["1.2.3.4"] }, "proxied" => false }) }

      expect(calls.count { |c| c[:method] == :post }).to eq(1)
      expect(calls.count { |c| c[:method] == :delete }).to eq(0)
    end
  end

  describe "#teardown" do
    it "deletes all DNS records and only the matching routing rule" do
      dns = [{ "id" => "d1", "type" => "CNAME", "content" => "x" }]
      rules = [
        { "tag" => "rule-1", "matchers" => [{ "field" => "to", "value" => "rajan@devis.im" }] },
        { "tag" => "rule-2", "matchers" => [{ "field" => "to", "value" => "someone@devis.im" }] }
      ]
      calls = stub_cf("dns_records?name=" => dns, "email/routing/rules" => rules)

      quietly { provisioner.teardown("rajan") }

      deletes = calls.select { |c| c[:method] == :delete }.map { |c| c[:path] }
      expect(deletes).to include(a_string_matching(%r{/dns_records/d1}))
      expect(deletes).to include(a_string_matching(%r{/email/routing/rules/rule-1}))
      expect(deletes).not_to include(a_string_matching(/rule-2/))
    end
  end

  describe "#comment_email_setup" do
    it "does nothing when there are no names" do
      expect(provisioner).not_to receive(:gh)
      quietly { provisioner.comment_email_setup([]) }
    end

    it "skips when EMAIL_FORM_URL is unset" do
      expect(provisioner).not_to receive(:gh)
      quietly { provisioner.comment_email_setup(["rajan"]) }
    end

    it "posts one comment per name when fully configured" do
      env.merge!("EMAIL_FORM_URL" => "https://form.devis.im", "REPO" => "cdrrazan/denizens",
                 "GH_TOKEN" => "tok", "AFTER_SHA" => "deadbeef")
      allow(provisioner).to receive(:gh).with(:get, %r{/commits/deadbeef/pulls}).and_return([200, [{ "number" => 7 }]])

      expect(provisioner).to receive(:gh).with(
        :post,
        "/repos/cdrrazan/denizens/issues/7/comments",
        hash_including(body: a_string_including("rajan@devis.im", "https://form.devis.im?name=rajan"))
      )

      quietly { provisioner.comment_email_setup(["rajan"]) }
    end
  end

  describe "#changed_domain_files" do
    around { |ex| Dir.mktmpdir { |dir| Dir.chdir(dir) { ex.run } } }

    def git(*args)
      system("git", *args, out: File::NULL, err: File::NULL) || raise("git #{args.join(' ')} failed")
    end

    def commit(msg)
      git("add", "-A")
      git("commit", "-q", "-m", msg)
      `git rev-parse HEAD`.strip
    end

    before do
      git("init", "-q")
      git("config", "user.email", "t@t.com")
      git("config", "user.name", "t")
      Dir.mkdir("domains")
    end

    it "classifies added / modified / deleted and excludes the example template" do
      File.write("domains/alpha.json", "{}")
      File.write("domains/gamma.json", "{}")
      File.write("domains/example.json", "{}")
      c1 = commit("c1")

      File.write("domains/alpha.json", '{"x":1}')
      File.write("domains/beta.json", "{}")
      File.write("domains/example.json", '{"x":1}')
      File.delete("domains/gamma.json")
      c2 = commit("c2")

      prov = described_class.new(env: { "BEFORE_SHA" => c1, "AFTER_SHA" => c2 })
      result = prov.changed_domain_files.map { |f| [f["name"], f["status"]] }.sort

      expect(result).to eq([["alpha", "modified"], ["beta", "added"], ["gamma", "deleted"]])
    end

    it "treats every domain file as added when the base sha is all-zeros" do
      File.write("domains/alpha.json", "{}")
      File.write("domains/example.json", "{}")
      c1 = commit("c1")

      prov = described_class.new(env: { "BEFORE_SHA" => "0" * 40, "AFTER_SHA" => c1 })
      expect(prov.changed_domain_files.map { |f| [f["name"], f["status"]] }).to eq([["alpha", "added"]])
    end

    it "does not collapse a delete+add of identical content into a rename" do
      File.write("domains/old.json", '{"same":"content"}')
      c1 = commit("c1")

      File.delete("domains/old.json")
      File.write("domains/fresh.json", '{"same":"content"}')
      c2 = commit("c2")

      prov = described_class.new(env: { "BEFORE_SHA" => c1, "AFTER_SHA" => c2 })
      result = prov.changed_domain_files.map { |f| [f["name"], f["status"]] }.sort
      expect(result).to eq([["fresh", "added"], ["old", "deleted"]])
    end
  end
end
