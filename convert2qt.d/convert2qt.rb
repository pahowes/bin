#!/usr/bin/env ruby

#
# Converts any video file to QuickTime/iTunes compatible MP4 format.
#

require 'json'
require 'optparse'
require 'ruby-progressbar'
require 'shellwords'

#
# Command line parser
#
class Options
  #
  # Default options
  #
  @@options = {
    # Whether to convert to 480p.
    :P480 => false,

    # Whether to convert to 720p.
    :P720 => false,

    # Whether to dump the conversion command and exit.
    :dump => false,

    # Whether to dump the output from ffprobe and exit.
    :info => false,

    # Whether to include subtitles from the source file.
    :subs => false,

    # Files to convert.
    :files => []
  }

  def self.options
    @@options
  end

  def self.parse

    #
    # Parser definition
    #
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: convert2qt [options] files..."
      opts.on("-4", "--480", "Convert video to Standard Definition (480p)") do |sd|
        @@options[:P480] = sd
      end
      opts.on("-7", "--720", "Convert video to 720p HD") do |hd|
        @@options[:P720] = hd
      end
      opts.on("-d", "--dump", "Dump ffmpeg command and exit") do |d|
        @@options[:dump] = d
      end
      opts.on("-i", "--info", "Dump ffprobe output and exit") do |i|
        @@options[:info] = i
      end
      opts.on("-s", "--subtitles", "Convert subtitles from the source file") do |s|
        @@options[:subs] = s
      end
      opts.on_tail("-v", "--version", "Show version") do
        puts opts.ver()
        exit
      end
      opts.on_tail("-h", "--help", "Show this message") do
        puts opts
        exit
      end
    end
    parser.version = "0.3"
    parser.parse!(ARGV)
    @@options[:files] = ARGV
  end
end

#
# Executes a command in a subshell and returns whatever the command sent to
# STDOUT. The method returns an array that contains each line received from
# the child shell.
#
def execute(command_array, with_stderr = false)
  command_array << "2>/dev/null" unless with_stderr
  command_array << "2>&1" if with_stderr
  command = command_array.join(" ")

  output = []
  IO::popen command do |f|
    line = ""
    f.each_char do |c|
      if "\n" == c || "\r" == c
        output << line
        yield line if block_given?
        line = ""
      else
        line << c
      end
    end
    output << line
  end
  output
end

#
# Uses ffprobe to collect information about the file.
#
def probe(file)
  file = Shellwords.escape(file)
  command = [ "ffprobe", "-print_format json", "-show_format", "-show_streams", "#{file}" ]

  json = JSON.parse execute(command).join

  if Options.options[:info]
    pp json
    exit
  end

  info = {}
  info[:filename] = json["format"]["filename"]
  info[:duration] = json["format"]["duration"].to_i
  info[:video] = []
  info[:audio] = []
  info[:subtitle] = []

  # Note that the stream index value is not the index of the stream relative
  # to the file, it's the index relative to the number of that type of streams.
  # That is what ffmpeg expects when you specify something like "-map 0:a:0"
  # which means the first audio stream in the first input file, even if the
  # stream is the fifth found in the file.
  #
  json["streams"].each do |stream|
    if("video" == stream["codec_type"])
      info[:video] << {
        :index  => info[:video].count,
        :codec  => stream["codec_name"],
        :width  => stream["width"],
        :height => stream["height"]
      }
    elsif("audio" == stream["codec_type"])
      info[:audio] << {
        :index    => info[:audio].count,
        :codec    => stream["codec_name"],
        :channels => stream["channels"],
        :language => (stream["tags"] && stream["tags"]["language"]) ? stream["tags"]["language"].downcase : 'und',
        :title    => (stream["tags"] && stream["tags"]["title"]) ? stream["tags"]["title"] : 'Audio Track'
      }
    elsif("subtitle" == stream["codec_type"] && Options.options[:subs])
      info[:subtitle] << {
        :index    => info[:subtitle].count,
        :codec    => stream["codec_name"],
        :language => stream["tags"] ? stream["tags"]["language"] ? stream["tags"]["language"].downcase : 'eng' : 'eng',
        :title    => (stream["tags"] && stream["tags"]["title"]) ? stream["tags"]["title"] : 'Subtitle Track',
        :forced   => stream["disposition"]["forced"],
        :impared  => stream["disposition"]["hearing_impaired"]
      }
    end
  end

  return info
end

