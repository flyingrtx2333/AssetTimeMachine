#!/usr/bin/env ruby
# Explicit submission of the prepared 1.14 store version, using its verified 233 IPA.
$stdout.sync = true
require "time"
ENV["APP_STORE_VERSION"] = "1.14"
ENV["SCREENSHOT_DISPLAY_TYPE"] = "APP_IPHONE_67"
require_relative "app_store_screenshots"

root = File.expand_path(ARGV.fetch(0))
metadata = JSON.parse(File.read(File.join(root, "metadata.json")))
prepared = JSON.parse(File.read(File.join(root, "prepared.json")))
artifact = JSON.parse(File.read(File.join(root, "artifact-match.json")))
abort "Unverified or stale artifact receipt" unless artifact.fetch("serverArtifactMatched") &&
  artifact.fetch("serverDeliveryComplete") && artifact.fetch("build") == metadata.fetch("build") &&
  artifact.fetch("version") == metadata.fetch("version") && artifact.fetch("bundleID") == BUNDLE_ID &&
  Time.now - Time.parse(artifact.fetch("checkedAt")) < 7200
app_id = "6764277773"
version_id = prepared.fetch("version").fetch("id")
version = data(:get, "/v1/appStoreVersions/#{version_id}")
abort "Wrong version" unless version.dig("attributes", "versionString") == metadata.fetch("version")
abort "Wrong release policy" unless version.dig("attributes", "releaseType") == "AFTER_APPROVAL"
build = data(:get, "/v1/appStoreVersions/#{version_id}/build")
abort "Wrong build" unless build.fetch("id") == metadata.fetch("buildID") && build.dig("attributes", "version") == metadata.fetch("build")

localizations = data(:get, "/v1/appStoreVersions/#{version_id}/appStoreVersionLocalizations?limit=20")
metadata.fetch("localizations").each do |locale, copy|
  loc = localizations.find { |l| l.dig("attributes", "locale") == locale }
  abort "Missing locale #{locale}" unless loc
  copy.reject { |k, _| k == "subtitle" }.each { |key, value| abort "Copy mismatch #{locale}/#{key}" unless loc.dig("attributes", key) == value }
  sets = data(:get, "/v1/appStoreVersionLocalizations/#{loc.fetch('id')}/appScreenshotSets?limit=20")
  abort "Unexpected screenshot size sets" unless sets.length == 1 && sets.first.dig("attributes", "screenshotDisplayType") == DISPLAY_TYPE
  shots = screenshots(sets.first.fetch("id"))
  files = Dir[File.join(root, "posters", locale, "*.png")].sort
  abort "Wrong screenshot count" unless files.length == 5 && shots.length == 5
  files.zip(shots).each do |path, shot|
    a = shot.fetch("attributes")
    abort "Screenshot not ready #{locale}" unless a.fetch("fileName") == File.basename(path) &&
      a.fetch("sourceFileChecksum") == Digest::MD5.file(path).hexdigest &&
      a.dig("assetDeliveryState", "state") == "COMPLETE" &&
      a.dig("imageAsset", "width") == 1320 && a.dig("imageAsset", "height") == 2868
  end
end
puts "VERIFIED build, release policy, localized copy, and all ten screenshot assets"

infos = data(:get, "/v1/apps/#{app_id}/appInfos?limit=20")
editable = infos.select { |info| EDITABLE_STATES.include?(info.dig("attributes", "appStoreState")) }
abort "Expected one editable app info" unless editable.length == 1
info_id = editable.first.fetch("id")
info_locales = data(:get, "/v1/appInfos/#{info_id}/appInfoLocalizations?limit=20")
audit = []
metadata.fetch("localizations").each do |locale, copy|
  loc = info_locales.find { |l| l.dig("attributes", "locale") == locale }
  abort "Missing app info locale" unless loc
  fields = { subtitle: copy.fetch("subtitle") }
  fields[:name] = "Asset Time Machine" if locale == "en-US"
  changed = data(:patch, "/v1/appInfoLocalizations/#{loc.fetch('id')}", body: {
    data: { type: "appInfoLocalizations", id: loc.fetch("id"), attributes: fields }
  })
  readback = data(:get, "/v1/appInfoLocalizations/#{loc.fetch('id')}")
  fields.each { |key, value| abort "App info mismatch" unless readback.dig("attributes", key.to_s) == value }
  abort "Privacy URL changed" unless loc.dig("attributes", "privacyPolicyUrl") == readback.dig("attributes", "privacyPolicyUrl")
  audit << { locale: locale, previousName: loc.dig("attributes", "name"), previousSubtitle: loc.dig("attributes", "subtitle"),
             name: readback.dig("attributes", "name"), subtitle: readback.dig("attributes", "subtitle"), privacyURLPreserved: true }
end
File.write(File.join(root, "app-info.json"), JSON.pretty_generate(audit))

review = data(:get, "/v1/appStoreVersions/#{version_id}/appStoreReviewDetail")
abort "Missing review contact" unless review && %w[contactFirstName contactLastName contactPhone contactEmail].all? { |k| !review.dig("attributes", k).to_s.empty? }
abort "Unexpected demo account requirement" if review.dig("attributes", "demoAccountRequired")
notes = "Core asset recording and history features work locally without signing in. Sign in with Apple is optional and only required for cloud sync. Store screenshots use sample account balances, not user financial data or strategy performance claims. The optional gold curve displays asset-equivalent grams based on the dated gold price. This app does not execute trades."
data(:patch, "/v1/appStoreReviewDetails/#{review.fetch('id')}", body: {
  data: { type: "appStoreReviewDetails", id: review.fetch("id"), attributes: { notes: notes } }
})
submissions = data(:get, "/v1/apps/#{app_id}/reviewSubmissions?limit=50")
active = submissions.select { |s| %w[READY_FOR_REVIEW WAITING_FOR_REVIEW IN_REVIEW UNRESOLVED_ISSUES CANCELING COMPLETING].include?(s.dig("attributes", "state")) }
abort "Another submission is active" unless active.empty?
submission = data(:post, "/v1/reviewSubmissions", body: {
  data: { type: "reviewSubmissions", attributes: { platform: "IOS" },
          relationships: { app: { data: { type: "apps", id: app_id } } } }
})
submission_id = submission.fetch("id")
item = data(:post, "/v1/reviewSubmissionItems", body: {
  data: { type: "reviewSubmissionItems", relationships: {
    reviewSubmission: { data: { type: "reviewSubmissions", id: submission_id } },
    appStoreVersion: { data: { type: "appStoreVersions", id: version_id } }
  } }
})
# Persist the exact submission identity before the irreversible submission request.
File.write(File.join(root, "submission-created.json"), JSON.pretty_generate({ submission: submission, item: item }))
data(:patch, "/v1/reviewSubmissions/#{submission_id}", body: {
  data: { type: "reviewSubmissions", id: submission_id, attributes: { submitted: true } }
})
readback = data(:get, "/v1/reviewSubmissions/#{submission_id}")
version = data(:get, "/v1/appStoreVersions/#{version_id}")
File.write(File.join(root, "submitted.json"), JSON.pretty_generate({ submission: readback, version: version,
  buildID: build.fetch("id"), build: metadata.fetch("build"), checkedAt: Time.now.utc.iso8601 }))
abort "Submission did not enter the review queue" unless %w[WAITING_FOR_REVIEW IN_REVIEW COMPLETING COMPLETE].include?(readback.dig("attributes", "state"))
puts "SUBMITTED #{metadata.fetch('version')} (#{metadata.fetch('build')}) #{readback.dig('attributes','state')} AFTER_APPROVAL #{submission_id}"
