# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "open3"
require_relative "../script/release"

RSpec.describe Release do
  def git(*args, directory: @work)
    output, error, status = Open3.capture3("git", *args, chdir: directory)
    raise error unless status.success?
    output.strip
  end

  def commit(subject = "Fix behavior")
    File.write(File.join(@work, "example"), subject)
    git("add", ".")
    git("commit", "-m", subject)
    git("push", "origin", "main")
  end

  around do |example|
    Dir.mktmpdir("release-spec") do |directory|
      @root = directory
      @origin = File.join(directory, "origin.git")
      @work = File.join(directory, "work")
      @artifacts = File.join(directory, "artifacts")
      FileUtils.mkdir_p(@work)
      git("init", "--bare", @origin)
      git("init", "-b", "main")
      git("config", "user.name", "Release test")
      git("config", "user.email", "test@example.com")
      FileUtils.mkdir_p(File.join(@work, "lib/rspec/osc7501"))
      File.write(File.join(@work, "lib/rspec/osc7501/version.rb"), 'VERSION = "0.1.0"' + "\n")
      File.write(File.join(@work, "CHANGELOG.md"), "# Changelog\n\n## Unreleased\n\n- Handwritten\n\n## 0.1.0 - 2026-11-07\n\n- Initial release\n")
      git("add", ".")
      git("commit", "-m", "Initial release")
      git("tag", "v0.1.0")
      git("remote", "add", "origin", @origin)
      git("push", "origin", "main", "--tags")
      @release = described_class.new(@work)
      original_summary = ENV["GITHUB_STEP_SUMMARY"]
      ENV["GITHUB_STEP_SUMMARY"] = File.join(directory, "summary.md")
      begin
        example.run
      ensure
        original_summary ? ENV["GITHUB_STEP_SUMMARY"] = original_summary : ENV.delete("GITHUB_STEP_SUMMARY")
      end
    end
  end

  it "prepares a bundled commit without updating origin" do
    commit('Fix [output] `handling`')
    before = git("rev-parse", "origin/main")
    state = @release.prepare("0.1.1", @artifacts)
    expect(git("ls-remote", "origin", "refs/heads/main").split.first).to eq(before)
    expect(File.read(File.join(@work, "lib/rspec/osc7501/version.rb"))).to include('"0.1.1"')
    changelog = File.read(File.join(@work, "CHANGELOG.md"))
    expect(changelog).to end_with("## 0.1.0 - 2026-11-07\n\n- Initial release\n")
    expect(changelog).not_to include("Handwritten")
    expect(File.read(File.join(@artifacts, "notes.md"))).to include('Fix \\[output\\] \\`handling\\`')
    restored = File.join(@root, "restored")
    git("clone", @origin, restored)
    described_class.new(restored).restore(@artifacts)
    expect(git("rev-parse", "HEAD", directory: restored)).to eq(state.fetch("release_sha"))
  end

  ["0.1.1.pre.1", "v0.1.1", "01.1.1", "0.1.1;echo bad", "0.0.9"].each do |version|
    it "rejects invalid or older version #{version}" do
      commit
      expect { @release.prepare(version, @artifacts) }.to raise_error(Release::Error)
    end
  end

  it "rejects an empty release" do
    expect { @release.prepare("0.1.1", @artifacts) }.to raise_error(Release::Error, /No commits/)
  end

  it "rejects a missing previous tag" do
    git("push", "origin", ":refs/tags/v0.1.0")
    git("tag", "-d", "v0.1.0")
    commit
    expect { @release.prepare("0.1.1", @artifacts) }.to raise_error(Release::Error)
  end

  it "promotes the prepared commit and tag atomically" do
    commit
    state = @release.prepare("0.1.1", @artifacts)
    @release.promote(@artifacts)
    expect(git("ls-remote", "origin", "refs/heads/main").split.first).to eq(state.fetch("release_sha"))
    expect(git("ls-remote", "origin", "refs/tags/v0.1.1").split.first).to eq(state.fetch("release_sha"))
  end

  it "rejects promotion after main advances without pushing the tag" do
    commit
    state = @release.prepare("0.1.1", @artifacts)
    other = File.join(@root, "other")
    git("clone", "--branch", "main", @origin, other)
    git("config", "user.name", "Other", directory: other)
    git("config", "user.email", "other@example.com", directory: other)
    File.write(File.join(other, "new"), "new")
    git("add", ".", directory: other)
    git("commit", "-m", "Advance main", directory: other)
    git("push", "origin", "main", directory: other)
    expect { @release.promote(@artifacts) }.to raise_error(Release::Error, /main advanced/)
    expect(git("ls-remote", "origin", "refs/tags/v0.1.1")).to eq("")
    expect(git("ls-remote", "origin", "refs/heads/main").split.first).not_to eq(state.fetch("release_sha"))
  end

  it "recovers the original tag after main advances" do
    commit
    state = @release.prepare("0.1.1", @artifacts)
    @release.promote(@artifacts)
    git("checkout", "-B", "main")
    commit("Later change")
    retry_dir = File.join(@root, "retry")
    retry_state = @release.prepare("0.1.1", retry_dir)
    expect(retry_state.fetch("retry")).to be(true)
    expect(retry_state.fetch("release_sha")).to eq(state.fetch("release_sha"))
    before = git("ls-remote", "origin", "refs/heads/main")
    @release.promote(retry_dir)
    expect(git("ls-remote", "origin", "refs/heads/main")).to eq(before)
  end
  it "rejects a previous release tag outside main's history" do
    git("checkout", "--orphan", "unrelated")
    git("commit", "-m", "Unrelated release")
    git("tag", "-f", "v0.1.0")
    git("push", "--force", "origin", "refs/tags/v0.1.0")
    git("checkout", "main")
    commit
    expect { @release.prepare("0.1.1", @artifacts) }.to raise_error(Release::Error)
  end

  it "does not promote when another release tag appears" do
    commit
    @release.prepare("0.1.1", @artifacts)
    git("push", "origin", "refs/tags/v0.1.0:refs/tags/v0.1.1")
    before = git("ls-remote", "origin", "refs/heads/main")
    expect { @release.promote(@artifacts) }.to raise_error(Release::Error, /tag already exists/)
    expect(git("ls-remote", "origin", "refs/heads/main")).to eq(before)
  end

  def build_gem(filename, text: "payload", date: "2026-11-08", dependency: ">= 3.12", version: "0.1.1")
    build = File.join(@root, "build-#{filename}")
    FileUtils.mkdir_p(build)
    File.write(File.join(build, "payload.rb"), text)
    specification = Gem::Specification.new do |spec|
      spec.name = "rspec-osc7501"
      spec.version = version
      spec.summary = "Test gem"
      spec.authors = ["Test"]
      spec.license = "Apache-2.0"
      spec.homepage = "https://example.com"
      spec.files = ["payload.rb"]
      spec.date = date
      spec.required_ruby_version = ">= 3.3"
      spec.add_dependency("rspec-core", dependency, "< 4")
    end
    path = File.join(@root, "#{filename}.gem")
    Gem::DefaultUserInteraction.use_ui(Gem::SilentUI.new) do
      Dir.chdir(build) { Gem::Package.build(specification, false, false, path) }
    end
    path
  end

  it "compares gem content and metadata while ignoring build dates" do
    first = build_gem("first")
    second = build_gem("second", date: "2026-11-09")
    expect { @release.verify_gem(first, second) }.not_to raise_error
  end

  [{ text: "changed" }, { dependency: ">= 3.13" }, { version: "0.1.2" }].each do |changes|
    it "rejects conflicting published gem #{changes.keys.first}" do
      first = build_gem("first")
      second = build_gem("second", **changes)
      expect { @release.verify_gem(first, second) }.to raise_error(Release::Error, /differs/)
    end
  end

  it "treats only HTTP 404 as an absent gem" do
    gem = build_gem("candidate")
    allow(@release).to receive(:http_get).and_return([404, "missing"])
    expect(@release.check_gem(gem)).to be(false)
    [401, 403, 429, 500].each do |status|
      allow(@release).to receive(:http_get).and_return([status, "failed"])
      expect { @release.check_gem(gem) }.to raise_error(Release::Error, /HTTP/)
    end
  end

  it "does not treat network failures as an absent gem" do
    gem = build_gem("candidate")
    allow(@release).to receive(:http_get).and_raise(Net::ReadTimeout)
    expect { @release.check_gem(gem) }.to raise_error(Net::ReadTimeout)
  end

  it "verifies a downloaded published gem" do
    gem = build_gem("candidate")
    remote = build_gem("remote", date: "2026-11-10")
    allow(@release).to receive(:http_get).and_return([200, "{}"], [200, File.binread(remote)])
    expect(@release.check_gem(gem)).to be(true)
  end

  it "checks GitHub release notes and target before accepting an existing release" do
    commit
    state = @release.prepare("0.1.1", @artifacts)
    notes = File.read(File.join(@artifacts, "notes.md"))
    existing = { "tag_name" => "v0.1.1", "target_commitish" => state.fetch("release_sha"),
                 "body" => notes, "draft" => false, "prerelease" => false }
    allow(@release).to receive(:github_release).and_return(nil)
    expect(@release.check_release("0.1.1", "v0.1.1", File.join(@artifacts, "notes.md"))).to be(false)
    allow(@release).to receive(:github_release).and_return(existing)
    expect(@release.check_release("0.1.1", "v0.1.1", File.join(@artifacts, "notes.md"))).to be(true)
    existing["body"] = "Wrong notes"
    expect { @release.check_release("0.1.1", "v0.1.1", File.join(@artifacts, "notes.md")) }.to raise_error(Release::Error, /GitHub release differs/)
  end

  it "distinguishes GitHub 404 from authorization and server failures" do
    allow(@release).to receive(:capture).and_return(["HTTP/2.0 404 Not Found\n\n{}", "", false])
    expect(@release.send(:github_release, "v0.1.1")).to be_nil
    [403, 500].each do |status|
      allow(@release).to receive(:capture).and_return(["HTTP/2.0 #{status} Error\n\n{}", "error", false])
      expect { @release.send(:github_release, "v0.1.1") }.to raise_error(Release::Error)
    end
  end

  it "rejects an existing gem without its release tag" do
    commit
    @release.prepare("0.1.1", @artifacts)
    gem = build_gem("candidate")
    allow(@release).to receive(:check_gem).and_return(true)
    expect { @release.publish(@artifacts, gem) }.to raise_error(Release::Error, /no matching release tag/)
    expect(git("ls-remote", "origin", "refs/tags/v0.1.1")).to eq("")
  end

  it "reports uncertain publication when the upload response fails" do
    commit
    @release.prepare("0.1.1", @artifacts)
    gem = build_gem("candidate")
    allow(@release).to receive(:check_gem).and_return(false)
    allow(@release).to receive(:check_release).and_return(false)
    allow(@release).to receive(:run).and_call_original
    allow(@release).to receive(:run).with("gem", "push", gem).and_raise(Release::Error, "upload response lost")
    expect { @release.publish(@artifacts, gem) }.to raise_error(Release::Error, /upload response lost/)
    summary = JSON.parse(File.read(File.join(@artifacts, "publication.json")))
    expect(summary).to include("rubygems" => "unknown", "github" => "incomplete")
  end

  it "recovers after gem publication succeeds and GitHub creation fails" do
    commit
    state = @release.prepare("0.1.1", @artifacts)
    gem = build_gem("candidate")
    published = false
    github_created = false
    uploads = 0
    allow(@release).to receive(:check_gem) { published }
    allow(@release).to receive(:check_release) { github_created }
    allow(@release).to receive(:run).and_call_original
    allow(@release).to receive(:run).with("gem", "push", gem) { uploads += 1; published = true }
    allow(@release).to receive(:create_release).and_raise(Release::Error, "GitHub unavailable")
    expect { @release.publish(@artifacts, gem) }.to raise_error(Release::Error, /GitHub unavailable/)
    summary = JSON.parse(File.read(File.join(@artifacts, "publication.json")))
    expect(summary).to include("rubygems" => "published", "github" => "incomplete")
    promoted = git("ls-remote", "origin", "refs/heads/main", "refs/tags/v0.1.1")
    retry_dir = File.join(@root, "retry")
    @release.prepare("0.1.1", retry_dir)
    allow(@release).to receive(:create_release) { github_created = true }
    @release.publish(retry_dir, gem)
    expect(uploads).to eq(1)
    expect(git("ls-remote", "origin", "refs/heads/main", "refs/tags/v0.1.1")).to eq(promoted)
    expect(JSON.parse(File.read(File.join(retry_dir, "publication.json")))).to include("rubygems" => "published", "github" => "published")
  end

end
