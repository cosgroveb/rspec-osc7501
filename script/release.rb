# frozen_string_literal: true

require 'json'
require 'open3'
require 'fileutils'
require 'date'
require 'net/http'
require 'rubygems/package'
require 'stringio'
require 'tempfile'

# Release bookkeeping stays outside the gem's runtime library.
class Release
  class Error < StandardError; end
  class DownloadNotVisible < Error; end

  VERSION_FILE = 'lib/rspec/osc7501/version.rb'
  REPOSITORY = 'cosgroveb/rspec-osc7501'

  # Builds or recovers the exact source commit to validate.
  module Preparation
    def prepare(version, directory)
      validate_version(version)
      raise Error, 'Working tree must be clean' unless git('status', '--porcelain').empty?

      directory = File.expand_path(directory)
      FileUtils.mkdir_p(directory)
      state = prepare_state(version)
      save_bundle(directory, state)
      state
    end

    def prepare_state(version)
      git('fetch', 'origin', 'main', '--tags')
      captured = git('rev-parse', 'origin/main')
      tag = "v#{version}"
      existing = remote_tag(tag)
      sha = existing ? recover_tag(version, captured, existing) : create_tag(version, captured)
      { 'version' => version, 'tag' => tag, 'captured_main' => captured,
        'release_sha' => sha, 'retry' => !existing.nil? }
    end

    def recover_tag(version, captured, existing)
      sha = git('rev-parse', "v#{version}^{commit}")
      raise Error, 'Tag does not match origin' unless sha == existing

      git('merge-base', '--is-ancestor', sha, captured)
      git('checkout', '--detach', sha)
      raise Error, 'Tag version mismatch' unless source_version == version

      sha
    end

    def create_tag(version, captured)
      git('checkout', '--detach', captured)
      previous = previous_tag(version, captured)
      update_release_files(version, commit_notes(previous, captured))
      git('add', VERSION_FILE, 'CHANGELOG.md')
      git('commit', '-m', "Release #{version}")
      sha = git('rev-parse', 'HEAD')
      git('tag', "v#{version}", sha)
      sha
    end

    def previous_tag(version, captured)
      current = source_version
      raise Error, "Version must exceed #{current}" unless Gem::Version.new(version) > Gem::Version.new(current)

      previous = "v#{current}"
      raise Error, 'Previous release tag missing' unless remote_tag(previous)

      git('merge-base', '--is-ancestor', previous, captured)
      raise Error, 'Previous tag version mismatch' unless read_version(git('show',
                                                                           "#{previous}:#{VERSION_FILE}")) == current

      previous
    end

    def commit_notes(previous, captured)
      commits = git('log', '--reverse', '--no-merges', '--format=%H%x09%s', "#{previous}..#{captured}").lines
      raise Error, "No commits since #{previous}" if commits.empty?

      "#{commits.map { |line| commit_bullet(line) }.join("\n")}\n"
    end

    def commit_bullet(line)
      hash, subject = line.chomp.split("\t", 2)
      escaped = subject.gsub(/([\\`*_{}\[\]()<>#])/) { |character| "\\#{character}" }
      "- #{escaped} ([#{hash[0, 7]}](https://github.com/#{REPOSITORY}/commit/#{hash}))"
    end

    def update_release_files(version, notes)
      write(VERSION_FILE, read(VERSION_FILE).sub(/VERSION = ["'][^"']+["']/, "VERSION = '#{version}'"))
      history = read('CHANGELOG.md')[/^## \d.*\z/m]
      raise Error, 'Missing changelog history' unless history

      write('CHANGELOG.md',
            "# Changelog\n\n## Unreleased\n\n## #{version} - #{Time.now.utc.to_date}\n\n#{notes}\n#{history}")
    end

    def save_bundle(directory, state)
      File.write(File.join(directory, 'state.json'), "#{JSON.pretty_generate(state)}\n")
      File.write(File.join(directory, 'notes.md'), release_notes(state.fetch('version')))
      git('bundle', 'create', File.join(directory, 'source.bundle'), "refs/tags/#{state.fetch('tag')}")
    end
    private :prepare_state, :recover_tag, :create_tag, :previous_tag, :commit_notes, :commit_bullet,
            :update_release_files, :save_bundle
  end

  # Checks published gem metadata and payload against the candidate.
  module Packages
    def verify_gem(candidate, published)
      left = Gem::Package.new(candidate)
      right = Gem::Package.new(published)
      left.verify
      right.verify
      attributes = Gem::Specification.attribute_names - %i[date rubygems_version]
      same_spec = attributes.all? { |attribute| left.spec.public_send(attribute) == right.spec.public_send(attribute) }
      return if same_spec && gem_contents(candidate) == gem_contents(published)

      raise Error,
            'Published gem differs from tagged source'
    end

    def check_gem(path)
      spec = candidate_spec(path)
      status, = http_get("https://rubygems.org/api/v2/rubygems/rspec-osc7501/versions/#{spec.version}.json")
      return false if status == 404
      raise Error, "RubyGems lookup HTTP #{status}" unless status == 200

      verify_download(path, spec.version)
      true
    end

    def candidate_spec(path)
      spec = Gem::Package.new(path).spec
      raise Error, 'Wrong gem name' unless spec.name == 'rspec-osc7501'

      validate_version(spec.version.to_s)
      spec
    end

    def verify_download(path, version)
      status, bytes = http_get("https://rubygems.org/downloads/rspec-osc7501-#{version}.gem")
      raise DownloadNotVisible, 'RubyGems download HTTP 404' if status == 404
      raise Error, "RubyGems download HTTP #{status}" unless status == 200

      Tempfile.create(['published-gem', '.gem']) do |file|
        file.binmode
        file.write(bytes)
        file.flush
        verify_gem(path, file.path)
      end
      true
    end

    def await_gem(path)
      deadline = monotonic_time + 300
      while monotonic_time < deadline
        begin
          return if check_gem(path)
        rescue DownloadNotVisible
          # Wait for the uploaded file to become available.
        end

        sleep((deadline - monotonic_time).clamp(0, 5))
      end
      raise Error, 'RubyGems publication could not be verified within 300 seconds'
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def gem_contents(path)
      File.open(path, 'rb') do |io|
        Gem::Package::TarReader.new(io) do |archive|
          archive.each do |entry|
            return payload_contents(entry.read) if entry.full_name == 'data.tar.gz'
          end
        end
      end
      {}
    end

    def payload_contents(bytes)
      Zlib::GzipReader.wrap(StringIO.new(bytes)) do |gzip|
        Gem::Package::TarReader.new(gzip) do |tar|
          return tar.to_h do |file|
            [file.full_name, [file.header.typeflag, file.header.mode, file.header.linkname, file.read]]
          end
        end
      end
    end

    def http_get(url)
      uri = URI(url)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 60) do |http|
        http.get(uri.request_uri)
      end
      [response.code.to_i, response.body]
    end
    private :candidate_spec, :verify_download, :await_gem, :monotonic_time,
            :gem_contents, :payload_contents, :http_get
  end

  # Publishes validated source and records partial publication outcomes.
  module Publication
    def check_release(version, tag, notes_file)
      validate_version(version)
      raise Error, 'Invalid release tag' unless tag == "v#{version}"

      release = github_release(tag)
      return false unless release

      raise Error, 'GitHub release differs from tagged source or notes' unless matching_release?(release, tag,
                                                                                                 notes_file)

      true
    end

    def matching_release?(release, tag, notes_file)
      expected = { 'tag_name' => tag, 'draft' => false, 'prerelease' => false }
      expected.all? { |key, value| release.fetch(key) == value } &&
        remote_tag(tag) == git('rev-parse', "#{tag}^{commit}") &&
        release.fetch('body').to_s.strip == File.read(notes_file).strip
    end

    def create_release(version, tag, notes_file)
      validate_version(version)
      unless remote_tag(tag) == git('rev-parse', "#{tag}^{commit}")
        raise Error, 'Remote release tag differs from local source'
      end

      run('gh', 'release', 'create', tag, '--repo', REPOSITORY, '--verify-tag', '--title', "v#{version}",
          '--notes-file', File.expand_path(notes_file))
    end

    def publish(directory, gem_path)
      state = load_state(directory)
      summary = state.slice('version', 'tag', 'release_sha').merge('rubygems' => 'unknown', 'github' => 'unknown')
      notes_file = File.join(directory, 'notes.md')
      verify_candidate(state, gem_path, notes_file)
      publication_status(state, gem_path, notes_file, summary)
      promote(directory)
      publish_gem(gem_path, summary) unless summary['rubygems'] == 'published'
      publish_github(state, notes_file, summary) unless summary['github'] == 'published'
    ensure
      save_publication(directory, summary) if summary
    end

    def verify_candidate(state, gem_path, notes_file)
      verify_source(state)
      spec = Gem::Package.new(gem_path).spec
      raise Error, 'Candidate version mismatch' unless spec.version.to_s == state.fetch('version')
      return if File.read(notes_file) == release_notes(state.fetch('version'))

      raise Error,
            'Release notes artifact mismatch'
    end

    def publication_status(state, gem_path, notes_file, summary)
      published = check_gem(gem_path)
      summary['rubygems'] = published ? 'published' : 'absent'
      raise Error, 'Published gem has no matching release tag' if published && !state.fetch('retry')

      github = check_release(state.fetch('version'), state.fetch('tag'), notes_file)
      summary['github'] = github ? 'published' : 'incomplete'
    end

    def publish_gem(gem_path, summary)
      summary['rubygems'] = 'unknown'
      run('gem', 'push', gem_path)
      summary['rubygems'] = 'published'
      await_gem(gem_path)
    end

    def publish_github(state, notes_file, summary)
      create_release(state.fetch('version'), state.fetch('tag'), notes_file)
      summary['github'] = 'published'
    end

    def save_publication(directory, summary)
      File.write(File.join(directory, 'publication.json'), "#{JSON.pretty_generate(summary)}\n")
      return unless ENV['GITHUB_STEP_SUMMARY']

      File.open(ENV.fetch('GITHUB_STEP_SUMMARY'), 'a') do |file|
        file.puts "Release #{summary.fetch('version')} (#{summary.fetch('tag')}, #{summary.fetch('release_sha')})"
        file.puts "\nRubyGems: #{summary.fetch('rubygems')}\n\nGitHub Release: #{summary.fetch('github')}"
      end
    end

    def github_release(tag)
      output, error, success = capture('gh', 'api', '--include', "repos/#{REPOSITORY}/releases/tags/#{tag}")
      header, body = output.split(/\r?\n\r?\n/, 2)
      status = header.to_s[%r{\AHTTP/[\d.]+ (\d+)}, 1].to_i
      return nil if status == 404
      raise Error, "GitHub release lookup failed (HTTP #{status}): #{error.strip}" unless success && status == 200

      JSON.parse(body)
    end
    private :matching_release?, :verify_candidate, :publication_status, :publish_gem, :publish_github,
            :save_publication, :github_release
  end

  include Preparation
  include Packages
  include Publication

  def initialize(directory = Dir.pwd)
    @directory = File.expand_path(directory)
  end

  def restore(directory)
    state = load_state(directory)
    git('fetch', File.expand_path(File.join(directory, 'source.bundle')),
        "refs/tags/#{state.fetch('tag')}:refs/tags/#{state.fetch('tag')}")
    git('checkout', '--detach', state.fetch('release_sha'))
    verify_source(state)
    state
  end

  def promote(directory)
    state = load_state(directory)
    verify_source(state)
    existing = remote_tag(state.fetch('tag'))
    if state.fetch('retry')
      raise Error, 'Remote tag changed' unless existing == state.fetch('release_sha')

      return
    end
    raise Error, 'Release tag already exists' if existing

    push_release(state)
  end

  def push_release(state)
    current = git('ls-remote', 'origin', 'refs/heads/main').split.first
    raise Error, 'main advanced during validation' unless current == state.fetch('captured_main')

    git('push', '--atomic', 'origin', "#{state.fetch('release_sha')}:refs/heads/main",
        "refs/tags/#{state.fetch('tag')}")
  end

  private :push_release

  private

  def validate_version(version)
    return if /\A(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\z/.match?(version)

    raise Error,
          'Expected stable major.minor.patch version'
  end

  def load_state(directory)
    state = JSON.parse(File.read(File.join(directory, 'state.json')))
    validate_version(state.fetch('version'))
    raise Error, 'Invalid tag' unless state.fetch('tag') == "v#{state.fetch('version')}"

    %w[captured_main release_sha].each do |key|
      raise Error, "Invalid #{key}" unless /\A[0-9a-f]{40}\z/.match?(state.fetch(key))
    end
    raise Error, 'Invalid retry state' unless [true, false].include?(state.fetch('retry'))

    state
  end

  def verify_source(state)
    raise Error, 'Release checkout mismatch' unless git('rev-parse', 'HEAD') == state.fetch('release_sha')
    raise Error, 'Release tag mismatch' unless git('rev-parse',
                                                   "#{state.fetch('tag')}^{commit}") == state.fetch('release_sha')
    raise Error, 'Release version mismatch' unless source_version == state.fetch('version')
  end

  def remote_tag(tag)
    lines = git('ls-remote', 'origin', "refs/tags/#{tag}", "refs/tags/#{tag}^{}").lines
    lines.last&.split&.first
  end

  def release_notes(version)
    notes = read('CHANGELOG.md')[/^## #{Regexp.escape(version)} - \d{4}-\d{2}-\d{2}\n\n(.*?)(?=^## |\z)/m, 1]
    raise Error, "Missing release notes for #{version}" unless notes && !notes.strip.empty?

    "#{notes.rstrip}\n"
  end

  def read_version(source)
    version = source[/^\s*VERSION = ["']([^"']+)["']/, 1]
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
    run('git', *args).strip
  end

  def run(*args)
    output, error, success = capture(*args)
    raise Error, "#{args.first} failed: #{[output, error].reject(&:empty?).join("\n").strip}" unless success

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
    when 'prepare' then release.prepare(*ARGV)
    when 'restore' then release.restore(*ARGV)
    when 'promote' then release.promote(*ARGV)
    when 'publish' then release.publish(*ARGV)
    when 'check-gem' then puts JSON.generate('published' => release.check_gem(*ARGV))
    when 'check-release' then puts JSON.generate('published' => release.check_release(*ARGV))
    when 'create-release' then release.create_release(*ARGV)
    else raise Release::Error, 'Expected prepare, restore, promote, publish, check-gem, check-release or create-release'
    end
  rescue Release::Error => e
    warn e.message
    exit 1
  end
end
