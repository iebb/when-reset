# frozen_string_literal: true

require "base64"
require "json"
require "net/http"
require "openssl"
require "uri"

STDOUT.sync = true
API_ROOT = "https://api.appstoreconnect.apple.com"
EMAIL = ENV.fetch("BETA_TESTER_EMAIL", "sharkchili.su@gmail.com")
BUNDLE_ID = ENV.fetch("APP_BUNDLE_ID", "com.harrisliangsu.whenreset")
INTERNAL_GROUP = ENV.fetch("TESTFLIGHT_GROUP_NAME", "Internal Testers")
EXTERNAL_GROUP = ENV.fetch("EXTERNAL_GROUP_NAME", "External Testers")
MARKETING_VERSION = ENV.fetch("MARKETING_VERSION", "1.8")
BUILD_NUMBER = ENV.fetch("BUILD_NUMBER", "2")

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

def request_json(method, path, token, body = nil)
  uri = URI("#{API_ROOT}#{path}")
  request_class = { get: Net::HTTP::Get, post: Net::HTTP::Post, delete: Net::HTTP::Delete, patch: Net::HTTP::Patch }.fetch(method)
  request = request_class.new(uri)
  request["Authorization"] = "Bearer #{token}"
  request["Content-Type"] = "application/json" if body
  request.body = JSON.generate(body) if body
  response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 60) do |http|
    http.request(request)
  end
  parsed = response.body.nil? || response.body.empty? ? {} : JSON.parse(response.body)
  [response.code.to_i, parsed]
rescue JSON::ParserError
  [response.code.to_i, { "raw" => response.body.to_s[0, 500] }]
end

def api_path(path, parameters = nil)
  return path if parameters.nil? || parameters.empty?

  "#{path}?#{URI.encode_www_form(parameters)}"
end

def expect(code, parsed, what)
  return parsed if code.between?(200, 299)

  raise "#{what} failed with HTTP #{code}: #{error_text(parsed)}"
end

def error_text(parsed)
  parsed.dig("errors")&.map { |error| [error["title"], error["detail"]].compact.join(": ") }&.join("; ") || parsed.to_s
end

OLD_TESTER_ID = "7a36386a-35b4-4a58-8feb-6136ba3bd2b8"
QQ_HITS = []

def qq_email?(value)
  value.to_s.downcase.end_with?("@qq.com")
end

def remember_qq(value, path)
  return unless value.is_a?(String) && value.downcase.include?("qq")

  hit = "#{path}=#{value}"
  QQ_HITS << hit
  puts "QQ_HIT #{hit}"
end

def walk_qq(value, path)
  case value
  when Hash
    value.each { |key, child| walk_qq(child, "#{path}.#{key}") }
  when Array
    value.each_with_index { |child, index| walk_qq(child, "#{path}[#{index}]") }
  else
    remember_qq(value.to_s, path) if value.is_a?(String)
  end
end

def dump(label, code, body)
  puts "---- #{label} HTTP #{code} ----"
  puts JSON.pretty_generate(body)
  walk_qq(body, label)
end

def urls_in(value, found = [])
  case value
  when Hash
    value.each_value { |child| urls_in(child, found) }
  when Array
    value.each { |child| urls_in(child, found) }
  when String
    found << value if value.include?("http://") || value.include?("https://")
  end
  found
end

def find_ios_build(token, app_id)
  versions = expect(
    *request_json(
      :get,
      api_path("/v1/preReleaseVersions", { "filter[app]" => app_id, "filter[version]" => MARKETING_VERSION, "filter[platform]" => "IOS", "limit" => "20" }),
      token
    ),
    "List prerelease versions"
  ).fetch("data")
  versions.each do |version|
    builds = expect(
      *request_json(:get, api_path("/v1/builds", { "filter[preReleaseVersion]" => version.fetch("id"), "filter[version]" => BUILD_NUMBER, "limit" => "20" }), token),
      "List builds"
    ).fetch("data")
    found = builds.find { |build| build.dig("attributes", "version") == BUILD_NUMBER }
    return found if found
  end
  nil
end

def ensure_external_group(token, app_id, groups)
  external = groups.find { |group| group.dig("attributes", "name") == EXTERNAL_GROUP && group.dig("attributes", "isInternalGroup") == false }
  return external if external

  code, body = request_json(
    :post,
    "/v1/betaGroups",
    token,
    {
      data: {
        type: "betaGroups",
        attributes: { name: EXTERNAL_GROUP, isInternalGroup: false, publicLinkEnabled: false, feedbackEnabled: true },
        relationships: { app: { data: { type: "apps", id: app_id } } }
      }
    }
  )
  created = expect(code, body, "Create external group").fetch("data")
  puts "CREATED_EXTERNAL_GROUP id=#{created.fetch("id")}"
  created
