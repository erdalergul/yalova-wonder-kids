# Codemagic derlemesinde Xcode proje ayarlarını otomatik yapar
# (Mac olmadığı için Xcode'da elle yapılacak ayarların yerine geçer).
require 'xcodeproj'

BUNDLE_ID = ENV['BUNDLE_ID'] || 'com.yalovawonderkids.app'
proje = Xcodeproj::Project.open(File.join(__dir__, 'Runner.xcodeproj'))

proje.build_configurations.each do |c|
  c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
end

runner = proje.targets.find { |t| t.name == 'Runner' }
runner.build_configurations.each do |c|
  c.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = BUNDLE_ID
  c.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'Runner/Runner.entitlements'
  c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
  c.build_settings['TARGETED_DEVICE_FAMILY'] = '1' # yalnızca iPhone
end

grup = proje.main_group['Runner']
unless grup.files.any? { |f| f.path == 'Runner.entitlements' }
  grup.new_file('Runner.entitlements')
end

proje.save
puts "iOS ayarlandı: #{BUNDLE_ID}"
