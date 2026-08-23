require "base64"
require "json"
require "net/http"
require "openssl"
require "uri"

API_ROOT = "https://api.appstoreconnect.apple.com"

# An App Store version can only be edited while Apple has not taken it into review.
EDITABLE_VERSION_STATES = [
  "PREPARE_FOR_SUBMISSION",
  "DEVELOPER_REJECTED",
  "REJECTED",
  "METADATA_REJECTED",
  "INVALID_BINARY"
].freeze

# A review submission that Apple already accepted must not be reopened or duplicated.
CLOSED_SUBMISSION_STATES = %w[COMPLETE COMPLETING CANCELING].freeze

def required_env(name)
  value = ENV[name]
  raise "Required environment variable #{name} is missing" if value.nil? || value.empty?

  value
end

def base64url(value)
  Base64.urlsafe_encode64(value, padding: false)
end

def jose_signature(key, signing_input)
  digest = OpenSSL::Digest::SHA256.digest(signing_input)
  sequence = OpenSSL::ASN1.decode(key.dsa_sign_asn1(digest))
  integers = sequence.value.map { |part| part.value.to_i.to_s(16).rjust(64, "0") }
  [integers.join].pack("H*")
end

def token_for(key_path, key_id, issuer_id)
  now = Time.now.to_i
  header = base64url(JSON.generate(alg: "ES256", kid: key_id, typ: "JWT"))
  payload = base64url(JSON.generate(iss: issuer_id, iat: now - 30, exp: now + 600, aud: "appstoreconnect-v1"))
  signing_input = "#{header}.#{payload}"
  key = OpenSSL::PKey::EC.new(File.read(key_path))
  "#{signing_input}.#{base64url(jose_signature(key, signing_input))}"
end

def api_path(path, parameters = nil)
  return path if parameters.nil? || parameters.empty?

  "#{path}?#{URI.encode_www_form(parameters)}"
end

def request_json(method, path, token_provider, body = nil)
  uri = URI("#{API_ROOT}#{path}")
  request_class = {
    get: Net::HTTP::Get,
    post: Net::HTTP::Post,
    patch: Net::HTTP::Patch
  }.fetch(method)
  request = request_class.new(uri)
  request["Authorization"] = "Bearer #{token_provider.call}"
  request["Content-Type"] = "application/json" if body
  request.body = JSON.generate(body) if body
  response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 45) do |http|
    http.request(request)
  end

  unless response.code.to_i.between?(200, 299)
    detail = begin
      JSON.parse(response.body).fetch("errors", []).map { |error| error["detail"] || error["title"] }.compact.join("; ")
    rescue StandardError
      ""
    end
    raise "App Store Connect #{method.upcase} #{path} failed with HTTP #{response.code}#{detail.empty? ? "" : ": #{detail}"}"
  end

  response.body.nil? || response.body.empty? ? {} : JSON.parse(response.body)
end

def version_state(version)
  version.dig("attributes", "appVersionState") || version.dig("attributes", "appStoreState")
end

# Apple keeps a build in PROCESSING for a while after upload. Nothing can be attached to a
# version until it turns VALID, so wait rather than failing the release.
def await_valid_build(token, app_id, marketing_version, build_number, platform, deadline, poll_seconds)
  loop do
    versions = request_json(
      :get,
      api_path(
        "/v1/preReleaseVersions",
        {
          "filter[app]" => app_id,
          "filter[version]" => marketing_version,
          "filter[platform]" => platform,
          "limit" => "20"
        }
      ),
      token
    ).fetch("data")

    build = versions.flat_map do |version|
      request_json(
        :get,
        api_path(
          "/v1/builds",
          {
            "filter[preReleaseVersion]" => version.fetch("id"),
            "filter[version]" => build_number,
            "limit" => "20"
          }
        ),
        token
      ).fetch("data")
    end.find { |candidate| candidate.dig("attributes", "version") == build_number }

    if build
      state = build.dig("attributes", "processingState")
      raise "Build #{marketing_version} (#{build_number}) for #{platform} is #{state}" if state == "INVALID"
      return build if state == "VALID"
    end

    if Time.now >= deadline
      raise "Timed out waiting for #{platform} build #{marketing_version} (#{build_number}) to finish processing"
    end

    puts "Waiting for Apple to finish processing #{platform} build #{marketing_version} (#{build_number})..."
    sleep poll_seconds
  end