end

def assign_build_to_group(token, group_id, build)
  code, body = request_json(
    :post,
    "/v1/betaGroups/#{group_id}/relationships/builds",
    token,
    { data: [{ type: "builds", id: build.fetch("id") }] }
  )
  puts "ASSIGN_BUILD HTTP #{code} #{error_text(body) unless code.between?(200, 299) || code == 409}"
  code
end

def ensure_export_compliance(token, build)
  return build unless build.dig("attributes", "usesNonExemptEncryption").nil?

  code, body = request_json(
    :patch,
    "/v1/builds/#{build.fetch("id")}",
    token,
    { data: { type: "builds", id: build.fetch("id"), attributes: { usesNonExemptEncryption: false } } }
  )
  puts "EXPORT_COMPLIANCE HTTP #{code} #{error_text(body) unless code.between?(200, 299)}"
  code.between?(200, 299) ? body.fetch("data") : build
end

def ensure_beta_description(token, app_id)
  code, body = request_json(:get, "/v1/apps/#{app_id}/betaAppLocalizations?limit=20", token)
  puts "BETA_APP_LOCALIZATIONS HTTP #{code} #{error_text(body) unless code == 200}"
  return unless code == 200

  localizations = body.fetch("data")
  localization = localizations.find { |row| row.dig("attributes", "locale") == "en-US" } || localizations.first
  description = "Blinky shows provider usage limits on this iPhone. The first screen is an empty usage list until an account is connected."
  if localization.nil?
    create_code, create_body = request_json(
      :post,
      "/v1/betaAppLocalizations",
      token,
      {
        data: {
          type: "betaAppLocalizations",
          attributes: { description: description, feedbackEmail: EMAIL, locale: "en-US" },
          relationships: { app: { data: { type: "apps", id: app_id } } }
        }
      }
    )
    puts "BETA_APP_DESCRIPTION_CREATE HTTP #{create_code} #{error_text(create_body) unless create_code.between?(200, 299)}"
    return
  end

  attributes = localization.fetch("attributes")
  puts "BETA_APP_DESCRIPTION locale=#{attributes["locale"]} present=#{!attributes["description"].to_s.empty?} feedback_present=#{!attributes["feedbackEmail"].to_s.empty?}"
  patch = {}
  patch[:description] = description if attributes["description"].to_s.empty?
  patch[:feedbackEmail] = EMAIL if attributes["feedbackEmail"].to_s.empty?
  return if patch.empty?

  patch_code, patch_body = request_json(
    :patch,
    "/v1/betaAppLocalizations/#{localization.fetch("id")}",
    token,
    { data: { type: "betaAppLocalizations", id: localization.fetch("id"), attributes: patch } }
  )
  puts "BETA_APP_DESCRIPTION_PATCH HTTP #{patch_code} #{error_text(patch_body) unless patch_code.between?(200, 299)}"
end

