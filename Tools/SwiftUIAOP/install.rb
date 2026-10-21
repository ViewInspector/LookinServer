#!/usr/bin/env ruby
# Requires xcodeproj (also installed with CocoaPods). Changes project configuration only.
require 'xcodeproj'
require 'pathname'
require 'shellwords'

abort 'Usage: ruby install.rb PROJECT.xcodeproj TARGET [SWIFT_MODULE]' unless (2..3).cover?(ARGV.length)
project_path = Pathname.new(ARGV[0]).expand_path
project = Xcodeproj::Project.open(project_path)
target = project.targets.find { |item| item.name == ARGV[1] }
abort "Target not found: #{ARGV[1]}" unless target
module_name = ARGV[2] || 'LookinServerSwift'
abort 'Invalid module name' unless module_name.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
root = project_path.dirname
relative = lambda { |path| '$(SRCROOT)/' + Pathname.new(path).relative_path_from(root).to_s }
script = relative.call(File.join(__dir__, 'prepare.sh'))
inputs = target.source_build_phase.files_references.compact.select { |file| file.real_path.extname == '.swift' }.map { |file| relative.call(file.real_path) }
abort 'No Swift Compile Sources found; add target source files first' if inputs.empty?
phase = target.shell_script_build_phases.find { |item| item.name == 'Lookin SwiftUI Debug AOP' } || target.new_shell_script_build_phase('Lookin SwiftUI Debug AOP')
target.build_phases.delete(phase)
target.build_phases.insert(0, phase)
phase.shell_path = '/bin/bash'
# Only expand SRCROOT; quote literal project/file names safely, including spaces.
shell_path = lambda { |path| '"$SRCROOT"/' + path.delete_prefix('$(SRCROOT)/').shellescape }
phase.shell_script = "export LOOKIN_SWIFT_MODULE=#{module_name.shellescape}\n/bin/bash #{shell_path.call(script)} #{inputs.map { |input| shell_path.call(input) }.join(' ')}\n"
phase.input_paths = inputs + [script, relative.call(File.join(__dir__, 'Instrument.swift'))]
phase.output_paths = ['$(DERIVED_FILE_DIR)/LookinSwiftUIAOP/overlay.json', '$(DERIVED_FILE_DIR)/LookinSwiftUIAOP/report.json']
phase.always_out_of_date = '1'
target.build_configurations.select { |config| config.name == 'Debug' }.each do |config|
  flags = config.build_settings['OTHER_SWIFT_FLAGS'] || ['$(inherited)']
  flags = Shellwords.split(flags) if flags.is_a?(String)
  overlay = '$(DERIVED_FILE_DIR)/LookinSwiftUIAOP/overlay.json'
  unless flags.include?(overlay)
    flags += ['-vfsoverlay', overlay]
  end
  config.build_settings['OTHER_SWIFT_FLAGS'] = flags
  config.build_settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
end
abort 'No Debug configuration; configure your Debug variant explicitly' unless target.build_configurations.any? { |config| config.name == 'Debug' }
project.save
puts "Enabled Debug SwiftUI AOP for #{target.name}: #{inputs.length} source inputs; business files unchanged."
