# frozen_string_literal: true

require "json"
require "open3"
require "fileutils"
require "date"
require "net/http"
require "rubygems/package"
require "stringio"
require "tempfile"

# Release bookkeeping stays outside the gem's runtime library.
class Release
  class Error < StandardError; end

  VERSION_FILE = "lib/rspec/osc7501/version.rb"
  REPOSITORY = "cosgroveb/rspec-osc7501"

  def initialize(directory = Dir.pwd)
    @directory = File.expand_path(directory)
  end

  def prepare(version, directory)
    validate_version(version)
    raise Error, "Working tree must be clean" unless git("status", "--porcelain").empty?

    directory = File.expand_path(directory)
    FileUtils.mkdir_p(directory)
    git("fetch", "origin", "main", "--tags")
    captured = git("rev-parse", "origin/main")
    tag = "v#{version}"
    existing = remote_tag(tag)
    if existing
      sha = git("rev-parse", "#{tag}^{commit}")
      raise Error, "Tag does not match origin" unless sha == existing
      git("merge-base", "--is-ancestor", sha, captured)
      git("checkout", "--detach", sha)
      raise Error, "Tag version mismatch" unless source_version == version
      notes = release_notes(version)
    else
      git("checkout", "--detach", captured)
      current = source_version
      raise Error, "Version must exceed #{current}" unless Gem::Version.new(version) > Gem::Version.new(current)
      previous = "v#{current}"
      raise Error, "Previous release tag missing" unless remote_tag(previous)
      git("merge-base", "--is-ancestor", previous, captured)
      previous_source = git("show", "#{previous}:#{VERSION_FILE}")
      raise Error, "Previous tag version mismatch" unless read_version(previous_source) == current
      commits = git("log", "--reverse", "--no-merges", "--format=%H%x09%s", "#{previous}..#{captured}").lines
      raise Error, "No commits since #{previous}" if commits.empty?
      notes = commits.map do |line|
        hash, subject = line.chomp.split("\t", 2)
        escaped = subject.gsub(/([\\`*_{}\[\]()<>#])/) { |character| "\\#{character}" }
        "- #{escaped} ([#{hash[0, 7]}](https://github.com/#{REPOSITORY}/commit/#{hash}))"
      end.join("\n") + "\n"
      version_source = read(VERSION_FILE)
      write(VERSION_FILE, version_source.sub(/VERSION = "[^"]+"/, "VERSION = \"#{version}\""))
      changelog = read("CHANGELOG.md")
      history = changelog[/^## \d.*\z/m]
      raise Error, "Missing changelog history" unless history
      write("CHANGELOG.md", "# Changelog\n\n## Unreleased\n\n## #{version} - #{Time.now.utc.to_date}\n\n#{notes}\n#{history}")
      git("add", VERSION_FILE, "CHANGELOG.md")
      git("commit", "-m", "Release #{version}")
      sha = git("rev-parse", "HEAD")
      git("tag", tag, sha)
    end
    state = { "version" => version, "tag" => tag, "captured_main" => captured,
              "release_sha" => sha, "retry" => !existing.nil? }
    File.write(File.join(directory, "state.json"), JSON.pretty_generate(state) + "\n")
    File.write(File.join(directory, "notes.md"), notes)
    git("bundle", "create", File.join(directory, "source.bundle"), "refs/tags/#{tag}")
    state
  end

  def restore(directory)
    state = load_state(directory)
    git("fetch", File.expand_path(File.join(directory, "source.bundle")), "refs/tags/#{state.fetch('tag')}:refs/tags/#{state.fetch('tag')}")
    git("checkout", "--detach", state.fetch("release_sha"))
    verify_source(state)
    state
  end

  def promote(directory)
    state = load_state(directory)
    verify_source(state)
    existing = remote_tag(state.fetch("tag"))
    if state.fetch("retry")
      raise Error, "Remote tag changed" unless existing == state.fetch("release_sha")
      return
    end
    raise Error, "Release tag already exists" if existing
    current = git("ls-remote", "origin", "refs/heads/main").split.first
    raise Error, "main advanced during validation" unless current == state.fetch("captured_main")
    git("push", "--atomic", "origin", "#{state.fetch('release_sha')}:refs/heads/main", "refs/tags/#{state.fetch('tag')}")
  end

  def verify_gem(candidate, published)
    left = Gem::Package.new(candidate)
    right = Gem::Package.new(published)
    left.verify
    right.verify
    attributes = Gem::Specification.attribute_names - [:date, :rubygems_version]
    same_spec = attributes.all? { |attribute| left.spec.public_send(attribute) == right.spec.public_send(attribute) }
    raise Error, "Published gem differs from tagged source" unless same_spec && gem_contents(candidate) == gem_contents(published)
  end

  def check_gem(path)
    spec = Gem::Package.new(path).spec
    raise Error, "Wrong gem name" unless spec.name == "rspec-osc7501"
    validate_version(spec.version.to_s)
    status, = http_get("https://rubygems.org/api/v2/rubygems/rspec-osc7501/versions/#{spec.version}.json")
    return false if status == 404
    raise Error, "RubyGems lookup HTTP #{status}" unless status == 200
    status, bytes = http_get("https://rubygems.org/downloads/rspec-osc7501-#{spec.version}.gem")
    raise Error, "RubyGems download HTTP #{status}" unless status == 200
    Tempfile.create(["published-gem", ".gem"]) do |file|
      file.binmode
      file.write(bytes)
      file.flush
      verify_gem(path, file.path)
    end
    true
  end

  def check_release(version, tag, notes_file)
    validate_version(version)
    raise Error, "Invalid release tag" unless tag == "v#{version}"
    release = github_release(tag)
    return false unless release
    matches = release.fetch("tag_name") == tag && !release.fetch("draft") && !release.fetch("prerelease") &&
              release.fetch("target_commitish") == git("rev-parse", "#{tag}^{commit}") &&
              release.fetch("body").to_s.strip == File.read(notes_file).strip
    raise Error, "GitHub release differs from tagged source or notes" unless matches
    true
  end

  def create_release(version, tag, notes_file)
    validate_version(version)
    run("gh", "release", "create", tag, "--repo", REPOSITORY, "--verify-tag", "--title", "v#{version}",
        "--target", git("rev-parse", "#{tag}^{commit}"), "--notes-file", File.expand_path(notes_file))
  end

  def publish(directory, gem_path)
    state = load_state(directory)
    summary = state.slice("version", "tag", "release_sha").merge("rubygems" => "unknown", "github" => "unknown")
    verify_source(state)
    spec = Gem::Package.new(gem_path).spec
    raise Error, "Candidate version mismatch" unless spec.version.to_s == state.fetch("version")
    notes_file = File.join(directory, "notes.md")
    raise Error, "Release notes artifact mismatch" unless File.read(notes_file) == release_notes(state.fetch("version"))
    published = check_gem(gem_path)
    summary["rubygems"] = published ? "published" : "absent"
    raise Error, "Published gem has no matching release tag" if published && !state.fetch("retry")
    github = check_release(state.fetch("version"), state.fetch("tag"), notes_file)
    summary["github"] = github ? "published" : "incomplete"
    promote(directory)
    unless published
      summary["rubygems"] = "unknown"
      run("gem", "push", gem_path)
      summary["rubygems"] = "published"
      raise Error, "RubyGems publication could not be verified" unless check_gem(gem_path)
    end
    unless github
      create_release(state.fetch("version"), state.fetch("tag"), notes_file)
      summary["github"] = "published"
    end
  ensure
    if summary
      File.write(File.join(directory, "publication.json"), JSON.pretty_generate(summary) + "\n")
      if ENV["GITHUB_STEP_SUMMARY"]
        File.open(ENV.fetch("GITHUB_STEP_SUMMARY"), "a") do |file|
          file.puts "Release #{summary.fetch('version')} (#{summary.fetch('tag')}, #{summary.fetch('release_sha')})"
          file.puts "\nRubyGems: #{summary.fetch('rubygems')}\n\nGitHub Release: #{summary.fetch('github')}"
        end
      end
    end
  end

  private

  def gem_contents(path)
    contents = {}
    File.open(path, "rb") do |io|
      Gem::Package::TarReader.new(io) do |archive|
        archive.each do |entry|
          next unless entry.full_name == "data.tar.gz"
          Zlib::GzipReader.wrap(StringIO.new(entry.read)) do |gzip|
            Gem::Package::TarReader.new(gzip) do |tar|
              tar.each { |file| contents[file.full_name] = [file.header.typeflag, file.header.mode, file.header.linkname, file.read] }
            end
          end
        end
      end
    end
    contents
  end

  def http_get(url)
    uri = URI(url)
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 60) do |http|
      http.get(uri.request_uri)
    end
    [response.code.to_i, response.body]
  end

  def github_release(tag)
    output, error, success = capture("gh", "api", "--include", "repos/#{REPOSITORY}/releases/tags/#{tag}")
    header, body = output.split(/\r?\n\r?\n/, 2)
    status = header.to_s[/\AHTTP\/[\d.]+ (\d+)/, 1].to_i
    return nil if status == 404
    raise Error, "GitHub release lookup failed (HTTP #{status}): #{error.strip}" unless success && status == 200
    JSON.parse(body)
  end

  def validate_version(version)
    raise Error, "Expected stable major.minor.patch version" unless /\A(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\z/.match?(version)
  end

  def load_state(directory)
    state = JSON.parse(File.read(File.join(directory, "state.json")))
    validate_version(state.fetch("version"))
    raise Error, "Invalid tag" unless state.fetch("tag") == "v#{state.fetch('version')}"
    %w[captured_main release_sha].each do |key|
      raise Error, "Invalid #{key}" unless /\A[0-9a-f]{40}\z/.match?(state.fetch(key))
    end
    raise Error, "Invalid retry state" unless [true, false].include?(state.fetch("retry"))
    state
  end

  def verify_source(state)
    raise Error, "Release checkout mismatch" unless git("rev-parse", "HEAD") == state.fetch("release_sha")
    raise Error, "Release tag mismatch" unless git("rev-parse", "#{state.fetch('tag')}^{commit}") == state.fetch("release_sha")
    raise Error, "Release version mismatch" unless source_version == state.fetch("version")
  end

  def remote_tag(tag)
    lines = git("ls-remote", "origin", "refs/tags/#{tag}", "refs/tags/#{tag}^{}").lines
    lines.last&.split&.first
  end

  def release_notes(version)
    notes = read("CHANGELOG.md")[/^## #{Regexp.escape(version)} - \d{4}-\d{2}-\d{2}\n\n(.*?)(?=^## |\z)/m, 1]
    raise Error, "Missing release notes for #{version}" unless notes && !notes.strip.empty?
    notes.rstrip + "\n"
  end

  def read_version(source)
    version = source[/^\s*VERSION = "([^"]+)"/, 1]
    validate_version(version.to_s)
    version
  end

  def source_version
    read_version(read(VERSION_FILE))
  end

  def read(path)
    File.read(File.join(@directory, path))
  end

  def write(path, content)
    File.write(File.join(@directory, path), content)
  end

  def git(*args)
    run("git", *args).strip
  end

  def run(*args)
    output, error, success = capture(*args)
    raise Error, "#{args.first} failed: #{error.strip}" unless success
    output
  end

  def capture(*args)
    output, error, status = Open3.capture3(*args, chdir: @directory)
    [output, error, status.success?]
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    release = Release.new
    case ARGV.shift
    when "prepare" then release.prepare(*ARGV)
    when "restore" then release.restore(*ARGV)
    when "promote" then release.promote(*ARGV)
    when "publish" then release.publish(*ARGV)
    when "check-gem" then puts JSON.generate("published" => release.check_gem(*ARGV))
    when "check-release" then puts JSON.generate("published" => release.check_release(*ARGV))
    when "create-release" then release.create_release(*ARGV)
    else raise Release::Error, "Expected prepare, restore, promote, publish, check-gem, check-release or create-release"
    end
  rescue Release::Error => error
    warn error.message
    exit 1
  end
end