def submit_beta_review(token, app_id, build)
  ensure_beta_description(token, app_id)
  review_code, review_body = request_json(:get, "/v1/builds/#{build.fetch("id")}/betaAppReviewSubmission", token)
  existing = review_code == 200 ? review_body["data"] : nil
  state = existing&.dig("attributes", "betaReviewState")
  puts "EXISTING_BETA_REVIEW HTTP #{review_code} state=#{state.inspect}"
  if existing && state != "REJECTED"
    puts "BETA_REVIEW_STATE #{state}"
    return
  end

  detail_code, detail_body = request_json(:get, "/v1/apps/#{app_id}/betaAppReviewDetail", token)
  puts "BETA_REVIEW_DETAIL HTTP #{detail_code}"
  detail = detail_code == 200 ? detail_body["data"] : nil
  if detail
    attributes = detail.fetch("attributes")
    puts "BETA_REVIEW_CONTACT email=#{attributes["contactEmail"].inspect} phone_present=#{!attributes["contactPhone"].to_s.empty?} notes_present=#{!attributes["notes"].to_s.empty?}"
    needs = attributes["contactEmail"].to_s.empty? || attributes["contactFirstName"].to_s.empty? || attributes["contactLastName"].to_s.empty?
    if needs
      patch = {}
      patch[:contactEmail] = EMAIL if attributes["contactEmail"].to_s.empty?
      patch[:contactFirstName] = "Kong" if attributes["contactFirstName"].to_s.empty?
      patch[:contactLastName] = "Yi" if attributes["contactLastName"].to_s.empty?
      patch[:demoAccountRequired] = false if attributes["demoAccountRequired"].nil?
      patch[:notes] = "Blinky shows provider usage limits. No demo account is required; the first screen is an empty usage list until an account is connected." if attributes["notes"].to_s.empty?
      patch_code, patch_body = request_json(
        :patch,
        "/v1/betaAppReviewDetails/#{detail.fetch("id")}",
        token,
        { data: { type: "betaAppReviewDetails", id: detail.fetch("id"), attributes: patch } }
      )
      puts "BETA_REVIEW_CONTACT_PATCH HTTP #{patch_code} #{error_text(patch_body) unless patch_code.between?(200, 299)}"
    end
  end

  submit_code, submit_body = request_json(
    :post,
    "/v1/betaAppReviewSubmissions",
    token,
    { data: { type: "betaAppReviewSubmissions", relationships: { build: { data: { type: "builds", id: build.fetch("id") } } } } }
  )
  submitted_state = submit_body.dig("data", "attributes", "betaReviewState")
  puts "BETA_REVIEW_SUBMIT HTTP #{submit_code} state=#{submitted_state.inspect} #{error_text(submit_body) unless submit_code.between?(200, 299)}"
  puts "BETA_REVIEW_STATE #{submitted_state || "NOT_SUBMITTED"}"
end

def invite_external(token, app_id, groups, first_name, last_name)
  external = ensure_external_group(token, app_id, groups)
  puts "EXTERNAL_GROUP id=#{external.fetch("id")} name=#{external.dig("attributes", "name")}"
  members_code, members_body = request_json(:get, "/v1/betaGroups/#{external.fetch("id")}/betaTesters?limit=200", token)
  members = members_code == 200 ? members_body.fetch("data") : []
  existing = members.find { |tester| tester.dig("attributes", "email").to_s.casecmp(EMAIL).zero? }
  if existing
    puts "EXTERNAL_TESTER_ALREADY id=#{existing.fetch("id")} state=#{existing.dig("attributes", "state")} email=#{existing.dig("attributes", "email")}"
    puts "INVITE_ALREADY_PRESENT id=#{existing.fetch("id")}"
    tester_id = existing.fetch("id")
  else
    code, body = create_internal_tester(token, EMAIL, first_name, last_name, [external.fetch("id")])
    puts "EXTERNAL_CREATE HTTP #{code} id=#{body.dig("data", "id")} state=#{body.dig("data", "attributes", "state")} #{error_text(body) unless code.between?(200, 299)}"
    raise "External tester create failed" unless code.between?(200, 299)

    tester_id = body.dig("data", "id")
    puts "INVITE_SENT external tester id=#{tester_id} email=#{EMAIL}"
  end
  puts "EXTERNAL_TESTER_ID #{tester_id}"
  puts "EXTERNAL_TESTER_ID_DIFFERS_FROM_INTERNAL #{tester_id != OLD_TESTER_ID}"
  add_code, add_body = add_tester_to_group(token, external.fetch("id"), tester_id)
  puts "EXTERNAL_GROUP_ADD HTTP #{add_code} #{error_text(add_body) unless add_code.between?(200, 299) || add_code == 409}"
  confirm_code, confirm_body = request_json(:get, "/v1/betaGroups/#{external.fetch("id")}/betaTesters?limit=20", token)
  confirm = confirm_code == 200 ? confirm_body.fetch("data").map { |tester| "#{tester.fetch("id")}:#{tester.dig("attributes", "email")}:#{tester.dig("attributes", "state")}" } : []
  puts "EXTERNAL_MEMBERS HTTP #{confirm_code} #{confirm.inspect}"

  build = find_ios_build(token, app_id)
  raise "Build #{MARKETING_VERSION} (#{BUILD_NUMBER}) was not found" unless build

  puts "BUILD id=#{build.fetch("id")} version=#{build.dig("attributes", "version")} processing=#{build.dig("attributes", "processingState")} encryption=#{build.dig("attributes", "usesNonExemptEncryption").inspect}"
  build = ensure_export_compliance(token, build)
  detail_code, detail_body = request_json(:get, "/v1/builds/#{build.fetch("id")}/buildBetaDetail", token)
  if detail_code == 200
    attributes = detail_body.dig("data", "attributes") || {}
    puts "BUILD_BETA internal=#{attributes["internalBuildState"]} external=#{attributes["externalBuildState"]}"
  else
    puts "BUILD_BETA HTTP #{detail_code}: #{error_text(detail_body)}"
  end
  assign_build_to_group(token, external.fetch("id"), build)
  submit_beta_review(token, app_id, build)
  puts "INTERNAL_MEMBERSHIP_UNCHANGED tester=#{OLD_TESTER_ID}"