end

def find_or_create_version(token, app_id, marketing_version, platform, dry_run)
  existing = request_json(
    :get,
    api_path(
      "/v1/apps/#{app_id}/appStoreVersions",
      {
        "filter[versionString]" => marketing_version,
        "filter[platform]" => platform,
        "limit" => "10"
      }
    ),
    token
  ).fetch("data").first

  if existing
    state = version_state(existing)
    unless EDITABLE_VERSION_STATES.include?(state)
      raise "App Store version #{marketing_version} for #{platform} is #{state} and can no longer be edited"
    end

    puts "Reusing #{platform} App Store version #{marketing_version} (#{state})."
    return existing
  end

  if dry_run
    puts "Would create #{platform} App Store version #{marketing_version}."
    return nil
  end

  created = request_json(
    :post,
    "/v1/appStoreVersions",
    token,
    {
      data: {
        type: "appStoreVersions",
        attributes: {
          platform: platform,
          versionString: marketing_version,
          releaseType: "AFTER_APPROVAL"
        },
        relationships: { app: { data: { type: "apps", id: app_id } } }
      }
    }
  ).fetch("data")
  puts "Created #{platform} App Store version #{marketing_version}."
  created
end

# "What's New" is rejected outright on an app's very first App Store version.
def app_has_released_version?(token, app_id, platform)
  request_json(
    :get,
    api_path(
      "/v1/apps/#{app_id}/appStoreVersions",
      { "filter[platform]" => platform, "limit" => "50" }
    ),
    token
  ).fetch("data").any? do |version|
    %w[READY_FOR_DISTRIBUTION READY_FOR_SALE].include?(version_state(version))
  end
end

def apply_release_notes(token, version_id, release_notes, dry_run)
  localizations = request_json(
    :get,
    "/v1/appStoreVersions/#{version_id}/appStoreVersionLocalizations?limit=50",
    token
  ).fetch("data")
  raise "App Store version #{version_id} has no localizations" if localizations.empty?

  localizations.each do |localization|
    locale = localization.dig("attributes", "locale")
    if dry_run
      puts "Would set release notes for #{locale}."
      next
    end

    request_json(
      :patch,
      "/v1/appStoreVersionLocalizations/#{localization.fetch("id")}",
      token,
      {
        data: {
          type: "appStoreVersionLocalizations",
          id: localization.fetch("id"),
          attributes: { whatsNew: release_notes }
        }
      }
    )
    puts "Set release notes for #{locale}."
  end
end

def attach_build(token, version_id, build_id, dry_run)
  current = request_json(:get, "/v1/appStoreVersions/#{version_id}/relationships/build", token).fetch("data", nil)
  if current && current.fetch("id") == build_id
    puts "Build is already attached to the version."
    return
  end

  if dry_run
    puts "Would attach build #{build_id} to the version."
    return
  end

  request_json(
    :patch,
    "/v1/appStoreVersions/#{version_id}/relationships/build",
    token,
    { data: { type: "builds", id: build_id } }
  )
  attached = request_json(:get, "/v1/appStoreVersions/#{version_id}/relationships/build", token).fetch("data", nil)
  raise "Build could not be attached to the App Store version" unless attached && attached.fetch("id") == build_id

  puts "Attached the build to the version."
end

