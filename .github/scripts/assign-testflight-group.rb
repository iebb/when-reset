require "base64"
require "cgi"
require "json"
require "net/http"
require "openssl"
require "uri"

API_ROOT = "https://api.appstoreconnect.apple.com"

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
  request_class = method == :post ? Net::HTTP::Post : Net::HTTP::Get
  request = request_class.new(uri)
  request["Authorization"] = "Bearer #{token_provider.call}"
  request["Content-Type"] = "application/json" if body
  request.body = JSON.generate(body) if body
  response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 45) do |http|
    http.request(request)
  end

  unless response.code.to_i.between?(200, 299)
    raise "App Store Connect request failed with HTTP #{response.code}"
  end

  response.body.nil? || response.body.empty? ? {} : JSON.parse(response.body)
end

key_path = required_env("ASC_KEY_PATH")
key_id = required_env("ASC_KEY_ID")
issuer_id = required_env("ASC_ISSUER_ID")
bundle_id = required_env("APP_BUNDLE_ID")
marketing_version = required_env("MARKETING_VERSION")
build_number = required_env("BUILD_NUMBER")
group_name = required_env("TESTFLIGHT_GROUP_NAME")
timeout_seconds = Integer(ENV.fetch("TESTFLIGHT_PROCESSING_TIMEOUT_SECONDS", "2700"))
poll_seconds = Integer(ENV.fetch("TESTFLIGHT_POLL_SECONDS", "30"))
dry_run = ENV["TESTFLIGHT_DRY_RUN"] == "1"
token = lambda { token_for(key_path, key_id, issuer_id) }

apps = request_json(
  :get,
  api_path("/v1/apps", { "filter[bundleId]" => bundle_id, "limit" => "1" }),
  token
).fetch("data")
raise "No App Store Connect app matches #{bundle_id}" unless apps.length == 1

app_id = apps.first.fetch("id")
groups = request_json(
  :get,
  api_path("/v1/betaGroups", { "filter[app]" => app_id, "limit" => "200" }),
  token
).fetch("data")
group = groups.find do |candidate|
  attributes = candidate.fetch("attributes")
  attributes["name"] == group_name && attributes["isInternalGroup"] == true
end
raise "Internal TestFlight group #{group_name.inspect} was not found" unless group

deadline = Time.now + timeout_seconds
build = nil

loop do
  versions = request_json(
    :get,
    api_path(
      "/v1/preReleaseVersions",
      {
        "filter[app]" => app_id,
        "filter[version]" => marketing_version,
        "filter[platform]" => "IOS",
        "limit" => "20"
      }
    ),
    token
  ).fetch("data")

  builds = versions.flat_map do |version|
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
  end
  build = builds.find { |candidate| candidate.dig("attributes", "version") == build_number }

  if build
    processing_state = build.dig("attributes", "processingState")
    raise "TestFlight build #{build_number} entered processing state #{processing_state}" if processing_state == "INVALID"

    details = request_json(
      :get,
      api_path("/v1/buildBetaDetails", { "filter[build]" => build.fetch("id"), "limit" => "1" }),
      token
    ).fetch("data").first
    internal_state = details&.dig("attributes", "internalBuildState")
    break if processing_state == "VALID" && ["READY_FOR_BETA_TESTING", "IN_BETA_TESTING"].include?(internal_state)
  end

  raise "Timed out waiting for TestFlight build #{marketing_version} (#{build_number})" if Time.now >= deadline

  puts "Waiting for Apple to process TestFlight build #{marketing_version} (#{build_number})..."
  sleep poll_seconds
end

build_id = build.fetch("id")
group_builds = request_json(:get, "/v1/betaGroups/#{group.fetch("id")}/builds?limit=200", token).fetch("data")
already_assigned = group_builds.any? { |candidate| candidate.fetch("id") == build_id }

unless already_assigned || dry_run
  request_json(
    :post,
    "/v1/betaGroups/#{group.fetch("id")}/relationships/builds",
    token,
    { data: [{ type: "builds", id: build_id }] }
  )
end

if dry_run
  puts "Verified TestFlight build #{marketing_version} (#{build_number}) is ready for #{group_name}."
elsif already_assigned
  puts "TestFlight build #{marketing_version} (#{build_number}) is already assigned to #{group_name}."
else
  group_builds = request_json(:get, "/v1/betaGroups/#{group.fetch("id")}/builds?limit=200", token).fetch("data")
  unless group_builds.any? { |candidate| candidate.fetch("id") == build_id }
    raise "TestFlight group assignment could not be verified"
  end
  puts "Assigned TestFlight build #{marketing_version} (#{build_number}) to #{group_name}."
end
