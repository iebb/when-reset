# Drop development identities that a previous hosted runner created and then
# discarded. Xcode automatic signing with an App Store Connect API key names
# that certificate "Apple Development: Created via API (<team id>)" and binds
# it to the runner image's machine identity. The private key never leaves the
# runner. The next archive stops with "Revoke certificate" and never creates
# development profiles, because -allowProvisioningUpdates will not revoke the
# certificate without an interactive prompt.
#
# Only those API-created development certificates are revoked. Personal
# development certificates and every distribution certificate stay in place.
# The matching Xcode-managed development team profiles are removed so the
# archive can create profiles that include the new certificate.

require "base64"
require "json"
require "net/http"
require "openssl"
require "uri"

module CiSigningHygiene
  API_ROOT = "https://api.appstoreconnect.apple.com"
  DEVELOPMENT_CERTIFICATE_TYPES = %w[DEVELOPMENT IOS_DEVELOPMENT MAC_APP_DEVELOPMENT].freeze
  DEVELOPMENT_PROFILE_TYPES = %w[IOS_APP_DEVELOPMENT MAC_APP_DEVELOPMENT].freeze
  PROFILE_NAME_PREFIXES = [
    "iOS Team Provisioning Profile: ",
    "Mac Team Provisioning Profile: "
  ].freeze
  # Codesign shows this exact subject. The parenthetical is the 10-character team id.
  API_CREATED_COMMON_NAME = /\A(?:Apple Development|iOS Development|iPhone Developer|Mac Developer): Created via API \([A-Z0-9]{10}\)\z/
  BUNDLE_ID = /\A[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]\z/
  RESOURCE_ID = /\A[A-Za-z0-9][A-Za-z0-9-]{0,127}\z/

  def self.bundle_ids(app_bundle_id, widget_bundle_id)
    ids = [app_bundle_id, widget_bundle_id].map { |value| value.to_s.strip }.uniq
    raise "App and widget bundle ids are required" if ids.any?(&:empty?)
    raise "Refusing an unexpected bundle id" if ids.any? { |value| !value.match?(BUNDLE_ID) || value.include?("..") }

    ids
  end

  def self.common_name(certificate_content)
    raise "Development certificate content is missing" if certificate_content.nil? || certificate_content.strip.empty?

    encoded = certificate_content.include?("BEGIN CERTIFICATE") ? certificate_content : Base64.decode64(certificate_content)
    certificate = OpenSSL::X509::Certificate.new(encoded)
    pair = certificate.subject.to_a.assoc("CN")
    name = pair && pair[1]
    raise "Development certificate has no common name" unless name.is_a?(String) && !name.empty?

    name
  rescue OpenSSL::X509::CertificateError, ArgumentError
    raise "Development certificate could not be classified"
  end

  def self.api_created_development_certificate?(certificate)
    attributes = certificate.fetch("attributes")
    return false unless DEVELOPMENT_CERTIFICATE_TYPES.include?(attributes["certificateType"])

    common_name(attributes["certificateContent"]).match?(API_CREATED_COMMON_NAME)
  end

  def self.managed_development_profile?(profile, bundle_ids)
    attributes = profile.fetch("attributes")
    return false unless DEVELOPMENT_PROFILE_TYPES.include?(attributes["profileType"])

    name = attributes["name"].to_s
    bundle_ids.any? { |bundle_id| PROFILE_NAME_PREFIXES.any? { |prefix| name == "#{prefix}#{bundle_id}" } }
  end

  def self.resource_path(collection, id)
    unless collection.is_a?(String) && collection.match?(/\A(?:certificates|profiles)\z/)
      raise "Refusing an unexpected App Store Connect collection"
    end
    raise "Refusing an unexpected App Store Connect resource id" unless id.is_a?(String) && id.match?(RESOURCE_ID)

    "/v1/#{collection}/#{id}"
  end

  def self.targets(certificates, profiles, bundle_ids)
    {
      certificates: certificates.select { |certificate| api_created_development_certificate?(certificate) }
        .map { |certificate| resource_path("certificates", certificate.fetch("id")) },
      profiles: profiles.select { |profile| managed_development_profile?(profile, bundle_ids) }
        .map { |profile| resource_path("profiles", profile.fetch("id")) }
    }
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

  def self.collect(path, fetch_page)
    rows = []
    seen = {}
    while path
      url = api_uri(path).to_s
      raise "App Store Connect returned a pagination loop" if seen[url]

      seen[url] = true
      page = fetch_page.call(url)
      rows.concat(page.fetch("data"))
      path = page.dig("links", "next")
    end
    rows
  end
