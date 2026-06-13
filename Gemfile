# Automation dependencies for the denizens registry (GitHub Actions).
# Only the validation script needs a gem; provisioning uses the stdlib only.
source "https://rubygems.org"

ruby ">= 3.1"

# JSON Schema (draft-07) validation of domain claim files.
gem "json_schemer", "~> 2.3"

group :test do
  gem "rspec", "~> 3.13"
end
