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


def run_nunit_test(test_to_run, dll_path)
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

  command = params.join(' ')

  puts
  puts "\e[32m#{command}\e[0m"
  puts

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
    test_to_run: nil,
    device: nil,
    os: nil,
    emulator_serial: nil
}

parser = OptionParser.new do |opts|
  opts.banner = 'Usage: step.rb [options]'
  opts.on('-s', '--project path', 'Project path') { |s| options[:project] = s unless s.to_s == '' }
  opts.on('-c', '--configuration config', 'Configuration') { |c| options[:configuration] = c unless c.to_s == '' }
  opts.on('-p', '--platform platform', 'Platform') { |p| options[:platform] = p unless p.to_s == '' }
  opts.on('-t', '--test test', 'Test to run') { |t| options[:test_to_run] = t unless t.to_s == '' }
  opts.on('-d', '--device device', 'Device') { |d| options[:device] = d unless d.to_s == '' }
  opts.on('-o', '--os os', 'OS') { |o| options[:os] = o unless o.to_s == '' }
  opts.on('-e', '--emulator serial', 'Emulator serial') { |e| options[:emulator_serial] = e unless e.to_s == '' }
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
puts " * test_to_run: #{options[:test_to_run]}"

#
# Validate options
fail_with_message('No project file found') unless options[:project] && File.exist?(options[:project])
fail_with_message('configuration not specified') unless options[:configuration]
fail_with_message('platform not specified') unless options[:platform]

#
# Main
run_ios_test = false
run_android_test = false

if options[:device] &&  options[:os]
  puts " * simulator_device: #{options[:device]}"
  puts " * simulator_os: #{options[:os]}"

  udid, state = simulator_udid_and_state(options[:device], options[:os])
  fail_with_message('failed to get simulator udid') unless udid || state

  puts " * simulator_UDID: #{udid}"

  ENV['IOS_SIMULATOR_UDID'] = udid

  run_ios_test = true
end

if options[:emulator_serial]
  puts " * emulator_serial: #{options[:emulator_serial]}"

  ENV['ANDROID_EMULATOR_SERIAL'] = options[:emulator_serial]

  run_android_test = true
end

fail_with_message('No ios simulator or android emulator defined') if !run_ios_test && !run_android_test

builder = Builder.new(options[:project], options[:configuration], options[:platform], nil)
# begin
  builder.build
  builder.build_test
# rescue
#   fail_with_message('Build failed')
# end

dll_path = nil

output = builder.generated_files

puts
puts "Generated outputs: #{output}"
puts

output.each do |_, project_output|
  if run_android_test && project_output[:apk] && project_output[:uitests] && project_output[:uitests].length > 0
    dll_path = project_output[:uitests][0]
    ENV['ANDROID_APK_PATH'] = project_output[:apk]

    puts " (i) testing android: (#{project_output[:apk]}) with (#{dll_path})"
  elsif run_ios_test && project_output[:app] && project_output[:uitests] && project_output[:uitests].length > 0
    dll_path = project_output[:uitests][0]
    ENV['APP_BUNDLE_PATH'] = project_output[:app]

    puts " (i) testing ios: (#{project_output[:app]}) with (#{dll_path})"
  end
end

run_nunit_test(options[:test_to_run], dll_path)

#
# Set output envs
puts
puts '(i) The result is: succeeded'
system('envman add --key BITRISE_XAMARIN_TEST_RESULT --value succeeded')

puts
puts "(i) The test log is available at: #{@result_log_path}"
system("envman add --key BITRISE_XAMARIN_TEST_FULL_RESULTS_TEXT --value #{@result_log_path}") if @result_log_path