end

def remove_tester_from_group(token, group, tester_id)
  code, body = request_json(
    :delete,
    "/v1/betaGroups/#{group.fetch("id")}/relationships/betaTesters",
    token,
    { data: [{ type: "betaTesters", id: tester_id }] }
  )
  puts "REMOVED_FROM_GROUP name=#{group.dig("attributes", "name").inspect} tester=#{tester_id} HTTP #{code} #{error_text(body) unless code.between?(200, 299) || code == 404 || code == 409}"
  code
end

def delete_tester_resource(token, tester_id)
  code, body = request_json(:delete, "/v1/betaTesters/#{tester_id}", token)
  puts "DELETE_TESTER id=#{tester_id} HTTP #{code} #{error_text(body) unless code.between?(200, 299) || code == 404}"
  code
end

def email_tester_ids(token)
  code, body = request_json(:get, api_path("/v1/betaTesters", { "filter[email]" => EMAIL, "limit" => "20" }), token)
  ids = code == 200 ? body.fetch("data").map { |tester| tester.fetch("id") } : nil
  [code, ids]
end

def poll_email_gone(token, label, seconds)
  deadline = Time.now + seconds
  attempt = 0
  while Time.now < deadline
    sleep 10
    attempt += 1
    code, ids = email_tester_ids(token)
    puts "POLL_#{label} #{attempt} HTTP #{code} ids=#{ids.inspect}"
    return true if code == 200 && ids.empty?
  end
  false
end

def cycle_internal(token, app_id, groups, internal, first_name, last_name)
  code, ids = email_tester_ids(token)
  puts "CYCLE_START HTTP #{code} ids=#{ids.inspect}"
  tester_ids = (ids || []) | [OLD_TESTER_ID]

  groups.each do |group|
    tester_ids.each { |tester_id| remove_tester_from_group(token, group, tester_id) }
  end
  tester_ids.each { |tester_id| delete_tester_resource(token, tester_id) }
  poll_email_gone(token, "AFTER_INTERNAL_DELETE", 60)

  external = ensure_external_group(token, app_id, groups)
  external_code, external_body = create_internal_tester(token, EMAIL, first_name, last_name, [external.fetch("id")])
  external_id = external_body.dig("data", "id")
  puts "EXTERNAL_CYCLE_CREATE HTTP #{external_code} id=#{external_id} #{error_text(external_body) unless external_code.between?(200, 299)}"

  if external_code.between?(200, 299) && external_id
    remove_tester_from_group(token, external, external_id)
    delete_tester_resource(token, external_id)
  end
  code, ids = email_tester_ids(token)
  (ids || []).each { |tester_id| delete_tester_resource(token, tester_id) }
  poll_email_gone(token, "AFTER_EXTERNAL_DELETE", 60)

  internal_code = nil
  internal_body = nil
  new_id = nil
  3.times do |attempt|
    internal_code, internal_body = create_internal_tester(token, EMAIL, first_name, last_name, [internal.fetch("id")])
    new_id = internal_body.dig("data", "id")
    puts "INTERNAL_CREATE attempt=#{attempt + 1} HTTP #{internal_code} id=#{new_id} state=#{internal_body.dig("data", "attributes", "state")} #{error_text(internal_body) unless internal_code.between?(200, 299)}"
    break if internal_code.between?(200, 299) && new_id

    sleep 5
  end
  raise "Internal restore failed" unless internal_code.between?(200, 299) && new_id

  puts "OLD_TESTER_ID #{OLD_TESTER_ID}"
  puts "NEW_TESTER_ID #{new_id}"
  puts "TESTER_ID_CHANGED #{new_id != OLD_TESTER_ID}"
  if new_id == OLD_TESTER_ID
    puts "CYCLE_REUSED_OLD_ID #{OLD_TESTER_ID}"
  else
    puts "INVITE_SENT internal tester id=#{new_id} email=#{EMAIL}"
  end

  build = find_ios_build(token, app_id)
  if build
    assign_code = assign_build_to_group(token, internal.fetch("id"), build)
    puts "ASSIGN_INTERNAL_BUILD HTTP #{assign_code} build=#{build.fetch("id")} version=#{build.dig("attributes", "version")}"
  else
    puts "ASSIGN_INTERNAL_BUILD missing #{MARKETING_VERSION} (#{BUILD_NUMBER})"
  end

  members_code, members_body = request_json(:get, "/v1/betaGroups/#{external.fetch("id")}/betaTesters?limit=20", token)
  external_members = members_code == 200 ? members_body.fetch("data") : []
  external_members.each { |tester| remove_tester_from_group(token, external, tester.fetch("id")) if tester.dig("attributes", "email").to_s.casecmp(EMAIL).zero? }
  if members_code == 200 && external_members.reject { |tester| tester.dig("attributes", "email").to_s.casecmp(EMAIL).zero? }.empty?
    delete_code, delete_body = request_json(:delete, "/v1/betaGroups/#{external.fetch("id")}", token)
    puts "DELETED_EXTERNAL_GROUP id=#{external.fetch("id")} HTTP #{delete_code} #{error_text(delete_body) unless delete_code.between?(200, 299)}"
  else
    puts "EXTERNAL_GROUP_LEFT id=#{external.fetch("id")} members=#{external_members.length}"
  end

  final_code, final_ids = email_tester_ids(token)
  internal_members_code, internal_members_body = request_json(:get, "/v1/betaGroups/#{internal.fetch("id")}/betaTesters?limit=20", token)
  internal_members = internal_members_code == 200 ? internal_members_body.fetch("data").map { |tester| "#{tester.fetch("id")}:#{tester.dig("attributes", "state")}" } : []
  puts "FINAL_EMAIL_TESTERS HTTP #{final_code} ids=#{final_ids.inspect}"
  puts "FINAL_INTERNAL_MEMBERS #{internal_members.inspect}"
  puts "BETA_REVIEW_NOT_USED cycle ended on internal"