#
# Selects appropriate streams from those found in the file.
#
def select_streams(info)
  unless info[:video].empty?
    # There can be only one (video stream).
    info[:video] = info[:video].first
  end

  unless info[:audio].empty?
    audio_streams = []
    audio_stream = nil

    # Finds the highest quality English audio stream available
    info[:audio].each do |s|
      if s[:language] == 'eng'
        # Surround tracks
        audio_stream ||= s if s[:codec] == 'dts'    # DTS
        audio_stream ||= s if s[:codec] == 'dca'    # DTS (older ffmpeg)
        audio_stream ||= s if s[:codec] == 'eac3'   # Dolby Digital Plus
        audio_stream ||= s if s[:codec] == 'ac3'    # Dolby Digital
        # Stereo tracks
        audio_stream ||= s if s[:codec] == 'alac'   # Apple lossless
        audio_stream ||= s if s[:codec] == 'flac'   # Open-source lossless
        audio_stream ||= s if s[:codec] == 'opus'   # Open-source lossy
        audio_stream ||= s if s[:codec] == 'aac'    # AAC
        audio_stream ||= s if s[:codec] == 'vorbis' # OGG Vorbis
        audio_stream ||= s if s[:codec] == 'mp3'    # MP3
      end
    end

    audio_streams << audio_stream if audio_stream != nil

    # Adds all of the non-English audio streams.
    info[:audio].each do |s|
      if s[:language] != 'eng'
        audio_streams << s
      end
    end

    info[:audio] = audio_streams
  end
  
  unless info[:subtitle].empty?
    # Removes all non-english subtitle streams.
    info[:subtitle].delete_if { |s| s[:language] != 'eng' }

    # Removes Bluray PGS subtitles because ffmpeg doesn't have encoding nor OCR support.
    info[:subtitle].delete_if { |s| s[:codec] == 'hdmv_pgs_subtitle' }

    # Removes subtitles marked as "signs and songs" which are usually forced.
    info[:subtitle].delete_if { |s| s[:title].downcase.include? 'sign' }

    # Default to the last subtitle stream (first one is usually forced subs)
    info[:subtitle] = info[:subtitle].last
  end

  return info
end

#
# Converts an audio stream to AAC stereo
#
def convert_audio_to_aac(stream, index)
  disposition = (index == 0) ? 'default' : 'none'
  return [ "-map 0:a:#{stream[:index]}",
           "-metadata:s:a:#{index} title='Stereo Track'",
           "-metadata:s:a:#{index} language=#{stream[:language]}",
           "-disposition:a:#{index} #{disposition}",
           "-codec:a:#{index} aac",
           "-ar:a:#{index} 48k",
           "-ab:a:#{index} 160k",
           "-ac:a:#{index} 2" ]
end

#
# Converts an audio stream to AC3 5.1 Surround
#
def convert_audio_to_ac3(stream, index)
  args = [ "-map 0:a:#{stream[:index]}",
           "-metadata:s:a:#{index} title='Surround Track'",
           "-metadata:s:a:#{index} language=#{stream[:language]}",
           "-disposition:a:#{index} none",
           "-codec:a:#{index} ac3",
           "-ar:a:#{index} 48k",
           "-ab:a:#{index} 448k",
           "-ac:a:#{index} 6" ]

    # DCA (DTS) is usually too quiet when converted to AAC.
    args << "-af:a:#{index} volume=2.0" if 'dca' == stream[:codec]

    return args
end

#
# Copies an audio stream since it's already in an acceptable format
#
def copy_audio(stream, index)
  disposition = (index == 0) ? 'default' : 'none'
  title = (stream[:channels] > 2) ? 'Surround Track' : 'Stereo Track'
  return [ "-map 0:a:#{stream[:index]}",
           "-metadata:s:a:#{index} title='#{title}'",
           "-metadata:s:a:#{index} language=#{stream[:language]}",
           "-disposition:a:#{index} #{disposition}",
           "-codec:a:#{index} copy" ]
end

#
# Returns the parameters needed to convert an audio stream.
# 
def convert_audio(stream, index)
  args = []

  # If this is the first audio stream in an MP4 video file, and it contains more than two channels, a stereo AAC
  # version of the stream is needed to satisfy strict MP4 clients, like QuickTime. Then the original multi-channel
  # stream can be added, below.
  if index == 0 && stream[:channels] > 2
    args << convert_audio_to_aac(stream, index)
    index = 1
  end

  if stream[:channels] > 2
    # Ensure that multi-channel audio is in AC3 format.
    case stream[:codec]
    when 'ac3', 'eac3'
      args << copy_audio(stream, index)
    else
      args << convert_audio_to_ac3(stream, index)
    end
  else
    # Ensure that stereo audio is in AAC format.
    if stream[:codec] == 'aac'
      args << copy_audio(stream, index)
    else
      args << convert_audio_to_aac(stream, index)
    end
  end

  return (index + 1), args
