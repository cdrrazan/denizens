# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "json"
require_relative "../scripts/validate-claim"

# These specs run from the repo root so the validator reads the real schema.json
# and reserved.json. Claim files under test are written into domains/ and removed
# afterwards; git base lookups are stubbed via #read_at_base.
RSpec.describe Validator do
  let(:tmp) { Dir.mktmpdir }
  let(:written) { [] }

  after do
    FileUtils.remove_entry(tmp) if File.directory?(tmp)
    written.each { |p| File.delete(p) if File.exist?(p) }
  end

  def write_claim(filename, content)
    path = File.join(REPO_ROOT, filename)
    File.write(path, content)
    written << path
  end

  # Build a validator over the given changed-files list and run it.
  def validate(changed, author:, base_content: nil)
    changed_path = File.join(tmp, "changed.json")
    File.write(changed_path, JSON.dump(changed))
    v = described_class.new(env: {
      "CHANGED_FILES_JSON" => changed_path,
      "PR_AUTHOR" => author,
      "COMMENT_PATH" => File.join(tmp, "comment.md")
    })
    allow(v).to receive(:read_at_base).and_return(base_content)
    quietly { v.validate }
    v
  end

  def result(validator, label)
    validator.results.find { |r| r[:label] == label }
  end

  def claim(github:, record: { "CNAME" => "x.github.io" }, **extra)
    JSON.pretty_generate({ "$schema" => "../schema.json", "owner" => { "github" => github }, "record" => record }.merge(extra))
  end

  describe "happy path" do
    it "passes a valid added claim whose owner matches the author" do
      write_claim("domains/spec-ok.json", claim(github: "rajan", email: { "enabled" => true }))
      v = validate([{ "filename" => "domains/spec-ok.json", "status" => "added" }], author: "rajan")

      expect(v.passed?).to be(true)
      expect(v.comment_body).to include(Validator::MARKER, "Claim validation passed")
    end

    it "matches the author case-insensitively" do
      write_claim("domains/spec-case.json", claim(github: "Rajan"))
      v = validate([{ "filename" => "domains/spec-case.json", "status" => "added" }], author: "rajan")
      expect(result(v, "owner.github matches PR author")[:ok]).to be(true)
    end
  end

  describe "name rules" do
    it "rejects a reserved name" do
      write_claim("domains/admin.json", claim(github: "rajan"))
      v = validate([{ "filename" => "domains/admin.json", "status" => "added" }], author: "rajan")
      expect(v.passed?).to be(false)
      expect(result(v, "Name not reserved")[:ok]).to be(false)
    end

    it "rejects a name with a leading hyphen" do
      write_claim("domains/-bad.json", claim(github: "rajan"))
      v = validate([{ "filename" => "domains/-bad.json", "status" => "added" }], author: "rajan")
      expect(result(v, "Valid name format")[:ok]).to be(false)
    end

    it "rejects a name already taken (exists at base)" do
      write_claim("domains/taken.json", claim(github: "rajan"))
      v = validate([{ "filename" => "domains/taken.json", "status" => "added" }],
                   author: "rajan", base_content: claim(github: "rajan"))
      expect(result(v, "Name available")[:ok]).to be(false)
    end
  end

  describe "schema + record rules" do
    it "flags CNAME combined with A both explicitly and via the schema" do
      write_claim("domains/conflict.json", claim(github: "rajan", record: { "CNAME" => "x.github.io", "A" => ["1.2.3.4"] }))
      v = validate([{ "filename" => "domains/conflict.json", "status" => "added" }], author: "rajan")
      expect(result(v, "CNAME not combined with A/AAAA")[:ok]).to be(false)
      expect(result(v, "Matches schema.json")[:ok]).to be(false)
    end

    it "reports invalid JSON without raising" do
      write_claim("domains/broken.json", "{ not json ")
      v = validate([{ "filename" => "domains/broken.json", "status" => "added" }], author: "rajan")
      expect(result(v, "Valid JSON")[:ok]).to be(false)
    end

    it "rejects a URL record (redirects not supported yet)" do
      write_claim("domains/redir.json", claim(github: "rajan", record: { "URL" => "https://example.com" }))
      v = validate([{ "filename" => "domains/redir.json", "status" => "added" }], author: "rajan")
      expect(result(v, "Supported record type")[:ok]).to be(false)
    end

    it "accepts a CNAME record as a supported type" do
      write_claim("domains/ok.json", claim(github: "rajan", record: { "CNAME" => "x.github.io" }))
      v = validate([{ "filename" => "domains/ok.json", "status" => "added" }], author: "rajan")
      expect(result(v, "Supported record type")[:ok]).to be(true)
    end
  end

  describe "forwarding-email guard" do
    it "rejects an email address hidden in a TXT record" do
      # owner.email is a public contact and must be allowed; the TXT address must not.
      content = JSON.pretty_generate(
        "$schema" => "../schema.json",
        "owner" => { "github" => "rajan", "email" => "public@contact.com" },
        "record" => { "TXT" => "send mail to private@gmail.com" }
      )
      write_claim("domains/leaky.json", content)
      v = validate([{ "filename" => "domains/leaky.json", "status" => "added" }], author: "rajan")

      check = result(v, "No forwarding email in file")
      expect(check[:ok]).to be(false)
      expect(check[:detail]).to include("private@gmail.com")
      expect(check[:detail]).not_to include("public@contact.com")
    end

    it "allows a file whose only email is the public owner.email" do
      content = JSON.pretty_generate(
        "$schema" => "../schema.json",
        "owner" => { "github" => "rajan", "email" => "me@public.com" },
        "record" => { "CNAME" => "x.github.io" }
      )
      write_claim("domains/pub.json", content)
      v = validate([{ "filename" => "domains/pub.json", "status" => "added" }], author: "rajan")
      expect(result(v, "No forwarding email in file")[:ok]).to be(true)
    end
  end

  describe "ownership of edits and deletes" do
    it "rejects deleting someone else's file" do
      v = validate([{ "filename" => "domains/owned.json", "status" => "removed" }],
                   author: "intruder", base_content: claim(github: "realowner"))
      expect(v.passed?).to be(false)
      expect(result(v, "Owns the file being changed")[:ok]).to be(false)
    end

    it "allows the owner to release their own name" do
      v = validate([{ "filename" => "domains/owned.json", "status" => "removed" }],
                   author: "realowner", base_content: claim(github: "realowner"))
      expect(v.passed?).to be(true)
      # No schema check runs for a deletion.
      expect(result(v, "Matches schema.json")).to be_nil
    end

    it "rejects modifying someone else's file" do
      write_claim("domains/owned.json", claim(github: "realowner"))
      v = validate([{ "filename" => "domains/owned.json", "status" => "modified" }],
                   author: "intruder", base_content: claim(github: "realowner"))
      expect(result(v, "Owns the file being changed")[:ok]).to be(false)
    end
  end

  describe "PR shape" do
    it "rejects a multi-file PR and stops after the first check" do
      v = validate([{ "filename" => "domains/a.json", "status" => "added" },
                    { "filename" => "README.md", "status" => "modified" }], author: "rajan")
      expect(v.passed?).to be(false)
      expect(v.results.map { |r| r[:label] }).to eq(["One file per PR"])
    end

    it "skips when no domain files changed" do
      v = validate([{ "filename" => "README.md", "status" => "modified" }], author: "rajan")
      expect(v.passed?).to be(true)
      expect(v.skip_message).to include("nothing to validate")
      expect(v.comment_body).to include("Claim validation")
    end
  end
end
