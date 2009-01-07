desc "Generate static objects"
task :default => [ 'statics:html', 'statics:css' ]

namespace :statics do

  PUBLIC_ROOT = File.expand_path(File.dirname(__FILE__) + '/public')

  desc "Generate static documents"
  task :html do
    Dir.glob(PUBLIC_ROOT + '/**/*.haml').each do |fn|
      system "haml #{fn} > #{fn.gsub(/\.haml$/, '.html')}"
    end
  end

  desc "Generate static stylesheets"
  task :css do
    Dir.glob(PUBLIC_ROOT + '/**/*.sass').each do |fn|
      system "sass #{fn} > #{fn.gsub(/\.sass$/, '.css')}"
    end
  end
end
