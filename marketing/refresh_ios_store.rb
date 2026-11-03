#!/usr/bin/env ruby
# Prepare and verify a specific App Store version. Submission is a separate step.
$stdout.sync = true
ENV["APP_STORE_VERSION"] = "1.14"
ENV["SCREENSHOT_DISPLAY_TYPE"] = "APP_IPHONE_67"
require_relative "app_store_screenshots"

command = ARGV.shift || "inspect"
abort "Use inspect or prepare" unless %w[inspect prepare].include?(command)
root = File.expand_path(ARGV.shift || "app-store/ios-refresh-20261103", __dir__)
metadata = JSON.parse(File.read(File.join(root, "metadata.json")))
expected_version = metadata.fetch("version")
abort "Unexpected version" unless expected_version == ENV.fetch("APP_STORE_VERSION")
files_by_locale = metadata.fetch("localizations").to_h do |locale, _|
  files = Dir[File.join(root, "posters", locale, "*.png")].sort
  abort "Expected five screenshots for #{locale}" unless files.length == 5
  files.each do |path|
    png = File.binread(path)
    abort "Invalid screenshot: #{path}" unless png.start_with?("\x89PNG\r\n\x1a\n".b) &&
      png.byteslice(16, 8).unpack("NN") == [1320, 2868] && png.getbyte(25) == 2
  end
  [locale, files]
end
app, version, localizations = discover(create_version: command == "prepare")
abort "Wrong app/version" unless app.fetch("id") == "6764277773" && version.dig("attributes", "versionString") == expected_version
puts "TARGET #{app.fetch('id')} #{expected_version} #{version.fetch('id')} #{version.dig('attributes','appStoreState')}"
exit if command == "inspect"

build = data(:get, "/v1/builds/#{metadata.fetch('buildID')}")
pre_release = data(:get, "/v1/builds/#{build.fetch('id')}/preReleaseVersion")
abort "Build is not eligible" unless build.dig("attributes", "version") == metadata.fetch("build") &&
  build.dig("attributes", "processingState") == "VALID" && !build.dig("attributes", "expired") &&
  pre_release.dig("attributes", "version") == expected_version

backups = []
metadata.fetch("localizations").each do |locale, copy|
  localization = localizations.find { |item| item.dig("attributes", "locale") == locale }
  abort "Missing localization #{locale}" unless localization
  id = localization.fetch("id")
  old_sets = data(:get, "/v1/appStoreVersionLocalizations/#{id}/appScreenshotSets?limit=50")
  backups << { localization: localization, sets: old_sets.map { |set| { set: set, screenshots: screenshots(set.fetch("id")) } } }
end
backup_path = File.join(root, "draft-before.json")
File.write(backup_path, JSON.pretty_generate({ version: version, localizations: backups })) unless File.exist?(backup_path)

receipts = []
metadata.fetch("localizations").each do |locale, copy|
  localization = localizations.find { |item| item.dig("attributes", "locale") == locale }
  id = localization.fetch("id")
  fields = copy.reject { |key, _| key == "subtitle" }
  data(:patch, "/v1/appStoreVersionLocalizations/#{id}", body: {
    data: { type: "appStoreVersionLocalizations", id: id, attributes: fields }
  })
  set = ensure_set(id)
  existing = screenshots(set.fetch("id"))
  wanted = files_by_locale.fetch(locale).map { |path| File.basename(path) }
  abort "Unexpected screenshots in destination set" unless existing.all? { |shot| wanted.include?(shot.dig("attributes", "fileName")) }
  uploaded = files_by_locale.fetch(locale).map do |path|
    checksum = Digest::MD5.file(path).hexdigest
    match = existing.find { |shot| shot.dig("attributes", "fileName") == File.basename(path) &&
      shot.dig("attributes", "sourceFileChecksum") == checksum && shot.dig("attributes", "assetDeliveryState", "state") == "COMPLETE" }
    unless match
      existing.select { |shot| shot.dig("attributes", "fileName") == File.basename(path) }.each { |shot| request(:delete, "/v1/appScreenshots/#{shot.fetch('id')}") }
      match = upload_file(set.fetch("id"), path)
      puts "UPLOADED #{locale} #{File.basename(path)}"
    end
    match.fetch("id")
  end
  wait_complete(uploaded)
  ordered = uploaded.map { |id| { type: "appScreenshots", id: id } }
  request(:patch, "/v1/appScreenshotSets/#{set.fetch('id')}/relationships/appScreenshots", body: { data: ordered })
  final = screenshots(set.fetch("id"))
  abort "Screenshot order/count mismatch" unless final.map { |s| s.fetch("id") } == uploaded
  files_by_locale.fetch(locale).zip(final).each do |path, shot|
    abort "Screenshot checksum mismatch" unless shot.dig("attributes", "sourceFileChecksum") == Digest::MD5.file(path).hexdigest
  end
  receipts << { locale: locale, setID: set.fetch("id"), screenshots: final }
  puts "VERIFIED #{locale} five ordered screenshots COMPLETE"
end

# Remove inherited smaller-size sets only after both replacements are verified.
backups.each do |backup|
  backup.fetch(:sets).each do |entry|
    set = entry.fetch(:set)
    next unless set.dig("attributes", "screenshotDisplayType") == "APP_IPHONE_65"
    request(:delete, "/v1/appScreenshotSets/#{set.fetch('id')}")
    puts "REMOVED inherited 6.5-inch set #{set.fetch('id')} from draft"
  end
end
updated = data(:patch, "/v1/appStoreVersions/#{version.fetch('id')}", body: {
  data: { type: "appStoreVersions", id: version.fetch("id"), attributes: { releaseType: "AFTER_APPROVAL" },
          relationships: { build: { data: { type: "builds", id: build.fetch("id") } } } }
})
readback = data(:get, "/v1/appStoreVersions/#{version.fetch('id')}/appStoreVersionLocalizations?limit=50")
metadata.fetch("localizations").each do |locale, copy|
  actual = readback.find { |l| l.dig("attributes", "locale") == locale }.fetch("attributes")
  copy.reject { |k, _| k == "subtitle" }.each { |key, value| abort "Copy readback mismatch: #{locale}/#{key}" unless actual[key] == value }
end
File.write(File.join(root, "prepared.json"), JSON.pretty_generate({ version: updated, buildID: build.fetch("id"), screenshots: receipts }))
puts "PREPARED #{expected_version} (#{metadata.fetch('build')}) AFTER_APPROVAL"
