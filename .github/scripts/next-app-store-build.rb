require "base64"
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
  uri = URI("#{API_ROOT}#{path}")
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
end

key_path = required_env("ASC_KEY_PATH")
key_id = required_env("ASC_KEY_ID")
issuer_id = required_env("ASC_ISSUER_ID")
bundle_id = required_env("APP_BUNDLE_ID")
marketing_version = required_env("MARKETING_VERSION")
output_path = required_env("GITHUB_OUTPUT")
token = token_for(key_path, key_id, issuer_id)

apps = get_json(
  "/v1/apps?#{URI.encode_www_form("filter[bundleId]" => bundle_id, "limit" => "1")}",
  token
).fetch("data")
raise "No App Store Connect app matches #{bundle_id}" unless apps.length == 1

versions = get_json(
  "/v1/preReleaseVersions?#{URI.encode_www_form(
    "filter[app]" => apps.first.fetch("id"),
    "filter[version]" => marketing_version,
    "filter[platform]" => "IOS",
    "limit" => "20"
  )}",
  token
).fetch("data")

build_numbers = versions.flat_map do |version|
  get_json(
    "/v1/builds?#{URI.encode_www_form(
      "filter[preReleaseVersion]" => version.fetch("id"),
      "limit" => "200"
    )}",
    token
  ).fetch("data").filter_map do |build|
    value = build.dig("attributes", "version")
    Integer(value, exception: false)
  end
end

next_build = [build_numbers.max.to_i + 1, 1].max
File.open(output_path, "a") { |file| file.puts("build_number=#{next_build}") }
puts "Selected App Store build #{marketing_version} (#{next_build})."