end

#
# Uses ffmpeg to convert the file to MP4 format.
#
def convert(file_info)
  input_name = Shellwords.escape(file_info[:filename])
  input_suffix = File.extname input_name
  output_name = File.basename input_name, input_suffix
  output_suffix = "mp4"
  command = [ "ffmpeg", "-y", "-i #{input_name}", "-max_muxing_queue_size 9999", "-map_chapters -1" ]

  if (file_info[:video].empty? && !file_info[:audio].empty?) || input_suffix == '.flac' || input_suffix == '.mp3' || input_suffix == '.aiff'
    #
    # Audio-only files are converted to either ALAC if the source was FLAC, or
    # AAC for all other formats.
    #
    stream = file_info[:audio][0]
    case stream[:codec]
    when "alac"
      command << "-map 0:a:#{stream[:index]}" << "-codec:a copy"
    when "flac"
      command << "-map 0:a:#{stream[:index]}" << "-codec:a alac"
    when "mp3"
      command << "-map 0:a:#{stream[:index]}" << "-codec:a alac"
    else
      command << "-map 0:a:#{stream[:index]}" << "-codec:a aac" << "-ar:a:0 48k" << "-ab:a 256k"
    end
    output_suffix = "m4a"
  elsif !file_info[:video].empty? && !file_info[:audio].empty?
    command << "-map_metadata -1"

    # The number of channel maps and languages depends on the number of audio
    # channels, so the information is collected here and inserted into the
    # command later.
    maps  = [ "-map 0:v:0" ]
    langs = [ "-metadata:s:v:0 language=und", "-metadata:s:v:0 title='Video Track'"]

    #
    # The video track is copied if the codec is h265 (hevc) and a video tag
    # is added so that Apple products understand the format. Otherwise, the
    # video track is copied if it's in h264 format and the frame size is
    # to remain the same, or it's converted to h264 using high-quality
    # settings.
    #
    if "hevc" == file_info[:video][:codec]
      command << "-codec:v copy -vtag hvc1"
    elsif "h264" == file_info[:video][:codec] && !Options.options[:P480] && !Options.options[:P720]
      command << "-codec:v copy"
    else
      # This converts the video using settings that provide nearly visual
      # lossless results.
      output_suffix = "mp4"
      command << "-codec:v libx265" << "-vtag hvc1" << "-preset:v slow"
      command << (file_info[:video][:width] > 1000 ? '-profile:v high' : '-profile:v main')
      command << "-crf:v 18" << "-threads:v 0"

      # Converts HD video to wide-screen 720P if necessary.
      command << "-vf:v scale=1280:-1" if Options.options[:P720]

      # Converts HD video to wide-screen 480P if necessary.
      command << "-vf:v scale=854:-1" if Options.options[:P480]
    end

    # Convert all of the audio tracks to AAC (stereo) and AC3 (multi-channel)
    index = 0
    file_info[:audio].each do |stream|
      index, c = convert_audio(stream, index)
      command << c
    end

    if file_info.key?(:subtitle) && !file_info[:subtitle].nil? && !file_info[:subtitle].empty?
      command << "-map 0:s:#{file_info[:subtitle][:index]}" << "-metadata:s:s:0 language=eng" << "-metadata:s:s:0 title='Subtitle Track'"
      command << ('dvd_subtitle' == file_info[:subtitle][:codec] ? "-codec:s:0 copy" : "-codec:s:0 mov_text")
    end

    # Now insert the maps into the command
    command.insert 4, maps.concat(langs)
  end

  command << "#{output_name}.#{output_suffix}"

  if Options.options[:dump]
    puts command.join(' ')
    exit
  end

  #
  # Starts the transcoding process.
  #
  puts file_info[:filename]
  progress = ProgressBar.create(:format => "%t |%B| %e",
                                :total  => file_info[:duration] + 1,
                                :title  => "Encoding Progress")
  execute(command, true) do |line|
    begin
      line.match /time=(\d\d):(\d\d):(\d\d)/ do |match|
        if match.length == 4
          time = match[1].to_i * 3600 + match[2].to_i * 60 + match[3].to_i
          progress.progress = time
        end
      end
    rescue
      # Some UTF-8 characters can cause match to throw, but these characters are not used by this script.
    end
  end
  progress.finish
end

Options.parse
Options.options[:files].each do |file|
  file_info = probe file
  stream_info = select_streams file_info
  convert stream_info
end

