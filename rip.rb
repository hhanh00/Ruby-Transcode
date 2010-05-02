require 'Win32/Console/ANSI'
require 'WIN32OLE'
require "fileutils"
require "yaml"

# Output text in red
def red(text)
    puts "\033[0;31;40m#{text}\033[0m"
end

# Output text in green
def green(text)
    puts "\033[0;32;40m#{text}\033[0m"
end

# Output text in cyan
def cyan(text)
    puts "\033[0;36;40m#{text}\033[0m"
end

# Read and merge both config files
def read_config
  config = YAML::load_file('config.yaml')
  project = YAML::load_file('dvdrip.yaml')
  project.merge!(config)
  project
end

project = read_config()

# Read global settings
$x264preset = project["x264preset"]
$tempdir = project["tempdir"]
$clonedrivePath = project["clonedrive"]["path"]
$clonedriveLetter = project["clonedrive"]["letter"]
$clonedriveIndex = project["clonedrive"]["index"]

$decrypterPath = project["decrypter"]
$meguiPath = project["megui"]
$mkvmergePath = "#{$meguiPath}\\tools\\mkvmerge\\mkvmerge.exe"
$demuxPath = "#{$meguiPath}\\tools\\dgindex\\DGIndex.exe"

$is64OS = !ENV['PROCESSOR_ARCHITEW6432'].nil?

$last_mounted = nil

class Crop
  attr_reader :top, :bottom, :left, :right
  def initialize(left, top, right, bottom)
    @left = left
    @top = top
    @right = right
    @bottom = bottom
  end
  def to_s
    "%d/%d/%d/%d" % [@left, @top, @right, @bottom]
  end
end

# Video settings
class Video
  attr_accessor :crop
  attr_reader :bitrate, :dx, :dy, :autocrop
  def initialize(crop, bitrate)
    @crop = crop
    @autocrop = crop.nil?
    @bitrate = bitrate
  end
  
  def set_dar(dar)
    dar =~ /(\d+):(\d+)/
    darX, darY = $1.to_i, $2.to_i
    @dx = darX * 2
    @dy = darY * 3
  end
end

# Audio settings
class Audio
  attr_reader :language, :priority
  def initialize(language, priority)
    @language = language.encode("ISO-8859-1")
    @priority = priority
  end
  def to_s
    "Audio #{@language}"
  end
end

# Subtitle settings
class Sub
  attr_reader :language, :priority
  def initialize(language, priority)
    @language = language.encode("ISO-8859-1")
    @priority = priority
  end
  def to_s
    "Sub #{@language}"
  end
end

