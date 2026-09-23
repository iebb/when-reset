require "minitest/autorun"
require "open3"
require "tmpdir"
require_relative "next-app-store-build"

class AppStoreReleaseSelectionTest < Minitest::Test
  def version(number, state, platform = "IOS", state_key = "appVersionState")
    { "attributes" => { "versionString" => number, state_key => state, "platform" => platform } }
  end

  def build(number)
    { "attributes" => { "version" => number } }
  end

  def select_version(requested, versions, platforms = ["IOS"])
    AppStoreReleaseSelection.marketing_version(requested, versions, platforms)
  end

  def test_approved_release_advances_to_an_uploadable_patch
    assert_equal "1.4.1", select_version("1.4", [version("1.4", "READY_FOR_DISTRIBUTION")])
    assert_equal "1.4.1", select_version("1.4", [version("1.4", "READY_FOR_SALE", "IOS", "appStoreState")])
    assert_equal "1.4.2", select_version("1.4", [version("1.4.1", "PENDING_DEVELOPER_RELEASE")])
  end

  def test_numeric_ordering_and_equivalent_versions
    releases = [version("1.9.9", "READY_FOR_DISTRIBUTION"), version("1.10", "READY_FOR_DISTRIBUTION")]
    assert_equal "1.10.1", select_version("1.4", releases)
    assert_equal "1.4.1", select_version("1.4.0", [version("1.4", "READY_FOR_DISTRIBUTION")])
    assert_equal "2.0", select_version("2.0", releases)
  end

  def test_open_release_and_initial_upload_keep_the_requested_version
    assert_equal "1.4", select_version("1.4", [])
    assert_equal "1.4", select_version("1.4", [version("1.4", "PREPARE_FOR_SUBMISSION")])
    assert_equal "1.4.1", select_version("1.4.1", [version("1.4", "READY_FOR_DISTRIBUTION")])
  end

  def test_only_selected_platforms_constrain_the_release
    releases = [version("1.4", "READY_FOR_DISTRIBUTION"), version("2.0", "READY_FOR_DISTRIBUTION", "MAC_OS")]
    assert_equal "1.4.1", select_version("1.4", releases)
    assert_equal "2.0.1", select_version("1.4", releases, ["MAC_OS"])
    assert_equal "2.0.1", select_version("1.4", releases, %w[IOS MAC_OS])
  end

  def test_current_state_takes_precedence_over_legacy_state
    release = version("1.4", "READY_FOR_DISTRIBUTION")
    release["attributes"]["appStoreState"] = "PREPARE_FOR_SUBMISSION"
    assert_equal "1.4.1", select_version("1.4", [release])
  end

  def test_build_number_exceeds_all_marketing_versions_and_dotted_builds
    assert_equal 1, AppStoreReleaseSelection.build_number([])
    assert_equal 27, AppStoreReleaseSelection.build_number([build("2"), build("26"), build("1")])
    assert_equal 28, AppStoreReleaseSelection.build_number([build("27.9.3"), build("26")])
  end

  def test_untrusted_version_values_are_rejected_without_echoing_them
    ["bad-value-canary", "1.2.3.4", "1.4\nother=value", "", nil].each do |value|
      error = assert_raises(RuntimeError) { select_version(value, []) }
      assert_equal "Invalid numeric app version", error.message
    end
  end

  def test_pagination_includes_later_builds
    requests = []
    fetch_page = lambda do |url, token|
      requests << [url, token]
      if requests.length == 1
        { "data" => [build("1")], "links" => { "next" => "#{API_ROOT}/v1/builds?cursor=next" } }
      else
        { "data" => [build("26")], "links" => { "next" => nil } }
      end
    end
    builds = get_all("/v1/builds?limit=1", "test-token", fetch_page: fetch_page)
    assert_equal 27, AppStoreReleaseSelection.build_number(builds)
    assert_equal [["#{API_ROOT}/v1/builds?limit=1", "test-token"], ["#{API_ROOT}/v1/builds?cursor=next", "test-token"]], requests
  end

  def test_pagination_never_sends_authorization_to_an_unexpected_origin
    ["https://example.invalid/v1/builds", "http://api.appstoreconnect.apple.com/v1/builds",
     "https://api.appstoreconnect.apple.com:444/v1/builds", "https://canary@api.appstoreconnect.apple.com/v1/builds",
     "https://api.appstoreconnect.apple.com/not-the-api", "malformed URL canary"].each do |next_url|
      requests = []
      fetch_page = lambda do |url, _token|
        requests << url
        { "data" => [], "links" => { "next" => next_url } }
      end
      error = assert_raises(RuntimeError) { get_all("/v1/builds", "test-token", fetch_page: fetch_page) }
      assert_equal "Refusing an unexpected App Store Connect pagination URL", error.message
      assert_equal ["#{API_ROOT}/v1/builds"], requests
    end
  end

  def test_pagination_loop_is_detected
    requests = 0
    fetch_page = lambda do |_url, _token|
      requests += 1
      { "data" => [], "links" => { "next" => "/v1/builds" } }
    end
    error = assert_raises(RuntimeError) { get_all("/v1/builds", "test-token", fetch_page: fetch_page) }
    assert_equal "App Store Connect returned a pagination loop", error.message
    assert_equal 1, requests
  end

  def test_unreadable_api_responses_do_not_disclose_the_body
    response = Struct.new(:code, :body).new("200", "private-response-body-canary")
    Net::HTTP.stub(:start, ->(*_args, &_block) { response }) do
      error = assert_raises(RuntimeError) { get_json("/v1/builds", "test-token") }
      assert_equal "App Store Connect returned an unreadable response", error.message
      assert_nil error.cause
    end
  end
