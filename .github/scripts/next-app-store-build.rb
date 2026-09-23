require "base64"
require "json"
require "net/http"
require "openssl"
require "uri"

API_ROOT = "https://api.appstoreconnect.apple.com"

module AppStoreReleaseSelection
  # A reviewed/approved release can no longer accept another build in that train.
  # Include both current and legacy App Store Connect state names.
  CLOSED_STATES = %w[
    ACCEPTED PENDING_APPLE_RELEASE PENDING_DEVELOPER_RELEASE PENDING_CONTRACT
    PROCESSING_FOR_DISTRIBUTION PROCESSING_FOR_APP_STORE READY_FOR_DISTRIBUTION
    READY_FOR_SALE PREORDER_READY_FOR_SALE REPLACED_WITH_NEW_VERSION
    DEVELOPER_REMOVED_FROM_SALE REMOVED_FROM_SALE
  ].freeze

  def self.version_parts(value)
    raise "Invalid numeric app version" unless value.is_a?(String) && value.match?(/\A\d+(?:\.\d+){0,2}\z/)

    value.split(".").map(&:to_i).fill(0, value.split(".").length...3)
  end

  def self.marketing_version(requested, versions, platforms)
    floor = version_parts(requested)
    closed = versions.select do |version|
      attributes = version.fetch("attributes")
      platforms.include?(attributes["platform"]) &&
        CLOSED_STATES.include?(attributes["appVersionState"] || attributes["appStoreState"])
    end.map { |version| version_parts(version.fetch("attributes").fetch("versionString")) }.max
    return requested unless closed && (floor <=> closed) <= 0

    [closed[0], closed[1], closed[2] + 1].join(".")
  end

  def self.build_number(builds)
    # macOS requires increasing build numbers across marketing versions. Query
    # every app build and choose an integer above even a previous dotted build.
    maximum = builds.map { |build| version_parts(build.fetch("attributes").fetch("version")).first }.max
    (maximum || 0) + 1
  end

  def self.api_uri(path)
    uri = URI.join(API_ROOT, path)
    unless uri.scheme == "https" && uri.host == "api.appstoreconnect.apple.com" &&
        uri.port == 443 && uri.userinfo.nil? && uri.path.start_with?("/v1/")
      raise "Refusing an unexpected App Store Connect pagination URL"
    end
    uri
  rescue URI::InvalidURIError, ArgumentError
    raise "Refusing an unexpected App Store Connect pagination URL", cause: nil
  end
end

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
  payload = base64url(JSON.generate(
    iss: issuer_id,
    iat: now - 30,
    exp: now + 600,
    aud: "appstoreconnect-v1"
  ))
  signing_input = "#{header}.#{payload}"
  key = OpenSSL::PKey::EC.new(File.read(key_path))
  "#{signing_input}.#{base64url(jose_signature(key, signing_input))}"
end

def get_json(path, token)
  uri = AppStoreReleaseSelection.api_uri(path)
  request = Net::HTTP::Get.new(uri)
  request["Authorization"] = "Bearer #{token}"
  response = Net::HTTP.start(
    uri.host,
    uri.port,
    use_ssl: true,
    open_timeout: 15,
    read_timeout: 45
  ) { |http| http.request(request) }
  raise "App Store Connect request failed with HTTP #{response.code}" unless response.code == "200"

  JSON.parse(response.body)
rescue JSON::ParserError
  raise "App Store Connect returned an unreadable response", cause: nil
end

def get_all(path, token, fetch_page: method(:get_json))
  rows = []
  seen = {}
  while path
    url = AppStoreReleaseSelection.api_uri(path).to_s
    raise "App Store Connect returned a pagination loop" if seen[url]

    seen[url] = true
    page = fetch_page.call(url, token)
    rows.concat(page.fetch("data"))
    path = page.dig("links", "next")
  end
  rows
end

if $PROGRAM_NAME == __FILE__
  key_path = required_env("ASC_KEY_PATH")
  key_id = required_env("ASC_KEY_ID")
  issuer_id = required_env("ASC_ISSUER_ID")
  bundle_id = required_env("APP_BUNDLE_ID")
  requested_version = required_env("MARKETING_VERSION")
  output_path = required_env("GITHUB_OUTPUT")
  platforms = ENV.fetch("RELEASE_PLATFORMS", "IOS").split(",")
  raise "Unsupported release platform" if platforms.empty? || (platforms - %w[IOS MAC_OS]).any?

  token = token_for(key_path, key_id, issuer_id)
  apps = get_all(
    "/v1/apps?#{URI.encode_www_form("filter[bundleId]" => bundle_id, "limit" => "1")}", token
  )
  raise "No App Store Connect app matches the configured bundle ID" unless apps.length == 1

  app_id = apps.first.fetch("id")
  versions = get_all("/v1/apps/#{app_id}/appStoreVersions?limit=200", token)
  marketing_version = AppStoreReleaseSelection.marketing_version(requested_version, versions, platforms)
  builds = get_all(
    "/v1/builds?#{URI.encode_www_form(
      "filter[app]" => app_id,
      "limit" => "200"
    )}", token
  )
  next_build = AppStoreReleaseSelection.build_number(builds)
  File.open(output_path, "a") do |file|
    file.puts("marketing_version=#{marketing_version}")
    file.puts("build_number=#{next_build}")
  end
  puts "Selected App Store build #{marketing_version} (#{next_build})."
  puts "The configured version is already approved; using the next patch version." if marketing_version != requested_version
end
