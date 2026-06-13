# frozen_string_literal: true

require_relative "../scripts/blocklist-check"

RSpec.describe BlocklistCheck do
  subject(:checker) { described_class.new(env: env) }

  let(:env) { { "ZONE_NAME" => "devis.im" } }

  # Stub resolve() per query name. Keys are matched by substring against the
  # full `<domain>.<dnsbl>` query; value is the array of A addresses returned.
  def stub_resolve(answers = {})
    allow(checker).to receive(:resolve) do |name|
      key = answers.keys.find { |k| name.include?(k) }
      answers.fetch(key, [])
    end
  end

  describe "#check" do
    it "marks a DNSBL clean when the query does not resolve" do
      stub_resolve # all empty
      results = checker.check
      expect(results).to all(include(status: :clean))
    end

    it "marks a DNSBL listed on a real 127.0.x.x hit" do
      stub_resolve("dbl.spamhaus.org" => ["127.0.1.2"])
      dbl = checker.check.find { |r| r[:zone] == "dbl.spamhaus.org" }
      expect(dbl[:status]).to eq(:listed)
      expect(dbl[:addresses]).to eq(["127.0.1.2"])
    end

    it "treats a Spamhaus error sentinel as unknown, not listed" do
      stub_resolve("dbl.spamhaus.org" => ["127.255.255.254"])
      dbl = checker.check.find { |r| r[:zone] == "dbl.spamhaus.org" }
      expect(dbl[:status]).to eq(:unknown)
    end

    it "treats a URIBL whitelist/blocked sentinel as unknown" do
      stub_resolve("multi.uribl.com" => ["127.0.0.1"])
      uribl = checker.check.find { |r| r[:zone] == "multi.uribl.com" }
      expect(uribl[:status]).to eq(:unknown)
    end

    it "lists when at least one address is a real hit even if another is a sentinel" do
      stub_resolve("dbl.spamhaus.org" => ["127.255.255.254", "127.0.1.5"])
      dbl = checker.check.find { |r| r[:zone] == "dbl.spamhaus.org" }
      expect(dbl[:status]).to eq(:listed)
    end
  end

  describe "#run" do
    it "exits 0 when nothing is listed" do
      stub_resolve
      expect(quietly { checker.run }).to eq(0)
    end

    it "exits 1 and tries to open an issue when listed" do
      stub_resolve("dbl.spamhaus.org" => ["127.0.1.2"])
      expect(checker).to receive(:open_issue).with(
        array_including(hash_including(zone: "dbl.spamhaus.org"))
      )
      expect(quietly { checker.run }).to eq(1)
    end

    it "does not open an issue when only inconclusive" do
      stub_resolve("dbl.spamhaus.org" => ["127.255.255.254"])
      expect(checker).not_to receive(:open_issue)
      expect(quietly { checker.run }).to eq(0)
    end
  end

  describe "#open_issue" do
    let(:env) { { "ZONE_NAME" => "devis.im", "REPO" => "cdrrazan/denizens", "GH_TOKEN" => "x" } }

    let(:listed) { [{ name: "Spamhaus DBL", zone: "dbl.spamhaus.org", status: :listed, addresses: ["127.0.1.2"] }] }

    it "creates an issue when none is open" do
      calls = []
      allow(checker).to receive(:gh) do |method, path, body = nil|
        calls << { method: method, path: path, body: body }
        method == :get ? [200, []] : [201, { "number" => 1 }]
      end
      quietly { checker.open_issue(listed) }
      post = calls.find { |c| c[:method] == :post }
      expect(post[:path]).to eq("/repos/cdrrazan/denizens/issues")
      expect(post[:body][:body]).to include(described_class::ISSUE_MARKER)
    end

    it "does not duplicate when an open blocklist issue already exists" do
      calls = []
      allow(checker).to receive(:gh) do |method, path, body = nil|
        calls << method
        [200, [{ "body" => described_class::ISSUE_MARKER }]]
      end
      quietly { checker.open_issue(listed) }
      expect(calls).to eq([:get])
    end

    it "skips quietly when REPO/GH_TOKEN are missing" do
      bare = described_class.new(env: { "ZONE_NAME" => "devis.im" })
      expect(bare).not_to receive(:gh)
      quietly { bare.open_issue(listed) }
    end
  end
end
