#!/usr/local/bin/ruby

require 'digest/sha2'
require 'optparse'
require 'json'

# brew install tokyo-cabinet
# gem install tokeycabinet
require 'tokyocabinet'
include TokyoCabinet

class DupeFinder
  # Sets up the command line parser.  Everything that is parsed can be found
  # in @options.
  def parse_options
    parser = OptionParser.new do |opts|
      # Help screen banner.
      opts.banner = "Usage: dupefinder.rb [options] file1 file2"
      opts.separator ''
      opts.separator 'Each file is an Aperture library or directory that contains image files.'
      opts.separator 'All of the master files in the library are hashed and stored in the database.'
      opts.separator 'The first file specified is considered to be the authority against which all '
      opts.separator 'others are compared against for duplicates'
      opts.separator 'and missing files.'
      opts.separator ''
      opts.separator 'Specific options:'

      # Database path
      @options[:db_path] = 'dupes.db'
      opts.on('-f', '--db-file PATH', 'Path to the database file.') do |path|
        @options[:db_path] = path
      end

      @options[:flag_adds] = true
      opts.on('-a', '--[no-]flag-adds', 'Log files that are added to the database.') do |flag|
        @options[:flag_adds] = flag
      end

      @options[:flag_dupes] = true
      opts.on('-d', '--[no-]flag-dupes', 'Log files that are already in the database.') do |flag|
        @options[:flag_dupes] = flag
      end

      opts.separator ''
      opts.separator 'Common options:'

      opts.on_tail('-h', '--help', 'Display this screen.') do
        puts opts
        exit
      end
    end
    parser.parse! ARGV
  end

  # Opens and creates the database.  The connection can be found in @database.
  def setup_database
    # If the database does not exist, then files added from the first library
    # are not logged.
    if(!File.file?(@options[:db_path]))
      @flag_adds = false
    end

    # Creates/opens the database.
    @database = HDB::new
    if(!@database.open(@options[:db_path], HDB::OWRITER | HDB::OCREAT))
      STDERR.printf("open error: %s\n", @database.errmsg(@database.ecode));
      exit
    end
  end

  # Adds a file to the database.  Returns the hash and the file that was added.  If the 
  def add_file(path)
    # Array of files for this hash.
    files = []
    files << path

    # Hash the file.
    hash = Digest::SHA2.hexdigest(File.read(path))

    # Determines whether other files with this hash already exist.
    existing = @database.get(hash)
    if(existing)
      files = files + JSON.parse(existing)
      if(@options[:flag_dupes])
        puts "Duplicates found: #{files}"
      end
    elsif(!existing && @flag_adds)
      puts "Adding #{path}"
    end

    # Puts all of the files into the data store.
    if(!@database.put(hash, files.to_json))
       STDERR.printf("Put error: %s\n", @database.errmsg(@database.ecode))
    end
  end

  # Runs the program.
  def initialize
    @database = nil
    @flag_adds = true
    @options = {}

    parse_options
    setup_database

    ARGV.each do |path|
      # After the first library has been processed, start logging additions
      # as well as duplicates, if set in the options hash.
      if(path != ARGV[0])
        @flag_adds = @options[:flag_adds]
      end

      puts "Processing #{path}"
      files = []

      aplib = path =~ /\.aplibrary$/
      if(aplib && aplib > 0)
        # Path is an aperture library
        master_path = File.join(path, 'Masters')
        files = Dir[File.join(master_path, '**/**/**/**')]
      else
        # Path is just a directory.
        files = Dir.glob(File.join(path, '**/*'))
      end

      # Process the files found
      files.each do |file|
        if(File.file?(file))
          add_file(file)
        end
      end
    end

    # Close the database file.
    if(!@database.close)
      STDERR.printf('Close error: %s\n', @database.errmsg(@database.ecode));
    end
  end
end

# Fire it up!
DupeFinder.new
