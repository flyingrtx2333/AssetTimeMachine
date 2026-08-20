#!/usr/bin/env ruby
# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "net/http"
require "openssl"
require "shellwords"
require "uri"

API = "https://api.appstoreconnect.apple.com"
BUNDLE_ID = "com.flyingrtx.AssetTimeMachine"
DISPLAY_TYPE = "APP_IPHONE_65" # 1242x2688 portrait
EDITABLE_STATES = %w[PREPARE_FOR_SUBMISSION DEVELOPER_REJECTED REJECTED METADATA_REJECTED].freeze

def b64url(value)
  Base64.urlsafe_encode64(value).delete("=")
end

def jwt
  header = b64url({ alg: "ES256", kid: ENV.fetch("ASC_KEY_ID"), typ: "JWT" }.to_json)
  now = Time.now.to_i
  payload = b64url({ iss: ENV.fetch("ASC_ISSUER_ID"), iat: now, exp: now + 1_100, aud: "appstoreconnect-v1" }.to_json)
  key = OpenSSL::PKey.read(File.read(ENV.fetch("ASC_KEY_PATH")))
  der_signature = key.dsa_sign_asn1(Digest::SHA256.digest("#{header}.#{payload}"))
  sequence = OpenSSL::ASN1.decode(der_signature)
  raw_signature = sequence.value.map { |integer| integer.value.to_s(2).rjust(32, "\0") }.join
  "#{header}.#{payload}.#{b64url(raw_signature)}"
end

def request(method, path_or_url, body: nil, headers: {})
  uri = URI(path_or_url.start_with?("http") ? path_or_url : "#{API}#{path_or_url}")
  klass = { get: Net::HTTP::Get, post: Net::HTTP::Post, patch: Net::HTTP::Patch, delete: Net::HTTP::Delete, put: Net::HTTP::Put }.fetch(method)
  req = klass.new(uri)
  unless path_or_url.start_with?("http")
    req["Authorization"] = "Bearer #{jwt}"
    req["Content-Type"] = "application/json" if body
  end
  headers.each { |key, value| req[key] = value }
  req.body = body.is_a?(String) ? body : JSON.generate(body) if body
  http_class = Net::HTTP::Proxy(:ENV)
  response = nil
  3.times do |attempt|
    begin
      response = http_class.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 45, read_timeout: 120) { |http| http.request(req) }
      break
    rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET => error
      raise if attempt == 2
      warn "Network retry #{attempt + 1}/3 for #{uri.host}: #{error.class}"
      sleep 2 * (attempt + 1)
    end
  end
  unless response.code.to_i.between?(200, 299)
    abort "#{method.upcase} #{uri} failed: HTTP #{response.code}\n#{response.body}"
  end
  return nil if response.body.nil? || response.body.empty?
  JSON.parse(response.body)
end

def data(method, path, **kwargs)
  request(method, path, **kwargs)&.fetch("data")
end

def discover(create_version: false)
  app = data(:get, "/v1/apps?filter[bundleId]=#{BUNDLE_ID}&limit=1").first
  abort "App not found for #{BUNDLE_ID}" unless app
  versions = data(:get, "/v1/apps/#{app.fetch("id")}/appStoreVersions?filter[platform]=IOS&limit=50")
  version = versions.find { |item| EDITABLE_STATES.include?(item.dig("attributes", "appStoreState")) }
  if version.nil? && create_version
    desired = ENV.fetch("APP_STORE_VERSION", "1.12")
    version = data(:post, "/v1/appStoreVersions", body: {
      data: {
        type: "appStoreVersions",
        attributes: { platform: "IOS", versionString: desired },
        relationships: { app: { data: { type: "apps", id: app.fetch("id") } } }
      }
    })
    puts "CREATED VERSION #{desired} #{version.fetch("id")}"
  end
  unless version
    summary = versions.map { |item| "#{item.dig("attributes", "versionString")}:#{item.dig("attributes", "appStoreState")}:#{item.fetch("id")}" }.join(", ")
    abort "No editable iOS App Store version found. Existing: #{summary}"
  end
  localizations = data(:get, "/v1/appStoreVersions/#{version.fetch("id")}/appStoreVersionLocalizations?limit=50")
  [app, version, localizations]
end

def screenshot_sets(localization_id)
  data(:get, "/v1/appStoreVersionLocalizations/#{localization_id}/appScreenshotSets?filter[screenshotDisplayType]=#{DISPLAY_TYPE}&limit=10")
end

def screenshots(set_id)
  data(:get, "/v1/appScreenshotSets/#{set_id}/appScreenshots?limit=50")
end

def ensure_set(localization_id)
  existing = screenshot_sets(localization_id).first
  return existing if existing
  data(:post, "/v1/appScreenshotSets", body: {
    data: {
      type: "appScreenshotSets",
      attributes: { screenshotDisplayType: DISPLAY_TYPE },
      relationships: { appStoreVersionLocalization: { data: { type: "appStoreVersionLocalizations", id: localization_id } } }
    }
  })
end

