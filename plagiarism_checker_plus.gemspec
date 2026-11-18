# frozen_string_literal: true

require_relative "lib/plagiarism_checker_plus"

Gem::Specification.new do |spec|
  spec.name = "plagiarism_checker_plus"
  spec.version = PlagiarismCheckerPlus::VERSION
  spec.authors = ["Plagiarism Checker Plus"]
  spec.email = ["contact@plagiarismcheckerplus.com"]
  spec.summary = "Official Ruby client for the Plagiarism Checker Plus API."
  spec.description = "Plagiarism checker API with linked sources and AI detector API with a per-sentence AI likelihood, from Plagiarism Checker Plus. Standard library only."
  spec.homepage = "https://plagiarismcheckerplus.com/integrations/api"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 2.7"
  spec.metadata = {
    "homepage_uri" => "https://plagiarismcheckerplus.com/integrations/api",
    "documentation_uri" => "https://app.plagiarismcheckerplus.com/api-docs",
    "source_code_uri" => "https://github.com/pcp-tech/plagiarism-checker-plus-ruby",
    "bug_tracker_uri" => "https://github.com/pcp-tech/plagiarism-checker-plus-ruby/issues"
  }
  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE"]
  spec.require_paths = ["lib"]
end
