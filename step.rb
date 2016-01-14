require 'optparse'
require 'pathname'
require 'timeout'

require_relative 'xamarin-builder/builder'

# -----------------------
# --- Constants
# -----------------------

@mdtool = "\"/Applications/Xamarin Studio.app/Contents/MacOS/mdtool\""
@mono = '/Library/Frameworks/Mono.framework/Versions/Current/bin/mono'
@nuget = '/Library/Frameworks/Mono.framework/Versions/Current/bin/nuget'

@work_dir = ENV['BITRISE_SOURCE_DIR']
@result_log_path = File.join(@work_dir, 'TestResult.xml')

# -----------------------
# --- Functions
# -----------------------

def fail_with_message(message)
  `envman add --key BITRISE_XAMARIN_TEST_RESULT --value failed`

  puts "\e[31m#{message}\e[0m"
  exit(1)
end

def error_with_message(message)
  puts "\e[31m#{message}\e[0m"
end

def to_bool(value)
  return true if value == true || value =~ (/^(true|t|yes|y|1)$/i)
  return false if value == false || value.nil? || value == '' || value =~ (/^(false|f|no|n|0)$/i)
  fail_with_message("Invalid value for Boolean: \"#{value}\"")
end

def simulator_udid_and_state(simulator_device, os_version)
  os_found = false
  os_regex = "-- #{os_version} --"
  os_separator_regex = '-- iOS \d.\d --'
  device_regex = "#{simulator_device}" + '\s*\(([\w|-]*)\)\s*\(([\w]*)\)'

  out = `xcrun simctl list | grep -i --invert-match 'unavailable'`
  out.each_line do |line|
    os_separator_match = line.match(os_separator_regex)
    os_found = false unless os_separator_match.nil?

    os_match = line.match(os_regex)
    os_found = true unless os_match.nil?

    next unless os_found

    match = line.match(device_regex)
    unless match.nil?
      udid, state = match.captures
      return udid, state
    end
  end
  nil
end

def xcode_major_version!
  out = `xcodebuild -version`
  begin
    version = out.split("\n")[0].strip.split(' ')[1].strip.split('.')[0].to_i
  rescue
    fail_with_message('failed to get xcode version') unless version
  end
  version
end

def boot_simulator!(udid, xcode_major_version)
  simulator_cmd = '/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app'
  simulator_cmd = '/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/Applications/iPhone Simulator.app' if xcode_major_version == 6
  fail_with_message("invalid xcode_major_version (#{xcode_major_version})") unless simulator_cmd

  `open #{simulator_cmd} --args -CurrentDeviceUDID #{udid}`
  fail_with_message("open \"#{simulator_cmd}\" --args -CurrentDeviceUDID #{udid} -- failed") unless $?.success?

  begin
    Timeout.timeout(300) do
      loop do
        sleep 2 # seconds
        out = `xcrun simctl openurl #{udid} https://www.google.com 2>&1`
        puts '    => waiting for boot ...'
        puts "#{out}"

        break if out == ''
      end
    end
  rescue Timeout::Error
    fail_with_message('simulator boot timed out')
  end
  sleep 2
end

def run_test_on_apk(test_to_run, apk_path, dll_path)
  puts
  puts '=> Running android test'
  puts " (i) testing (#{apk_path}) with (#{dll_path})"

  # run_unit_test!(dll_path, test_to_run)
end

def run_test_on_app(test_to_run, app_path, dll_path)
  puts
  puts '=> Running ios test'
  puts " (i) testing (#{app_path}) with (#{dll_path})"

  ENV['APP_BUNDLE_PATH'] = app_path

  # run_unit_test!(dll_path, test_to_run)
end


def run_unit_test!(dll_path, test_to_run)
  nunit_path = ENV['NUNIT_PATH']
  fail_with_message('No NUNIT_PATH environment specified') unless nunit_path

  nunit_console_path = File.join(nunit_path, 'nunit3-console.exe')
  timeout_milliseconds = 10 * 60000 # 10 min

  params = []
  params << @mono
  params << nunit_console_path
  params << "--test=\"#{test_to_run}\"" unless test_to_run.to_s == ''
  params << "--timeout=#{timeout_milliseconds}"
  params << dll_path

  # home = ENV['HOME']
  # nunit_console_path = File.join(home, "Downloads/NUnit-2.6.4/bin/nunit-console.exe")
  #
  # params = []
  # params << @mono
  # params << nunit_console_path
  # params << "-run=\"#{test_to_run}\"" unless test_to_run.to_s == ''
  # params << dll_path

  command = params.join(' ')
  puts "command: #{command}"

  system(command)

  unless $?.success?
    file = File.open(@result_log_path)
    contents = file.read
    file.close

    puts
    puts "result: #{contents}"
    puts

    fail_with_message("#{command} -- failed")
  end
end

# -----------------------
# --- Main
# -----------------------

#
# Parse options
options = {
    project: nil,
    configuration: nil,
    platform: nil,
    clean_build: true,
    test_to_run: nil,
    device: nil,
    os: nil
}