end

def create_internal_tester(token, email, first_name, last_name, group_ids)
  request_json(
    :post,
    "/v1/betaTesters",
    token,
    {
      data: {
        type: "betaTesters",
        attributes: { email: email, firstName: first_name, lastName: last_name },
        relationships: {
          betaGroups: { data: group_ids.map { |id| { type: "betaGroups", id: id } } }
        }
      }
    }
  )
end

def add_tester_to_group(token, group_id, tester_id)
  request_json(
    :post,
    "/v1/betaGroups/#{group_id}/relationships/betaTesters",
    token,
    { data: [{ type: "betaTesters", id: tester_id }] }
  )
end

key_path = required_env("ASC_KEY_PATH")
key_id = required_env("ASC_KEY_ID")
issuer_id = required_env("ASC_ISSUER_ID")
token = token_for(key_path, key_id, issuer_id)

apps = expect(*request_json(:get, api_path("/v1/apps", { "filter[bundleId]" => BUNDLE_ID, "limit" => "5" }), token), "List apps").fetch("data")
raise "No App Store Connect app matches #{BUNDLE_ID}" unless apps.length == 1

app = apps.first
app_id = app.fetch("id")
puts "APP id=#{app_id} bundle=#{BUNDLE_ID} name=#{app.dig("attributes", "name").inspect}"

users_code, users_body = request_json(:get, api_path("/v1/users", { "limit" => "200" }), token)
dump("users", users_code, users_body)
users = users_code == 200 ? users_body.fetch("data") : []
users.each do |user|
  detail_code, detail_body = request_json(:get, "/v1/users/#{user.fetch("id")}", token)
  dump("user #{user.fetch("id")}", detail_code, detail_body)
end
gmail_user = users.find { |user| user.dig("attributes", "username").to_s.casecmp(EMAIL).zero? }
qq_users = users.select { |user| qq_email?(user.dig("attributes", "username")) }
puts "GMAIL_ASC_USER present=#{!gmail_user.nil?} username=#{gmail_user&.dig("attributes", "username")}"
puts "QQ_USERS #{qq_users.map { |user| user.dig("attributes", "username") }.inspect}"

invites_code, invites_body = request_json(:get, api_path("/v1/userInvitations", { "limit" => "200" }), token)
dump("userInvitations", invites_code, invites_body)
invitations = invites_code == 200 ? invites_body.fetch("data") : []

