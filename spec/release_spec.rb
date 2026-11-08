# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'open3'
require_relative '../script/release'

RSpec.describe Release, :aggregate_failures do
  let(:root) { Dir.mktmpdir('release-spec') }
  let(:release) { described_class.new(work) }

  def origin
    File.join(root, 'origin.git')
  end

  def work
    File.join(root, 'work')
  end

  def artifacts
    File.join(root, 'artifacts')
  end

  def notes_file
    File.join(artifacts, 'notes.md')
  end

  after { FileUtils.remove_entry(root) }

  def git(*args, directory: work)
    output, error, status = Open3.capture3('git', *args, chdir: directory)
    raise error unless status.success?

    output.strip
  end

  def commit(subject = 'Fix behavior')
    File.write(File.join(work, 'example'), subject)
    git('add', '.')
    git('commit', '-m', subject)
    git('push', 'origin', 'main')
  end

  before do
    FileUtils.mkdir_p(work)
    git('init', '--bare', origin)
    git('init', '-b', 'main')
    git('config', 'user.name', 'Release test')
    git('config', 'user.email', 'test@example.com')
    FileUtils.mkdir_p(File.join(work, 'lib/rspec/osc7501'))
    File.write(File.join(work, 'lib/rspec/osc7501/version.rb'), "VERSION = \"0.1.0\"\n")
    File.write(File.join(work, 'CHANGELOG.md'),
               "# Changelog\n\n## Unreleased\n\n- Handwritten\n\n## 0.1.0 - 2026-11-07\n\n- Initial release\n")
    git('add', '.')
    git('commit', '-m', 'Initial release')
    git('tag', 'v0.1.0')
    git('remote', 'add', 'origin', origin)
    git('push', 'origin', 'main', '--tags')
  end

  around do |example|
    original_summary = ENV['GITHUB_STEP_SUMMARY']
    ENV['GITHUB_STEP_SUMMARY'] = File.join(root, 'summary.md')
    example.run
  ensure
    original_summary ? ENV['GITHUB_STEP_SUMMARY'] = original_summary : ENV.delete('GITHUB_STEP_SUMMARY')
  end

  context 'when preparing source' do
    let(:previous_main) { git('rev-parse', 'origin/main') }
    let(:changelog) { File.read(File.join(work, 'CHANGELOG.md')) }
    let(:state) { release.prepare('0.1.1', artifacts) }

    before do
      commit('Fix [output] `handling`')
      previous_main
      state
    end

    it 'leaves origin unchanged' do
      expect(git('ls-remote', 'origin', 'refs/heads/main').split.first).to eq(previous_main)
    end

    it 'updates the version with stock Ruby quoting' do
      expect(File.read(File.join(work, 'lib/rspec/osc7501/version.rb'))).to include("'0.1.1'")
    end

    it 'preserves changelog history' do
      expect(changelog).to end_with("## 0.1.0 - 2026-11-07\n\n- Initial release\n")
    end

    it 'replaces handwritten notes' do
      expect(changelog).not_to include('Handwritten')
    end

    it 'escapes commit subjects' do
      expect(File.read(notes_file)).to include('Fix \\[output\\] \\`handling\\`')
    end

    it 'restores the exact prepared commit from its bundle' do
      restored = File.join(root, 'restored')
      git('clone', origin, restored)
      described_class.new(restored).restore(artifacts)
      expect(git('rev-parse', 'HEAD', directory: restored)).to eq(state.fetch('release_sha'))
    end
  end

  it 'prepares single-quoted current source after a double-quoted release' do
    File.write(File.join(work, 'lib/rspec/osc7501/version.rb'), "VERSION = '0.1.0'\n")
    commit('Use stock quoting')
    expect(release.prepare('0.1.1', artifacts)).to include('version' => '0.1.1')
  end

  ['0.1.1.pre.1', 'v0.1.1', '01.1.1', '0.1.1;echo bad', '0.0.9'].each do |version|
    it "rejects invalid or older version #{version}" do
      commit
      expect { release.prepare(version, artifacts) }.to raise_error(Release::Error)
    end
  end

  it 'rejects an empty release' do
    expect { release.prepare('0.1.1', artifacts) }.to raise_error(Release::Error, /No commits/)
  end

  it 'rejects a missing previous tag' do
    git('push', 'origin', ':refs/tags/v0.1.0')
    git('tag', '-d', 'v0.1.0')
    commit
    expect { release.prepare('0.1.1', artifacts) }.to raise_error(Release::Error)
  end

  it 'promotes the prepared commit and tag atomically' do
    commit
    state = release.prepare('0.1.1', artifacts)
    release.promote(artifacts)
    expect(git('ls-remote', 'origin', 'refs/heads/main').split.first).to eq(state.fetch('release_sha'))
    expect(git('ls-remote', 'origin', 'refs/tags/v0.1.1').split.first).to eq(state.fetch('release_sha'))
  end

  def advance_remote_main
    other = File.join(root, 'other')
    git('clone', '--branch', 'main', origin, other)
    git('config', 'user.name', 'Other', directory: other)
    git('config', 'user.email', 'other@example.com', directory: other)
    File.write(File.join(other, 'new'), 'new')
    git('add', '.', directory: other)
    git('commit', '-m', 'Advance main', directory: other)
    git('push', 'origin', 'main', directory: other)
  end

  context 'when main advances during validation' do
    let(:state) { release.prepare('0.1.1', artifacts) }

    before do
      commit
      state
      advance_remote_main
    end

    it 'rejects promotion without pushing the tag or moving main' do
      expect { release.promote(artifacts) }.to raise_error(Release::Error, /main advanced/)
      expect(git('ls-remote', 'origin', 'refs/tags/v0.1.1')).to eq('')
      expect(git('ls-remote', 'origin', 'refs/heads/main').split.first).not_to eq(state.fetch('release_sha'))
    end
  end

  context 'when retrying after main advances' do
    let(:state) { release.prepare('0.1.1', artifacts) }
    let(:retry_dir) { File.join(root, 'retry') }
    let(:retry_state) { release.prepare('0.1.1', retry_dir) }

    before do
      commit
      state
      release.promote(artifacts)
      git('checkout', '-B', 'main')
      commit('Later change')
    end

    it 'recovers the original release commit' do
      expect(retry_state).to include('retry' => true, 'release_sha' => state.fetch('release_sha'))
    end

    it 'does not move main back during promotion' do
      retry_state
      previous = git('ls-remote', 'origin', 'refs/heads/main')
      release.promote(retry_dir)
      expect(git('ls-remote', 'origin', 'refs/heads/main')).to eq(previous)
    end
  end

  def replace_previous_tag
    git('checkout', '--orphan', 'unrelated')
    git('commit', '-m', 'Unrelated release')
    git('tag', '-f', 'v0.1.0')
    git('push', '--force', 'origin', 'refs/tags/v0.1.0')
    git('checkout', 'main')
  end

  it "rejects a previous release tag outside main's history" do
    replace_previous_tag
    commit
    expect { release.prepare('0.1.1', artifacts) }.to raise_error(Release::Error)
  end

  it 'does not promote when another release tag appears' do
    prepare_release
    git('push', 'origin', 'refs/tags/v0.1.0:refs/tags/v0.1.1')
    before = git('ls-remote', 'origin', 'refs/heads/main')
    expect { release.promote(artifacts) }.to raise_error(Release::Error, /tag already exists/)
    expect(git('ls-remote', 'origin', 'refs/heads/main')).to eq(before)
  end

  def prepare_release
    commit
    release.prepare('0.1.1', artifacts)
  end

  def build_gem(filename, text: 'payload', date: '2026-11-08', dependency: '>= 3.12', version: '0.1.1')
    build = File.join(root, "build-#{filename}")
    FileUtils.mkdir_p(build)
    File.write(File.join(build, 'payload.rb'), text)
    specification = gem_specification(date, dependency, version)
    path = File.join(root, "#{filename}.gem")
    Gem::DefaultUserInteraction.use_ui(Gem::SilentUI.new) do
      Dir.chdir(build) { Gem::Package.build(specification, false, false, path) }
    end
    path
  end

  def configure_gem(spec)
    spec.summary = 'Test gem'
    spec.authors = ['Test']
    spec.license = 'Apache-2.0'
    spec.homepage = 'https://example.com'
    spec.files = ['payload.rb']
  end

  def gem_specification(date, dependency, version)
    Gem::Specification.new do |spec|
      spec.name = 'rspec-osc7501'
      spec.version = version
      configure_gem(spec)
      spec.date = date
      spec.required_ruby_version = '>= 3.3'
      spec.add_dependency('rspec-core', dependency, '< 4')
    end
  end

  it 'compares gem content and metadata while ignoring build dates' do
    first = build_gem('first')
    second = build_gem('second', date: '2026-11-09')
    expect { release.verify_gem(first, second) }.not_to raise_error
  end

  [{ text: 'changed' }, { dependency: '>= 3.13' }, { version: '0.1.2' }].each do |changes|
    it "rejects conflicting published gem #{changes.keys.first}" do
      first = build_gem('first')
      second = build_gem('second', **changes)
      expect { release.verify_gem(first, second) }.to raise_error(Release::Error, /differs/)
    end
  end

  it 'treats HTTP 404 as an absent gem' do
    gem = build_gem('candidate')
    allow(release).to receive(:http_get).and_return([404, 'missing'])
    expect(release.check_gem(gem)).to be(false)
  end

  [401, 403, 429, 500].each do |status|
    it "rejects gem lookup HTTP #{status}" do
      gem = build_gem('candidate')
      allow(release).to receive(:http_get).and_return([status, 'failed'])
      expect { release.check_gem(gem) }.to raise_error(Release::Error, /HTTP/)
    end
  end

  it 'does not treat network failures as an absent gem' do
    gem = build_gem('candidate')
    allow(release).to receive(:http_get).and_raise(Net::ReadTimeout)
    expect { release.check_gem(gem) }.to raise_error(Net::ReadTimeout)
  end

  it 'verifies a downloaded published gem' do
    gem = build_gem('candidate')
    remote = build_gem('remote', date: '2026-11-10')
    allow(release).to receive(:http_get).and_return([200, '{}'], [200, File.binread(remote)])
    expect(release.check_gem(gem)).to be(true)
  end

  context 'when checking an existing GitHub release' do
    let(:state) { prepare_release }
    let(:existing) do
      { 'tag_name' => 'v0.1.1', 'target_commitish' => state.fetch('release_sha'),
        'body' => File.read(notes_file), 'draft' => false, 'prerelease' => false }
    end

    before { state }

    it 'reports an absent release' do
      allow(release).to receive(:github_release).and_return(nil)
      expect(release.check_release('0.1.1', 'v0.1.1', notes_file)).to be(false)
    end

    it 'accepts matching notes and target' do
      allow(release).to receive(:github_release).and_return(existing)
      expect(release.check_release('0.1.1', 'v0.1.1', notes_file)).to be(true)
    end

    it 'rejects conflicting notes' do
      existing['body'] = 'Wrong notes'
      allow(release).to receive(:github_release).and_return(existing)
      expect do
        release.check_release('0.1.1', 'v0.1.1', notes_file)
      end.to raise_error(Release::Error, /GitHub release differs/)
    end
  end

  it 'recognizes GitHub 404' do
    allow(release).to receive(:capture).and_return(["HTTP/2.0 404 Not Found\n\n{}", '', false])
    expect(release.send(:github_release, 'v0.1.1')).to be_nil
  end

  [403, 500].each do |status|
    it "rejects GitHub HTTP #{status}" do
      allow(release).to receive(:capture).and_return(["HTTP/2.0 #{status} Error\n\n{}", 'error', false])
      expect { release.send(:github_release, 'v0.1.1') }.to raise_error(Release::Error)
    end
  end

  it 'rejects an existing gem without its release tag' do
    prepare_release
    gem = build_gem('candidate')
    allow(release).to receive(:check_gem).and_return(true)
    expect { release.publish(artifacts, gem) }.to raise_error(Release::Error, /no matching release tag/)
    expect(git('ls-remote', 'origin', 'refs/tags/v0.1.1')).to eq('')
  end

  context 'when an upload response fails' do
    let(:gem) { build_gem('candidate') }

    before do
      prepare_release
      allow(release).to receive_messages(check_gem: false, check_release: false)
      allow(release).to receive(:run).and_call_original
      allow(release).to receive(:run).with('gem', 'push', gem).and_raise(Release::Error, 'upload response lost')
    end

    it 'reports uncertain publication and preserves the failure' do
      expect { release.publish(artifacts, gem) }.to raise_error(Release::Error, /upload response lost/)
      summary = JSON.parse(File.read(File.join(artifacts, 'publication.json')))
      expect(summary).to include('rubygems' => 'unknown', 'github' => 'incomplete')
    end
  end

  context 'when GitHub fails after gem publication' do
    let(:gem) { build_gem('candidate') }
    let(:publication) { { uploaded: false, github: false, uploads: 0 } }
    let(:retry_dir) { File.join(root, 'retry') }

    before do
      prepare_release
      allow(release).to receive(:check_gem) { publication[:uploaded] }
      allow(release).to receive(:check_release) { publication[:github] }
      allow(release).to receive(:run).and_call_original
      allow(release).to receive(:run).with('gem', 'push', gem) do
        publication[:uploads] += 1
        publication[:uploaded] = true
      end
      allow(release).to receive(:create_release).and_raise(Release::Error, 'GitHub unavailable')
    end

    it 'records the partial publication and preserves the failure' do
      expect { release.publish(artifacts, gem) }.to raise_error(Release::Error, /GitHub unavailable/)
      summary = JSON.parse(File.read(File.join(artifacts, 'publication.json')))
      expect(summary).to include('rubygems' => 'published', 'github' => 'incomplete')
    end

    context 'when retrying' do
      before do
        begin
          release.publish(artifacts, gem)
        rescue Release::Error => e
          raise unless e.message == 'GitHub unavailable'
        end
        release.prepare('0.1.1', retry_dir)
        allow(release).to receive(:create_release) { publication[:github] = true }
      end

      it 'does not upload again' do
        release.publish(retry_dir, gem)
        expect(publication[:uploads]).to eq(1)
      end

      it 'preserves the promoted refs' do
        promoted = git('ls-remote', 'origin', 'refs/heads/main', 'refs/tags/v0.1.1')
        release.publish(retry_dir, gem)
        expect(git('ls-remote', 'origin', 'refs/heads/main', 'refs/tags/v0.1.1')).to eq(promoted)
      end

      it 'completes GitHub publication' do
        release.publish(retry_dir, gem)
        summary = JSON.parse(File.read(File.join(retry_dir, 'publication.json')))
        expect(summary).to include('rubygems' => 'published', 'github' => 'published')
      end
    end
  end
end
