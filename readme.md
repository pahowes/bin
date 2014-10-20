# Introduction #

This is my `bin` directory that lives in my `${HOME}` directory on pretty much
every system. It contains useful scripts and small apps in a variety of
languages.

# What's In Here? #

* SublerCLI

  Downloaded from [Google Code](https://code.google.com/p/subler/downloads/detail?name=SublerCLI-0.19.zip&can=2&q=)

* convert2qt

  A Ruby script that depends on `ffprobe` and `ffmpeg` to analyze audio and
  audio/video files for conversion into a format that is recognized by Apple's
  QuickTime, iTunes, AppleTV, and other products. Audio files are converted to
  AAC-256 (or ALAC if the source was FLAC). Video files are converted to H.264
  with an AAC-160 stereo audio stream. If the video source contained an AC-3
  surround track, it is copied verbatim. DTS tracks are converted to AC-3.

* dupefinder

  Finds duplicate files across multiple file systems by computing a hash code,
  for each file which is stored in a SQLite database. Hash code collisions are
  considered duplicate files.

* mini-https

  A very small web server that runs on `localhost`. At present it's written in
  Ruby and is based on WEBrick which has been included with every distribution
  for quite some time.

* rsync\_backup.sh

  Copied from a [Gist](https://gist.github.com/tvwerkhoven/4541989)

* tweaksrt

  Applys an offset to each entry of an SRT file. Useful when the entire file is
  off by a little.