def submit_for_review(token, app_id, version_id, platform, dry_run)
  open_submission = request_json(
    :get,
    api_path("/v1/reviewSubmissions", { "filter[app]" => app_id, "filter[platform]" => platform, "limit" => "50" }),
    token
  ).fetch("data").reject { |submission| CLOSED_SUBMISSION_STATES.include?(submission.dig("attributes", "state")) }.first

  if open_submission && open_submission.dig("attributes", "submitted") == true
    puts "A #{platform} review submission is already with Apple (#{open_submission.dig("attributes", "state")}); nothing to do."
    return
  end

  if dry_run
    puts "Would submit the #{platform} version for review."
    return
  end

  submission = open_submission || request_json(
    :post,
    "/v1/reviewSubmissions",
    token,
    {
      data: {
        type: "reviewSubmissions",
        attributes: { platform: platform },
        relationships: { app: { data: { type: "apps", id: app_id } } }
      }
    }
  ).fetch("data")
  submission_id = submission.fetch("id")

  items = request_json(:get, "/v1/reviewSubmissions/#{submission_id}/items?limit=50", token).fetch("data")
  already_included = items.any? do |item|
    request_json(
      :get,
      "/v1/reviewSubmissionItems/#{item.fetch("id")}/appStoreVersion",
      token
    ).fetch("data", nil)&.fetch("id", nil) == version_id
  rescue StandardError
    false
  end

  unless already_included
    request_json(
      :post,
      "/v1/reviewSubmissionItems",
      token,
      {
        data: {
          type: "reviewSubmissionItems",
          relationships: {
            reviewSubmission: { data: { type: "reviewSubmissions", id: submission_id } },
            appStoreVersion: { data: { type: "appStoreVersions", id: version_id } }
          }
        }
      }
    )
    puts "Added the version to review submission #{submission_id}."
  end

  request_json(
    :patch,
    "/v1/reviewSubmissions/#{submission_id}",
    token,
    { data: { type: "reviewSubmissions", id: submission_id, attributes: { submitted: true } } }
  )
  puts "Submitted #{platform} for App Store review."
end

key_path = required_env("ASC_KEY_PATH")
key_id = required_env("ASC_KEY_ID")
issuer_id = required_env("ASC_ISSUER_ID")
bundle_id = required_env("APP_BUNDLE_ID")
marketing_version = required_env("MARKETING_VERSION")
build_number = required_env("BUILD_NUMBER")
release_notes = ENV["RELEASE_NOTES"].to_s.strip
platforms = required_env("REVIEW_PLATFORMS").split(",").map { |value| value.strip.upcase }.reject(&:empty?)
timeout_seconds = Integer(ENV.fetch("REVIEW_PROCESSING_TIMEOUT_SECONDS", "3600"))
poll_seconds = Integer(ENV.fetch("REVIEW_POLL_SECONDS", "60"))
dry_run = ENV["REVIEW_DRY_RUN"] == "1"
token = lambda { token_for(key_path, key_id, issuer_id) }

apps = request_json(:get, api_path("/v1/apps", { "filter[bundleId]" => bundle_id, "limit" => "1" }), token).fetch("data")
raise "No App Store Connect app matches #{bundle_id}" unless apps.length == 1

app_id = apps.first.fetch("id")
deadline = Time.now + timeout_seconds

platforms.each do |platform|
  puts "== #{platform} =="
  build = await_valid_build(token, app_id, marketing_version, build_number, platform, deadline, poll_seconds)
  version = find_or_create_version(token, app_id, marketing_version, platform, dry_run)
  next if version.nil?

  version_id = version.fetch("id")
  if release_notes.empty?
    puts "No release notes supplied; leaving existing text unchanged."
  elsif app_has_released_version?(token, app_id, platform)
    apply_release_notes(token, version_id, release_notes, dry_run)
  else
    puts "Skipping release notes: Apple rejects them on a first App Store version."
  end

  attach_build(token, version_id, build.fetch("id"), dry_run)
  submit_for_review(token, app_id, version_id, platform, dry_run)
end

puts dry_run ? "Dry run finished; nothing was submitted." : "Review submission finished."