def upload_file(set_id, path)
  bytes = File.binread(path)
  reservation = data(:post, "/v1/appScreenshots", body: {
    data: {
      type: "appScreenshots",
      attributes: { fileName: File.basename(path), fileSize: bytes.bytesize },
      relationships: { appScreenshotSet: { data: { type: "appScreenshotSets", id: set_id } } }
    }
  })
  reservation.dig("attributes", "uploadOperations").each do |operation|
    offset = operation.fetch("offset")
    length = operation.fetch("length")
    part = bytes.byteslice(offset, length)
    headers = operation.fetch("requestHeaders").to_h { |header| [header.fetch("name"), header.fetch("value")] }
    request(:put, operation.fetch("url"), body: part, headers: headers)
  end
  checksum = Digest::MD5.hexdigest(bytes)
  data(:patch, "/v1/appScreenshots/#{reservation.fetch("id")}", body: {
    data: { type: "appScreenshots", id: reservation.fetch("id"), attributes: { uploaded: true, sourceFileChecksum: checksum } }
  })
end

def wait_complete(ids)
  30.times do
    states = ids.map do |id|
      item = data(:get, "/v1/appScreenshots/#{id}")
      [id, item.dig("attributes", "assetDeliveryState", "state")]
    end
    puts states.map { |id, state| "#{id}=#{state}" }.join(" ")
    return if states.all? { |_, state| state == "COMPLETE" }
    failed = states.find { |_, state| %w[FAILED REJECTED].include?(state) }
    abort "Screenshot processing failed: #{failed.inspect}" if failed
    sleep 4
  end
  abort "Timed out waiting for screenshot processing"
end

def locale_directory(locale)
  mapping = { "zh-Hans" => "zh-CN", "en-US" => "en-US", "en-GB" => "en-US" }
  mapping[locale]
end

command = ARGV.shift || "inspect"
root = ARGV.shift || File.join(Dir.pwd, "marketing/app-store/2026-08-13-refresh/posters")
app, version, localizations = discover(create_version: command == "upload")
puts "APP #{app.fetch("id")} #{app.dig("attributes", "name")}"
puts "VERSION #{version.fetch("id")} #{version.dig("attributes", "versionString")} #{version.dig("attributes", "appStoreState")}"
localizations.each do |localization|
  locale = localization.dig("attributes", "locale")
  sets = screenshot_sets(localization.fetch("id"))
  puts "LOCALE #{locale} #{localization.fetch("id")} SETS=#{sets.map { |set| set.fetch("id") }.join(",")} COUNTS=#{sets.map { |set| screenshots(set.fetch("id")).length }.join(",")}"
  sets.each do |set|
    screenshots(set.fetch("id")).each_with_index do |item, index|
      attributes = item.fetch("attributes")
      puts "SCREENSHOT #{locale} #{index + 1} #{item.fetch("id")} #{attributes.fetch("fileName")} #{attributes.dig("assetDeliveryState", "state")}"
    end
  end
end
exit 0 if command == "inspect"
abort "Unknown command: #{command}" unless %w[upload replace_after_keep].include?(command)

if command == "upload" && localizations.none? { |item| item.dig("attributes", "locale") == "en-US" }
  english = data(:post, "/v1/appStoreVersionLocalizations", body: {
    data: {
      type: "appStoreVersionLocalizations",
      attributes: { locale: "en-US" },
      relationships: { appStoreVersion: { data: { type: "appStoreVersions", id: version.fetch("id") } } }
    }
  })
  localizations << english
  puts "CREATED LOCALIZATION en-US #{english.fetch("id")}"
end

targets = localizations.map do |localization|
  locale = localization.dig("attributes", "locale")
  next if command == "replace_after_keep" && locale != ENV.fetch("TARGET_LOCALE", "zh-Hans")
  directory = locale_directory(locale)
  next unless directory
  files = Dir[File.join(root, directory, "*.png")].sort
  abort "No PNG files for #{locale} in #{File.join(root, directory)}" if files.empty?
  [localization, files]
end.compact
abort "No matching zh-Hans/en localization found" if targets.empty?

targets.each do |localization, files|
  locale = localization.dig("attributes", "locale")
  set = ensure_set(localization.fetch("id"))
  old = screenshots(set.fetch("id"))
  keep_count = command == "replace_after_keep" ? Integer(ENV.fetch("KEEP_SCREENSHOTS", "2")) : 0
  abort "Cannot keep #{keep_count} of only #{old.length} screenshots for #{locale}" if keep_count > old.length
  kept = old.first(keep_count)
  removed = old.drop(keep_count)
  puts "Keeping #{kept.length}, replacing #{removed.length} screenshots for #{locale} with #{files.length}"
  kept.each_with_index { |item, index| puts "KEPT #{locale} #{index + 1} #{item.fetch("id")} #{item.dig("attributes", "fileName")}" }
  removed.each { |item| request(:delete, "/v1/appScreenshots/#{item.fetch("id")}") }
  uploaded = files.map do |path|
    item = upload_file(set.fetch("id"), path)
    puts "UPLOADED #{locale} #{File.basename(path)} #{item.fetch("id")}"
    item.fetch("id")
  end
  wait_complete(uploaded)
  final = screenshots(set.fetch("id"))
  expected_count = kept.length + files.length
  abort "Final screenshot count mismatch for #{locale}: #{final.length}, expected #{expected_count}" unless final.length == expected_count
  puts "VERIFIED #{locale} #{final.length} screenshots COMPLETE"
end