class Disk
  attr_reader :image, :ord, :drive_letter, :title_map
  def initialize(image, ord)
    @image = image
    if @image =~ /\.ISO$/i then
      @is_image = true
      @drive_letter =  $clonedriveLetter
    else
      @is_image = false
      @drive_letter = @image
    end
    @ord = ord
  end
  
  def mount
    if @is_image && $last_mounted != @image then
      green("Mounting image file #{@image}")
      mount_cmd = "\"#{$clonedrivePath}\" -mount #{$clonedriveIndex},\"#{@image}\""
      %x{#{mount_cmd}}
      sleep 10
      $last_mounted = @image
    end
  end

  # Get the duration of a VTS/PGC
  def parse_len(vts, pgc)
    path = "#{@drive_letter}:\\VIDEO_TS\\VTS_#{'%02d' % vts}_0.IFO"
    File::open(path, 'r') do |f|
      x = f.read(0x100)
      offset_of_pgciti = x[0xCC...0xD0].unpack('N').first
      f.seek(offset_of_pgciti * 0x800 + 8 * pgc)
      x = f.read(8)
      offset_of_pgci = x[4...8].unpack('N').first
      f.seek(offset_of_pgciti * 0x800 + offset_of_pgci)
      x = f.read(16)
      ts = x[4...7].unpack('CCC')
      ts = ts.map { |x| ((x & 0xF0) >> 4) * 10 + (x & 0x0F) }
      return Time.utc(2000, 1, 1, ts[0], ts[1], ts[2], 0) - Time.utc(2000)
    end
  end
  
  # Read the audio language codes of a VTS/PGC
  def parse_audio_langcode(vts, pgc)
    path = "#{@drive_letter}:\\VIDEO_TS\\VTS_#{'%02d' % vts}_0.IFO"
    langcode = []
    File::open(path, 'r') do |f|
      f.seek(0x200)
      x = f.read(0x100)
      num_audio_streams = x[2...4].unpack('n').first
      (0..num_audio_streams).each do |i|
        beg = 6 + i * 8
        langcode << x[beg...beg+2]
        end
    end
    langcode
  end

  # Read the subtitle language codes of a VTS/PGC
  def parse_sub_langcode(vts, pgc)
    path = "#{@drive_letter}:\\VIDEO_TS\\VTS_#{'%02d' % vts}_0.IFO"
    langcode = []
    File::open(path, 'r') do |f|
      f.seek(0x200)
      x = f.read(0x200)
      num_audio_streams = x[0x54...0x56].unpack('n').first
      (0..num_audio_streams).each do |i|
        beg = 0x58 + i * 6
        langcode << x[beg...beg+2]
        end
    end
    langcode
  end

  # Parse the Video Manager Group of a disk
  # Fill the title_map table
  def parse_vmg
    green("Parsing Video Manager IFO")
    path = "#{@drive_letter}:\\VIDEO_TS\\VIDEO_TS.IFO"
    @title_map = []
    @title_map[0] = { :length => 0 }
    File::open(path, 'r') do |f|
      x = f.read(0x100)
      offset_of_srpt = x[0xC4...0xC8].unpack('N').first
      f.seek(offset_of_srpt * 0x800)
      x = f.read(0x200)
      titles = x[0...2].unpack('n').first
      offset = 8
      (1..titles).each do |i| 
        a = x.slice(offset, 12).unpack("ccnnccN")
        vts = a[4]
        pgc = a[5]
        @title_map[i] = { :vts => vts, :pgc => pgc, :length => parse_len(vts, pgc), 
          :audio_langcode => parse_audio_langcode(vts, pgc),
          :sub_langcode => parse_sub_langcode(vts, pgc) }
        offset += 12
      end
    end
  end
end

# Base class of the track streams
class Stream
  attr_reader :id, :index, :info, :stream
  attr_accessor :mux_index
  def initialize(track, id, index, info, stream)
    @track = track
    # Stream id
    @id = id
    # Index of this stream among streams of the same type
    @index = index
    @info = info
    @stream = stream
  end
  
  def encode
  end
  
  def track_list
    # Stream position in the muxed file
    "#{@mux_index}:0"
  end
end

class AudioStream < Stream
  attr_reader :audio_filename, :channels
  def initialize(track, id, index, channels, info, stream)
    super track, id, index, info, stream
    @channels = channels
    track_number = "T%02x" % id
    @audio_filename = Dir.foreach(@track.tempdir).find { |f| f =~ /#{track_number}/ }
    @audio_filename =~ /DELAY (.*)ms/
    @delay = $1.to_i
    @path = "#{@track.tempdir}\\#{@audio_filename}"
  end
  
  def mux
    lang = @track.disk.title_map[@track.title][:audio_langcode][@index]
    "--language 0:#{lang} " +
    "--sync 0:#{@delay} " +
    "-D -a 0 -S -T \"#{@path}\""
  end
  
  def encode
    @track.size -= size unless @track.size.nil?
  end
  
  def size
    File.size(@path)
  end
  
  def merit
    # Keep original stream order among audio files
    1 + Integer(@id).to_f / 1000
  end
end

class VideoStream < Stream
  def initialize(track, id, info, stream)
    super track, id, 0, info, stream
    @path = "#{@track.tempdir}\\VTS_#{'%02d' % @track.vts}"
  end
  
  def encode
    precrop_avs
    autocrop
    avs
    autobitrate
    qpfile
    make_file ("#{@path}.stats") {
      encode1
    }
    make_file ("#{@path}.264") {
      encode2
    }
  end
  
  def round_to(x, prec)
    (x / prec).round * prec
  end
  
  def mux
    path = "#{@path}.264"
    vs = @track.video_stream
    c = vs.crop
    ar = round_to((720 - c.left - c.right ).to_f / (480 - c.top - c.bottom) * vs.dx / vs.dy, 0.01)
    "--default-duration 0:#{@track.fps}000/1001fps --aspect-ratio 0:#{ar} " +
    "-d 0 -A -S -T \"#{path}\""
  end
  
  def merit
    0
  end

private
  def precrop_avs
    c = @track.video_stream.crop
    x = <<EOS
LoadPlugin("#{$meguiPath}\\tools\\dgindex\\DGDecode.dll")
DGDecode_mpeg2source("#{@path}_1.d2v", info=3)
LoadPlugin("#{$meguiPath}\\tools\\avisynth_plugin\\ColorMatrix.dll")
ColorMatrix(hints=true, threads=0)
EOS
    avs_file = File.open(@path + '-precrop.avs', 'w') do |file|
      file.puts x
      if @track.interlaced then
        file.puts "Load_Stdcall_Plugin(\"#{$meguiPath}\\tools\\yadif\\yadif.dll\")"
        file.puts "Yadif(order=-1)"
      end
    end
  end
  
  def autocrop
    if @track.video_stream.autocrop then
      path_precrop_avs = "#{@path}-precrop.avs"
      @ac = WIN32OLE.new('autocroplib.AutoCrop')
      @ac.GetAutoCropValues(path_precrop_avs)
      c = Crop.new(@ac.left, @ac.top, @ac.right, @ac.bottom)
      green("Autocrop to #{c}")
      @track.video_stream.crop = c
    end
  end
    
  def avs
    path_precrop_avs = "#{@path}-precrop.avs"
    path_avs = "#{@path}.avs"
    File.open(path_avs, 'w') do |w|
      File.foreach(path_precrop_avs) do |line|
        w.puts line
      end
      c = @track.video_stream.crop
      if c.left != 0 || c.right != 0 || c.top != 0 || c.bottom != 0 then
        w.puts "crop(#{c.left}, #{c.top}, -#{c.right}, -#{c.bottom})"
      end
    end
  end
  
  def autobitrate
    if @track.video_stream.bitrate.nil?
      duration = @ac.frameCount / @track.fps
      @bitrate = @track.size / duration * 8 / 1000
    else
      @bitrate = @track.video_stream.bitrate
    end
    green("Video bitrate = #{@bitrate}")
  end

  # Create keyframes on chapter points
  def qpfile
    ts_ref = Time.utc(2000)
    path = "#{@path} - Chapter Information - OGG - fix.txt"
    File.open("#{@track.tempdir}\\qpfile.txt", "w") do |fw|
      File.foreach(path) do |line|
        if line =~ /(CHAPTER\d+)=(\d+):(\d+):(\d+)\.(\d+)/ then
          ts = Time.utc(2000, 1, 1, $2.to_i, $3.to_i, $4.to_i, $5.to_i * 1000)
          frame = ((ts - ts_ref) * @track.fps).to_i
          fw.puts "#{frame} I -1"
        end
      end
    end
  end
  
  # For 64 bit X264, pipe through avs2yuv
  def run_x264_64(x264_opt)
    avs2yuv_cmd = "\"#{$meguiPath}\\tools\\x264\\avs2yuv.exe\" #{@path}.avs -o -"
    x264_cmd = "\"#{$meguiPath}\\tools\\x264\\x264_64.exe\" - --stdin y4m #{x264_opt}"
    cmd = "\"#{$meguiPath}\\tools\\x264\\pipebuf.exe\" #{avs2yuv_cmd} : #{x264_cmd} : 0"
    @track.logfile.puts cmd
    %x{#{cmd}}
  end
  
  def run_x264_32(x264_opt)
    x264_cmd = "\"#{$meguiPath}\\tools\\x264\\x264.exe\" #{x264_opt} #{@path}.avs"
    @track.logfile.puts x264_cmd
    %x{#{x264_cmd}}
  end
  
  def encode1
    green("Video encoding - pass 1")
    path = "#{@track.tempdir}\\VTS_#{'%02d' % @track.vts}"
    x264_opt = "--profile high --sar #{@track.video_stream.dx}:#{@track.video_stream.dy} --preset #{$x264preset} " +
    "--tune film --pass 1 --bitrate #{@bitrate} --stats \"#{path}.stats\" --thread-input --qpfile \"#{@track.tempdir}\\qpfile.txt\" --output NUL"
    if $is64OS then
      run_x264_64(x264_opt)
    else
      run_x264_32(x264_opt)
    end
  end

  def encode2
    green("Video encoding - pass 2")
    path = "%s\\VTS_%02d" % [@track.tempdir, @track.vts]
    x264_opt = "--profile high --sar #{@track.video_stream.dx}:#{@track.video_stream.dy} --preset #{$x264preset} " +
    "--tune film --pass 2 --bitrate #{@bitrate} --stats \"#{path}.stats\" --thread-input  --qpfile \"#{@track.tempdir}\\qpfile.txt\" --aud --output \"#{path}.264\""
    if $is64OS then
      run_x264_64(x264_opt)
    else
      run_x264_32(x264_opt)
    end
  end
end

# Subtitle Streams are contained in a VobSubStream
class SubtitleStream < Stream
  def initialize(track, id, index, info, stream)
    super track, id, index, info, stream
  end

  def mux(mux_index)
    lang = @track.disk.title_map[@track.title][:sub_langcode][@index]
    "--language #{mux_index}:#{lang}"
  end
end

class VobSubStream < Stream
  def initialize(track, sub_streams)
    @track = track
    @sub_streams = sub_streams
  end
  
  def encode
    vobsubrip
    @track.size -= size unless @track.size.nil?
  end
  
  def size
    path = "#{@track.tempdir}\\\VTS_#{'%02d' % @track.vts}.SUB"
    File.size(path)
  end
  
  def mux
    path = "#{@track.tempdir}\\\VTS_#{'%02d' % @track.vts}.IDX"
    # Mux contained subtitle streams
    x = @sub_streams.zip(0...@sub_streams.length)
    arg = x.map { |a| a[0].mux(a[1]) }.join(' ')
    arg + " -s #{(0...@sub_streams.length).to_a.join(',')} -D -A -T \"#{path}\""
  end
  
  def track_list
    (0...@sub_streams.length).map { |i| "#{@mux_index}:#{i}" }.join(',')
  end

  def merit
    2
  end
  
private
  def vobsubrip
    # Run VobSub to rip all requested subtitle streams
    make_file("#{@track.tempdir}\\VTS_#{'%02d' % @track.vts}.idx") {
      green("Extracting subtitles")
      vobsub_param = "#{@track.tempdir}\\vobsub.txt"
      path = "#{@track.tempdir}\\VTS_#{'%02d' % @track.vts}"
      File.open(vobsub_param, 'w') do |f|
        f.puts "#{path}_0.IFO"
        f.puts "#{path}"
        f.puts @track.pgc
        f.puts 1
        f.puts @sub_streams.map { |s| "#{s.index}" }.join(' ')
        f.puts 'CLOSE'
        end
        
      vobsub_cmd = "rundll32.exe vobsub.dll,Configure #{vobsub_param}"
      @track.logfile.puts vobsub_cmd
      %x{#{vobsub_cmd}}
    }
  end
end

class ChapterStream < Stream
  def initialize(track)
    @track = track
    @path = "#{@track.tempdir}\\VTS_#{'%02d' % @track.vts} - Chapter Information - OGG"
  end
  
  def encode
    # Delay by 0.1% to account for drop frame
    # The fps on NTSC disks is not 30 fps but 30/1.001 fps (29.97)
    # Same thing for IVTC
    # Not sure it makes a bit difference though
    File.open("#{@path} - fix.txt", "w") do |fw|
      File.foreach("#{@path}.txt") do |line|
        if line =~ /(CHAPTER\d+)=(\d+):(\d+):(\d+)\.(\d+)/ then
          ts = Time.utc(2000, 1, 1, $2.to_i, $3.to_i, $4.to_i, $5.to_i * 1000)
          ts_ref = Time.utc(2000)
          sec = (ts - ts_ref) * 1.001
          new_ts = ts_ref + sec
          fw.puts "#{$1}=#{new_ts.strftime("%H:%M:%S")}\.#{new_ts.usec / 1000}"
        else
          fw.puts line
        end
      end
    end
  end
  
  def mux
    chapter_filename = "#{@path} - fix.txt"
    "--chapters \"#{chapter_filename}\""
  end

  def merit
    -1
  end
end

# Track is an output file
class Track
  attr_reader :tempdir, :title, :vts, :pgc, :name, :disk, :video_stream, :audio_streams, :sub_streams,
    :fps, :ivtc, :interlaced, :logfile
  attr_accessor :type, :size
  
  def initialize(outdir, type, size, title, name, disk, video_stream, audio_streams, sub_streams)
    @outdir = outdir
    @type = type
    @title = title
    @vts = disk.title_map[title][:vts]
    @pgc = disk.title_map[title][:pgc]
    @name = name
    @disk = disk
    @video_stream = video_stream
    @audio_streams = audio_streams
    @sub_streams = sub_streams
    @size = size && size * 1024 * 1024
    @tempdir = "#{$tempdir}\\#{@disk.ord}.#{@vts}.#{@pgc}"
    @path = "#{@tempdir}\\VTS_#{'%02d' % @vts}"
    FileUtils.mkdir_p("#{@tempdir}")
    @logfile = File.open("#{@tempdir}\\commands.log", "a")
    @logfile.puts Time.new().asctime
  end
  
  def run
    red("Processing #{@name}")
    File.open("#{@tempdir}\\readme.txt", "w") { |f| f.puts "#{@name}" }
    @disk.mount
    decrypt
    demux
    parse_stream_file
    encode
    mux
    cyan("Finished processing #{@name}")
  end
  
  def decrypt
    make_file ("#{@tempdir}\\VTS_#{'%02d' % @vts}_0.IFO") {
      green("Decrypting")
      decrypt_cmd = "\"#{$decrypterPath}\" /SRC #{@disk.drive_letter}: /DEST \"#{@tempdir}\" /VTS #{@vts} /PGC #{@pgc} /MODE IFO /START /CLOSE"
      @logfile.puts decrypt_cmd
      %x{#{decrypt_cmd}}
    }
  end
  
  # Parse the Stream Information file output by DVD Decrypter
  def parse_stream_file
    green("Parsing stream info file")
    @streams = []
    aud_streams = []
    sub_streams = []
    audio_index = 0
    sub_index = 0
    max_channels = 0
    video = nil
    File.open("#{@tempdir}\\VTS_#{'%02d' % @vts} - Stream Information.txt", "r:ISO-8859-1") do |f|
      while (line = f.gets)
        s = nil
        id, type, info = line.split(' - ', 3)
        case type
        when "Subtitle"
          info =~ /(\w+)/
          language = $1
          t = @sub_streams.find { |t| t.language == language }
          sub_streams << SubtitleStream.new(self, id, sub_index, info, t) if t
          sub_index += 1
        when "Audio"
          info = info.split(' / ', 8)
          codec = info[0]
          channels = info[1]
          channels =~ /(\d+)ch/
          channels = $1.to_i
          language = info[4]
          if codec == 'AC3' then
            t = @audio_streams.find { |t| t.language == language }
            aud_streams << AudioStream.new(self, id, audio_index, channels, info, t) if t
          end
          audio_index += 1
        when "Video"
          info = info.split(' / ', 7)
          dar = info[2]
          @video_stream.set_dar(dar)
          video = VideoStream.new(self, id, info, @video_stream)
        end
      end
    end

    # Take all the audio streams that have the lowest priority number
    best_audio = aud_streams.min { |a,b| a.stream.priority <=> b.stream.priority }
    aud_streams = aud_streams.delete_if { |a| a.stream.priority > best_audio.stream.priority }
    # Keep only the ones that have the highest number of channels
    max_channels = aud_streams.max { |a,b| a.channels <=> b.channels }
    @streams = aud_streams.delete_if { |a| a.channels < max_channels.channels }
    
    # Take all the subtitle streams that have the lowest priority number
    best_sub = sub_streams.min { |a,b| a.stream.priority <=> b.stream.priority }
    sub_streams = sub_streams.delete_if { |a| a.stream.priority > best_sub.stream.priority }
    @streams << VobSubStream.new(self, sub_streams) if sub_streams.length != 0
    @streams << ChapterStream.new(self)
    @streams << video
  end
  
  def encode
    @streams.each { |s| s.encode }
  end
  
  def demux
    set_video_type
    make_file ("#{@tempdir}\\VTS_#{'%02d' % @vts}_1.d2v") {
      green("Demuxing")
      path = "#{@path}_1"
      while true
        demux_cmd = "\"#{$demuxPath}\" -i \"#{path}.VOB\" -o \"#{path}\" -fo #{@ivtc ? 1 : 0} -exit"
        @logfile.puts demux_cmd
        %x{#{demux_cmd}}
        if @type == 'auto' then
          set_video_type 
          redo if @type != "film"
        end
        break
      end
    }
  end
  
  # Based on the video type, set the FPS and the frame type
  def set_video_type
    @type = parse_demux_log if @type == "auto" && File.exists?("#{@tempdir}\\VTS_#{'%02d' % @vts}_1.log")
    case @type
      when "auto", "film"
        @fps = 24
        @ivtc = true
        @interlaced = false
      when "progressive"
        @fps = 30
        @ivtc = false
        @interlaced = false
      when "interlaced"
        @fps = 30
        @ivtc = false
        @interlaced = true
    end
  end
  
  # Parse the DGIndex log and guess the video type
  def parse_demux_log
    film_percent = 0
    progressive = false
    File.foreach("#{@tempdir}\\VTS_#{'%02d' % @vts}_1.log") do |line|
      if line =~ /Video Type: Film( (\d+(\.\d+)?)%)?/ then
        film_percent = $1.nil? ? 100 : $2.to_f
      end
      if line == "Frame Type: Progressive" then
        progressive = true
      end
    end
    if film_percent >= 95 then 
      type = "film" 
    elsif progressive
      type = "progressive"
    else
      type = "interlaced"
    end
    type
  end
  
  def mux
    # Order the streams by mux merit
    mux_streams = @streams.clone
    mux_streams.delete_if { |s| s.merit < 0 }
    mux_streams.each_with_index { |s,i| s.mux_index = i }
    track_order = mux_streams.sort { |x,y| x.merit <=> y.merit }.map{ |s| s.track_list }.join(',')
    path = "#{@outdir}\\#{@name}.mkv"
    make_file(path) {
      green("Remuxing")
      mux_cmd = "\"#{$mkvmergePath}\" -o \"#{path}\" " + @streams.map { |s| s.mux }.join(' ') + " --track-order \"#{track_order}\""
      @logfile.puts mux_cmd
      %x{#{mux_cmd}}
    }
  end
end

# Execute the block creates the file
# If aborted, deletes the file before exiting
def make_file(file)
  return if File.exists?(file)
  begin
    yield
  rescue Interrupt
    sleep 2
    File.unlink(file) if File.exists?(file)
    raise $!
  end
end

TrackDoneFileName = 'tracks-done.yaml'

shutdown = false
# Loop until there is no more work
begin 
  # Read the tracks that are already done
  tracks_done = File.exist?(TrackDoneFileName) ? YAML::load(File.read(TrackDoneFileName)) : {}
  more_work = false
  project = read_config()
  shutdown = project["shutdown"]
  tracks = []
  outdir = project["outdir"]
  if !project["crop"].nil? then
    c = Crop.new(project["crop"]["left"], project["crop"]["top"], project["crop"]["right"], project["crop"]["bottom"])
  end
  video_stream = Video.new(c, project["bitrate"])
  audio_streams = project["audio"].map { |lang, priority| Audio.new(lang, priority) }
  sub_streams = project["sub"].map { |lang, priority| Sub.new(lang, priority) }
  
  # Collect all tracks
  disk_index = 0
  project["disk"].each do |d| 
    disk_index += 1
    disk = Disk.new(d["image"], disk_index)
    disk.mount
    disk.parse_vmg
    name = d["name"]
    raise "Invalid character in #{name}" if name =~ /[\\\/:\*\?"<>|]/
    if d["title"].nil? then
      title = disk.title_map.each_with_index.max { |a,b| a[0][:length] <=> b[0][:length] }[1]
      green("Autopicked title #{title}, duration = #{(Time.utc(2000) + disk.title_map[title][:length]).strftime("%H:%M:%S")}")
    else
      title = d["title"]
    end
    season = d["season"] || 1
    episode = d["episode"] || 1
    type = d["type"] || "auto"
    track_names = []
    if d["tracks"].nil? then
      track_names << { :name => name, :title => title }
    else
      d["tracks"].each do |t|
        track_name = "#{name} - S#{'%02d' % season}E#{'%02d' % episode} - #{t}"
        track_names << { :name => track_name, :title => title }
        title += 1
        episode += 1
      end
    end
    
    # Skip track if done
    track_names.delete_if { |t| tracks_done.has_key?(t[:name]) }
    tracks += track_names.map { |t|
      Track.new(outdir, type, project["size"], t[:title], t[:name], 
        disk, video_stream, audio_streams, sub_streams) }
  end

  # Process all tracks
  tracks.each do |t| 
    more_work = true
    t.run
    tracks_done[t.name] = true
    File.open(TrackDoneFileName, 'w') { |f| YAML::dump(tracks_done, f) }
  end
end while more_work

if shutdown then
  shutdown_cmd = "psshutdown -s"
  %x{#{shutdown_cmd}}
end