parser = OptionParser.new do |opts|
  opts.banner = 'Usage: step.rb [options]'
  opts.on('-s', '--project path', 'Project path') { |s| options[:project] = s unless s.to_s == '' }
  opts.on('-c', '--configuration config', 'Configuration') { |c| options[:configuration] = c unless c.to_s == '' }
  opts.on('-p', '--platform platform', 'Platform') { |p| options[:platform] = p unless p.to_s == '' }
  opts.on('-i', '--clean build', 'Clean build') { |i| options[:clean_build] = false unless to_bool(i) }
  opts.on('-t', '--test test', 'Test to run') { |t| options[:test_to_run] = t unless t.to_s == '' }
  opts.on('-d', '--device device', 'Device') { |d| options[:device] = d unless d.to_s == '' }
  opts.on('-o', '--os os', 'OS') { |o| options[:os] = o unless o.to_s == '' }
  opts.on('-h', '--help', 'Displays Help') do
    exit
  end
end
parser.parse!

#
# Print options
puts
puts '========== Configs =========='
puts " * project: #{options[:project]}"
puts " * configuration: #{options[:configuration]}"
puts " * platform: #{options[:platform]}"
puts " * clean_build: #{options[:clean_build]}"
puts " * test_to_run: #{options[:test_to_run]}"
puts " * simulator_device: #{options[:device]}"
puts " * simulator_os: #{options[:os]}"

#
# Validate options
fail_with_message('No project file found') unless options[:project] && File.exist?(options[:project])
fail_with_message('configuration not specified') unless options[:configuration]
fail_with_message('platform not specified') unless options[:platform]
fail_with_message('simulator_device not specified') unless options[:device]
fail_with_message('simulator_os_version not specified') unless options[:os]

udid, state = simulator_udid_and_state(options[:device], options[:os])
fail_with_message('failed to get simulator udid') unless udid || state

puts " * simulator_UDID: #{udid}"

ENV['IOS_SIMULATOR_UDID'] = udid
system("envman add --key IOS_SIMULATOR_UDID --value #{udid}")

# xcode_version = xcode_major_version!
# boot_simulator!(udid, xcode_version)

#
# Main
builder = Builder.new(options[:project], options[:configuration], options[:platform], nil)
# begin
builder.build
builder.build_test
output = builder.generated_files

puts
puts "output: #{output}"
puts

output.each do |project_id, project_output|
  if project_output[:apk] && project_output[:uitests]
    run_test_on_apk(options[:test_to_run], project_output[:apk], project_output[:uitests])
  elsif project_output[:app] && project_output[:uitests]
    run_test_on_app(options[:test_to_run], project_output[:app], project_output[:uitests])
  end
end

#
# projects_to_test.each do |project_to_test|
#   project = project_to_test[:project]
#   test_project = project_to_test[:test_project]
#
#   puts
#   puts " ** project to test: #{project[:path]}"
#   puts " ** related test project: #{test_project[:path]}"
#
#   builder = Builder.new(project[:path], project[:configuration], project[:platform])
#   test_builder = Builder.new(test_project[:path], test_project[:configuration], test_project[:platform])
#
#   #
#   # Clean projects
#   if options[:clean_build]
#     builder.clean!
#     test_builder.clean!
#   end
#
#   #
#   # Build project
#   puts
#   puts "==> Building project: #{project}"
#
#   built_projects = builder.build!
#
#   app_path = nil
#
#   built_projects.each do |built_project|
#     if built_project[:api] == MONOTOUCH_API_NAME || built_project[:api] == XAMARIN_IOS_API_NAME && !built_project[:is_test]
#       app_path = builder.export_app(built_project[:output_path])
#     end
#   end
#
#   fail_with_message('failed to get .app path') unless app_path
#   puts "  (i) .app path: #{app_path}"
#   ENV['APP_BUNDLE_PATH'] = app_path
#
#   #
#   # Build UITest
#   puts
#   puts "==> Building test project: #{test_project}"
#
#   built_projects = test_builder.build!
#
#   dll_path = nil
#
#   built_projects.each do |built_project|
#     if built_project[:is_test]
#       puts "built_project[:assembly_name]: #{built_project[:assembly_name]}"
#       dll_path = test_builder.export_dll(built_project[:assembly_name], built_project[:output_path])
#     end
#   end
#
#   fail_with_message('failed to get .dll path') unless dll_path
#   puts "  (i) .dll path: #{dll_path}"
#
#   #
#   # Run unit test
#   puts
#   puts '=> Run unit test'
#   run_unit_test!(dll_path, options[:test_to_run])
# end
#
# #
# # Set output envs
# puts
# puts '(i) The result is: succeeded'
# system('envman add --key BITRISE_XAMARIN_TEST_RESULT --value succeeded')
#
# puts
# puts "(i) The test log is available at: #{@result_log_path}"
# system("envman add --key BITRISE_XAMARIN_TEST_FULL_RESULTS_TEXT --value #{@result_log_path}") if @result_log_path