end

class AppStoreExportTest < Minitest::Test
  TRANSIENT = <<~LOG.freeze
    error: exportArchive The data couldn't be read because it isn't in the correct format.
    error: exportArchive No signing certificate "iOS Distribution" found
  LOG
  SCRIPT = File.expand_path("export-app-store.sh", __dir__)
  PRIVATE_DIAGNOSTIC = "private-diagnostic-canary"

  def export(responses)
    Dir.mktmpdir("app-store-export-test") do |directory|
      binary = File.join(directory, "xcodebuild")
      File.write(binary, <<~'RUBY')
        #!/usr/bin/env ruby
        require "json"
        calls_path = ENV.fetch("FAKE_CALLS_PATH")
        calls = File.exist?(calls_path) ? File.readlines(calls_path) : []
        File.open(calls_path, "a") { |file| file.puts(JSON.generate(ARGV)) }
        response = JSON.parse(ENV.fetch("FAKE_RESPONSES")).fetch(calls.length)
        puts "private-diagnostic-canary"
        puts response.fetch("log", "")
        exit response.fetch("status")
      RUBY
      File.chmod(0o700, binary)
      File.write(File.join(directory, "sleep"), "#!/bin/sh\nexit 0\n")
      File.chmod(0o700, File.join(directory, "sleep"))
      private_logs = File.join(directory, "logs")
      Dir.mkdir(private_logs)
      env = {
        "PATH" => "#{directory}:#{ENV.fetch('PATH')}",
        "TMPDIR" => "#{private_logs}/",
        "ASC_KEY_PATH" => File.join(directory, "synthetic-key.p8"),
        "ASC_KEY_ID" => "synthetic-key-id",
        "ASC_ISSUER_ID" => "synthetic-issuer-id",
        "FAKE_CALLS_PATH" => File.join(directory, "calls.jsonl"),
        "FAKE_RESPONSES" => JSON.generate(responses)
      }
      stdout, stderr, status = Open3.capture3(env, "bash", SCRIPT, "archive with spaces", "export directory", "options.plist")
      calls = File.readlines(env.fetch("FAKE_CALLS_PATH")).map { |line| JSON.parse(line) }
      refute_includes stdout + stderr, PRIVATE_DIAGNOSTIC
      refute_includes stdout + stderr, env.fetch("ASC_KEY_PATH")
      assert_empty Dir.children(private_logs), "Private logs must be removed on success and failure"
      yield status.exitstatus, stdout + stderr, calls
    end
  end

  def test_success_does_not_retry
    export([{ status: 0 }]) do |status, output, calls|
      assert_equal 0, status
      assert_includes output, "upload succeeded"
      assert_equal 1, calls.length
      assert_equal "archive with spaces", calls.first[calls.first.index("-archivePath") + 1]
    end
  end

  def test_known_pre_upload_signing_failure_is_retried
    export([{ status: 70, log: TRANSIENT }, { status: 0 }]) do |status, output, calls|
      assert_equal 0, status
      assert_includes output, "retrying before any upload"
      assert_equal ["export directory/attempt-1", "export directory/attempt-2"], calls.map { |args| args[args.index("-exportPath") + 1] }
    end
  end

  def test_signing_retries_are_bounded
    export(Array.new(3) { { status: 70, log: TRANSIENT } }) do |status, output, calls|
      assert_equal 70, status
      assert_includes output, "failed after three attempts"
      assert_equal 3, calls.length
    end
  end

  def test_closed_train_is_not_retried
    export([{ status: 70, log: "#{TRANSIENT}\nerror: exportArchive Invalid Pre-Release Train" }]) do |status, output, calls|
      assert_equal 70, status
      assert_includes output, "Apple rejected"
      assert_equal 1, calls.length
    end
  end

  def test_an_upload_that_might_have_reached_apple_is_not_retried
    export([{ status: 70, log: "#{TRANSIENT}\nProgress 50%: Uploading" }]) do |status, _output, calls|
      assert_equal 70, status
      assert_equal 1, calls.length
    end
  end

  def test_missing_certificate_alone_is_not_assumed_transient
    export([{ status: 70, log: 'error: exportArchive No signing certificate "iOS Distribution" found' }]) do |status, _output, calls|
      assert_equal 70, status
      assert_equal 1, calls.length
    end
  end

  def test_unrelated_failure_is_not_retried
    export([{ status: 65, log: TRANSIENT }]) do |status, _output, calls|
      assert_equal 65, status
      assert_equal 1, calls.length
    end
  end
end