groups = expect(*request_json(:get, api_path("/v1/betaGroups", { "filter[app]" => app_id, "limit" => "200" }), token), "List groups").fetch("data")
groups.each do |group|
  attributes = group.fetch("attributes")
  puts "GROUP id=#{group.fetch("id")} name=#{attributes["name"].inspect} internal=#{attributes["isInternalGroup"]}"
end

internal_groups = groups.select { |group| group.dig("attributes", "isInternalGroup") == true }
internal = internal_groups.find { |group| group.dig("attributes", "name") == INTERNAL_GROUP }
raise "Internal group #{INTERNAL_GROUP.inspect} was not found" unless internal

internal_groups.each do |group|
  members_code, members_body = request_json(:get, "/v1/betaGroups/#{group.fetch("id")}/betaTesters?limit=200", token)
  members = members_code == 200 ? members_body.fetch("data") : []
  puts "GROUP_MEMBERS name=#{group.dig("attributes", "name").inspect} HTTP #{members_code} count=#{members.length}"
  members.each do |tester|
    attributes = tester.fetch("attributes")
    puts "MEMBER group=#{group.dig("attributes", "name").inspect} id=#{tester.fetch("id")} email=#{attributes["email"]} state=#{attributes["state"]} inviteType=#{attributes["inviteType"]} first=#{attributes["firstName"]} last=#{attributes["lastName"]}"
  end
  builds_code, builds_body = request_json(:get, "/v1/betaGroups/#{group.fetch("id")}/builds?limit=20", token)
  builds = builds_code == 200 ? builds_body.fetch("data") : []
  builds.each do |build|
    attributes = build.fetch("attributes")
    puts "GROUP_BUILD group=#{group.dig("attributes", "name").inspect} id=#{build.fetch("id")} version=#{attributes["version"]} processing=#{attributes["processingState"]}"
  end
end

if ENV["REINVITE_AFTER_STOP"] == "1"
  raise "No App Store Connect user uses Apple ID #{EMAIL}" unless gmail_user

  first_name = gmail_user.dig("attributes", "firstName").to_s
  first_name = "Kong" if first_name.empty?
  last_name = gmail_user.dig("attributes", "lastName").to_s
  last_name = "Yi" if last_name.empty?
  _code, ids = email_tester_ids(token)
  tester_ids = ((ids || []) + [OLD_TESTER_ID]).uniq
  puts "REINVITE_DELETE ids=#{tester_ids.inspect}"
  groups.each do |group|
    tester_ids.each { |tester_id| remove_tester_from_group(token, group, tester_id) }
  end
  tester_ids.each { |tester_id| delete_tester_resource(token, tester_id) }
  gone = poll_email_gone(token, "AFTER_DELETE", 90)
  puts "EMAIL_FILTER_EMPTY #{gone}"

  create_code, create_body = create_internal_tester(token, EMAIL, first_name, last_name, [internal.fetch("id")])
  new_id = create_body.dig("data", "id")
  puts "INTERNAL_CREATE HTTP #{create_code} id=#{new_id} state=#{create_body.dig("data", "attributes", "state")} #{error_text(create_body) unless create_code.between?(200, 299)}"
  raise "Internal reinvite failed" unless create_code.between?(200, 299) && new_id

  blinky = internal_groups.find { |group| group.dig("attributes", "name") == "Blinky Internal" }
  if blinky
    add_code, add_body = add_tester_to_group(token, blinky.fetch("id"), new_id)
    puts "ADDED_BLINKY HTTP #{add_code} #{error_text(add_body) unless add_code.between?(200, 299) || add_code == 409}"
  end

  groups.select { |group| group.dig("attributes", "isInternalGroup") == false }.each do |group|
    remove_tester_from_group(token, group, new_id)
  end

  build = find_ios_build(token, app_id)
  if build
    assign_code = assign_build_to_group(token, internal.fetch("id"), build)
    puts "ASSIGN_INTERNAL_BUILD HTTP #{assign_code} build=#{build.fetch("id")} version=#{build.dig("attributes", "version")}"
  end

  puts "OLD_TESTER_ID #{OLD_TESTER_ID}"
  puts "NEW_TESTER_ID #{new_id}"
  puts "TESTER_ID_CHANGED #{new_id != OLD_TESTER_ID}"
  if new_id == OLD_TESTER_ID
    puts "REINVITE_REUSED_OLD_ID #{OLD_TESTER_ID}"
  else
    puts "INVITE_SENT internal tester id=#{new_id} email=#{EMAIL}"
  end

  internal_groups.each do |group|
    members_code, members_body = request_json(:get, "/v1/betaGroups/#{group.fetch("id")}/betaTesters?limit=20", token)
    members = members_code == 200 ? members_body.fetch("data").map { |tester| "#{tester.fetch("id")}:#{tester.dig("attributes", "email")}:#{tester.dig("attributes", "state")}" } : []
    puts "FINAL_GROUP name=#{group.dig("attributes", "name").inspect} HTTP #{members_code} #{members.inspect}"
  end
  final_code, final_ids = email_tester_ids(token)
  puts "FINAL_EMAIL_TESTERS HTTP #{final_code} ids=#{final_ids.inspect}"
  puts "BETA_REVIEW_NOT_USED internal only"
  exit 0