end

def signing_required_env(name)
  value = ENV[name]
  raise "Required environment variable #{name} is missing" if value.nil? || value.empty?

  value
end

def signing_base64url(value)
  Base64.urlsafe_encode64(value, padding: false)
end

def signing_token_for(key_path, key_id, issuer_id)
  now = Time.now.to_i
  header = signing_base64url(JSON.generate(alg: "ES256", kid: key_id, typ: "JWT"))
  payload = signing_base64url(JSON.generate(
    iss: issuer_id,
    iat: now - 30,
    exp: now + 600,
    aud: "appstoreconnect-v1"
  ))
  signing_input = "#{header}.#{payload}"
  key = OpenSSL::PKey::EC.new(File.read(key_path))
  digest = OpenSSL::Digest::SHA256.digest(signing_input)
  sequence = OpenSSL::ASN1.decode(key.dsa_sign_asn1(digest))
  signature = [sequence.value.map { |part| part.value.to_i.to_s(16).rjust(64, "0") }.join].pack("H*")
  "#{signing_input}.#{signing_base64url(signature)}"
end

def signing_get_json(path, token)
  uri = CiSigningHygiene.api_uri(path)
  request = Net::HTTP::Get.new(uri)
  request["Authorization"] = "Bearer #{token}"
  response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 45) do |http|
    http.request(request)
  end
  raise "App Store Connect request failed with HTTP #{response.code}" unless response.code == "200"

  JSON.parse(response.body)
rescue JSON::ParserError
  raise "App Store Connect returned an unreadable response", cause: nil
end

def signing_delete(path, token)
  uri = CiSigningHygiene.api_uri(path)
  request = Net::HTTP::Delete.new(uri)
  request["Authorization"] = "Bearer #{token}"
  response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 45) do |http|
    http.request(request)
  end
  code = response.code.to_i
  return if [200, 204, 404].include?(code)
  if code == 403
    raise "App Store Connect refused to update CI signing assets (HTTP 403). The API key needs Admin access."
  end

  raise "App Store Connect request failed with HTTP #{code}"
end

if $PROGRAM_NAME == __FILE__
  key_path = signing_required_env("ASC_KEY_PATH")
  key_id = signing_required_env("ASC_KEY_ID")
  issuer_id = signing_required_env("ASC_ISSUER_ID")
  bundle_ids = CiSigningHygiene.bundle_ids(
    signing_required_env("APP_BUNDLE_IDENTIFIER"),
    signing_required_env("WIDGET_BUNDLE_IDENTIFIER")
  )
  token = signing_token_for(key_path, key_id, issuer_id)
  certificates = CiSigningHygiene::DEVELOPMENT_CERTIFICATE_TYPES.flat_map do |type|
    CiSigningHygiene.collect(
      "/v1/certificates?#{URI.encode_www_form("filter[certificateType]" => type, "limit" => "200")}",
      ->(url) { signing_get_json(url, token) }
    )
  end
  profiles = CiSigningHygiene::DEVELOPMENT_PROFILE_TYPES.flat_map do |type|
    CiSigningHygiene.collect(
      "/v1/profiles?#{URI.encode_www_form("filter[profileType]" => type, "limit" => "200")}",
      ->(url) { signing_get_json(url, token) }
    )
  end
  plan = CiSigningHygiene.targets(certificates, profiles, bundle_ids)
  plan.fetch(:certificates).each { |path| signing_delete(path, token) }
  plan.fetch(:profiles).each { |path| signing_delete(path, token) }
  puts "Revoked #{plan.fetch(:certificates).length} API-created development certificate(s)."
  puts "Removed #{plan.fetch(:profiles).length} Xcode-managed development team profile(s)."
  puts "Personal development certificates and distribution certificates were left in place."
end