end

if ENV["ENSURE_INTERNAL_MEMBERSHIP"] == "1"
  add_code, add_body = add_tester_to_group(token, internal.fetch("id"), OLD_TESTER_ID)
  puts "ENSURE_INTERNAL_ADD HTTP #{add_code} #{error_text(add_body) unless add_code.between?(200, 299) || add_code == 409}"
  sleep 3
  members_code, members_body = request_json(:get, "/v1/betaGroups/#{internal.fetch("id")}/betaTesters?limit=20", token)
  members = members_code == 200 ? members_body.fetch("data").map { |tester| "#{tester.fetch("id")}:#{tester.dig("attributes", "email")}:#{tester.dig("attributes", "state")}" } : []
  puts "FINAL_INTERNAL_MEMBERS HTTP #{members_code} #{members.inspect}"
  final_code, final_ids = email_tester_ids(token)
  puts "FINAL_EMAIL_TESTERS HTTP #{final_code} ids=#{final_ids.inspect}"
  exit 0
end

if ENV["CYCLE_INTERNAL"] == "1"
  raise "No App Store Connect user uses Apple ID #{EMAIL}" unless gmail_user

  first_name = gmail_user.dig("attributes", "firstName").to_s
  first_name = "Kong" if first_name.empty?
  last_name = gmail_user.dig("attributes", "lastName").to_s
  last_name = "Yi" if last_name.empty?
  cycle_internal(token, app_id, groups, internal, first_name, last_name)
  exit 0
end

if ENV["EXTERNAL_INVITE"] == "1"
  raise "No App Store Connect user uses Apple ID #{EMAIL}" unless gmail_user

  first_name = gmail_user.dig("attributes", "firstName").to_s
  first_name = "Kong" if first_name.empty?
  last_name = gmail_user.dig("attributes", "lastName").to_s
  last_name = "Yi" if last_name.empty?
  invite_external(token, app_id, groups, first_name, last_name)
  exit 0
end

all_code, all_body = request_json(:get, api_path("/v1/betaTesters", { "limit" => "200" }), token)
dump("betaTesters", all_code, all_body)
qq_filter_code, qq_filter_body = request_json(:get, api_path("/v1/betaTesters", { "filter[email]" => "*@qq.com", "limit" => "20" }), token)
dump("betaTesters filter *@qq.com", qq_filter_code, qq_filter_body)

old_code, old_body = request_json(
  :get,
  api_path("/v1/betaTesters/#{OLD_TESTER_ID}", { "include" => "apps,betaGroups,builds" }),
  token
)
dump("betaTester #{OLD_TESTER_ID} include=apps,betaGroups,builds", old_code, old_body)
if old_code != 200
  %w[apps betaGroups builds].each do |name|
    rel_code, rel_body = request_json(:get, "/v1/betaTesters/#{OLD_TESTER_ID}/#{name}?limit=50", token)
    dump("betaTester #{OLD_TESTER_ID} /#{name}", rel_code, rel_body)
  end
end
old_urls = urls_in(old_body)
puts "OLD_TESTER_URLS #{old_urls.inspect}"

email_code, email_body = request_json(
  :get,
  api_path("/v1/betaTesters", { "filter[email]" => EMAIL, "include" => "apps,betaGroups,builds", "limit" => "20" }),
  token
)
dump("betaTesters filter #{EMAIL}", email_code, email_body)
testers = email_code == 200 ? email_body.fetch("data") : []

raise "No App Store Connect user uses Apple ID #{EMAIL}" unless gmail_user

first_name = gmail_user.dig("attributes", "firstName").to_s
first_name = "Kong" if first_name.empty?
last_name = gmail_user.dig("attributes", "lastName").to_s
last_name = "Yi" if last_name.empty?

if ENV["FORCE_RECREATE"] != "1"
  puts "FORCE_RECREATE is not set. No tester was deleted."
  exit 0
end

if ENV["ENSURE_BLINKY_ONLY"] == "1"
  blinky = internal_groups.find { |group| group.dig("attributes", "name") == "Blinky Internal" }
  raise "Blinky Internal group was not found" unless blinky

  add_code, add_body = add_tester_to_group(token, blinky.fetch("id"), OLD_TESTER_ID)
  puts "ADDED_TO_GROUP name=\"Blinky Internal\" HTTP #{add_code} #{error_text(add_body) unless add_code.between?(200, 299)}"
  members_code, members_body = request_json(:get, "/v1/betaGroups/#{blinky.fetch("id")}/betaTesters?limit=20", token)
  members = members_code == 200 ? members_body.fetch("data").map { |tester| tester.fetch("id") } : []
  puts "BLINKY_MEMBERS HTTP #{members_code} ids=#{members.inspect}"
  exit 0
end

delete_code, delete_body = request_json(:delete, "/v1/betaTesters/#{OLD_TESTER_ID}", token)
puts "DELETE_BETA_TESTER id=#{OLD_TESTER_ID} HTTP #{delete_code} #{error_text(delete_body) unless delete_code.between?(200, 299) || delete_code == 404}"
raise "DELETE betaTester failed HTTP #{delete_code}" unless delete_code.between?(200, 299) || delete_code == 404

deadline = Time.now + 300
attempt = 0
list_empty = false
while Time.now < deadline
  sleep 15
  attempt += 1
  list_code, list_body = request_json(:get, api_path("/v1/betaTesters", { "filter[email]" => EMAIL, "limit" => "20" }), token)
  remaining = list_code == 200 ? list_body.fetch("data").map { |tester| tester.fetch("id") } : nil
  puts "POLL #{attempt} HTTP #{list_code} ids=#{remaining.inspect} elapsed=#{attempt * 15}s"
  list_empty = list_code == 200 && remaining.empty?
end
puts "EMAIL_FILTER_EMPTY_AFTER_WAIT #{list_empty}"
raise "sharkchili.su@gmail.com still has a beta tester after 5 minutes" unless list_empty

created = nil
code = nil
body = nil
group_sets = [internal_groups.map { |group| group.fetch("id") }, [internal.fetch("id")]]
group_sets.each_with_index do |group_ids, attempt_index|
  code, body = create_internal_tester(token, EMAIL, first_name, last_name, group_ids)
  puts "CREATE_HTTP attempt=#{attempt_index + 1} groups=#{group_ids.inspect} HTTP #{code} id=#{body.dig("data", "id")} #{error_text(body) unless code.between?(200, 299)}"
  if code.between?(200, 299)
    created = body.fetch("data")
    break
  end
end
raise "Internal reinvite failed HTTP #{code}: #{error_text(body)}" unless created

new_id = created.fetch("id")
internal_groups.each do |group|
  next if group.fetch("id") == internal.fetch("id")

  add_code, add_body = add_tester_to_group(token, group.fetch("id"), new_id)
  puts "ADDED_TO_GROUP name=#{group.dig("attributes", "name").inspect} HTTP #{add_code} #{error_text(add_body) unless add_code.between?(200, 299)}"
end

new_code, new_body = request_json(
  :get,
  api_path("/v1/betaTesters/#{new_id}", { "include" => "apps,betaGroups,builds" }),
  token
)
dump("betaTester #{new_id} after create", new_code, new_body)
new_urls = urls_in(new_body)
puts "NEW_TESTER_URLS #{new_urls.inspect}"
puts "OLD_TESTER_ID #{OLD_TESTER_ID}"
puts "NEW_TESTER_ID #{new_id}"
puts "TESTER_ID_CHANGED #{new_id != OLD_TESTER_ID}"
puts "INVITE_SENT email=#{created.dig("attributes", "email")} state=#{created.dig("attributes", "state")} id=#{new_id}"
puts "QQ_HITS #{QQ_HITS.empty? ? "none" : QQ_HITS.uniq.inspect}"
puts "BETA_REVIEW_NOT_USED internal only"
