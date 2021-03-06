require 'titleizer'
require 'choice'
require 'Win32/Console/ANSI'
require 'WIN32OLE'
require 'fileutils'
require 'yaml'
require 'Win32API'

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

Choice.options do
  option :clean do
    short '-c'
    long '--clean'
    desc 'Delete temporary files before processing'
    default false
  end
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
$rename = Win32API.new("kernel32", "MoveFile", ['PP'])

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
  attr_reader :bitrate, :dx, :dy, :autocrop, :type
  def initialize(crop, bitrate, type)
    @crop = crop
    @autocrop = crop.nil?
    @bitrate = bitrate
    @type = type
  end
  
  def set_dar(dar)
    dar =~ /(\d+):(\d+)/
    darX, darY = $1.to_i, $2.to_i
    case @type
      when "pal"
        @dx = darX * 4
        @dy = darY * 5
      else
        @dx = darX * 2
        @dy = darY * 3
    end
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
      (0...num_audio_streams).each do |i|
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
      (0...num_audio_streams).each do |i|
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
      f.seek(offset_of_srpt * 0x800)
      x = f.read(0x100 + titles * 12)
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
    (lang[0].ord != 0 ? "--language 0:#{lang} " : "") +
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
    if @track.type == :hybrid then
      make_file ("#{@track.tempdir}\\tfm.txt") {
        encode0 
      }
    end
    make_file ("#{@path}.264") {
      encode_vid
    }
    @ac.ole_free
    @ac = nil
  end
  
  def round_to(x, prec)
    (x / prec).round * prec
  end
  
  def mux
    path = "#{@path}.264"
    vs = @track.video_stream
    c = vs.crop
    width = 720
    height = @stream.type == "pal" ? 576 : 480
    ar = round_to((width - c.left - c.right ).to_f / (height - c.top - c.bottom) * vs.dx / vs.dy, 0.01)
    real_fps = @stream.type == "pal" ? "#{@track.fps}fps" : "#{@track.fps}000/1001fps"
    (@track.type == :hybrid ? " --timecodes \"0:#{@track.tempdir}\\timecodes.txt\"" : "--default-duration 0:#{real_fps}") +
    " --aspect-ratio 0:#{ar} " +
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
      case @track.type
        when :interlaced
          file.puts "Load_Stdcall_Plugin(\"#{$meguiPath}\\tools\\yadif\\yadif.dll\")"
          file.puts "Yadif(order=-1)"
        when :ivtc
          file.puts "LoadPlugin(\"#{$meguiPath}\\tools\\avisynth_plugin\\TIVTC.dll\")"
          file.puts "TFM()"
          file.puts "TDecimate()"
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
    @avs_name = @track.type == :hybrid ? "#{@path}-pass1.avs" : path_avs
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
    avs2yuv_cmd = "\"#{$meguiPath}\\tools\\x264\\avs2yuv.exe\" #{@avs_name} -o -"
    x264_cmd = "\"#{$meguiPath}\\tools\\x264\\x264_64.exe\" - --stdin y4m #{x264_opt}"
    cmd = "\"#{$meguiPath}\\tools\\x264\\pipebuf.exe\" #{avs2yuv_cmd} : #{x264_cmd} : 0"
    @track.logfile.puts cmd
    %x{#{cmd}}
  end
  
  def run_x264_32(x264_opt)
    x264_cmd = "\"#{$meguiPath}\\tools\\x264\\x264.exe\" #{x264_opt} #{@avs_name}"
    @track.logfile.puts x264_cmd
    %x{#{x264_cmd}}
  end
  
  def encode0
    green("Video encoding - pass 0")
    
    path_avs = "#{@path}.avs"
    path_avs0 = "#{@path}-pass0.avs"
    File.open(path_avs0, 'w') do |w|
      File.foreach(path_avs) do |line|
        w.puts line
      end
      w.puts "LoadPlugin(\"#{$meguiPath}\\tools\\avisynth_plugin\\TIVTC.dll\")"
      w.puts "TFM(mode=1, output=\"tfm.txt\")"
      w.puts "TDecimate(mode=4, output=\"stats.txt\")"
    end
    
    path_avs = "#{@path}.avs"
    path_avs1 = "#{@path}-pass1.avs"
    File.open(path_avs1, 'w') do |w|
      File.foreach(path_avs) do |line|
        w.puts line
      end
      w.puts "LoadPlugin(\"#{$meguiPath}\\tools\\avisynth_plugin\\TIVTC.dll\")"
      w.puts "TFM(mode=1)"
      w.puts "TDecimate(mode=5, hybrid=2, dupthresh=1.0, input=\"stats.txt\", tfmin=\"tfm.txt\", mkvout=\"timecodes.txt\")"
    end

    avs2yuv_cmd = "\"#{$meguiPath}\\tools\\x264\\avs2yuv.exe\" #{@path}-pass0.avs -o nul"
    %x{#{avs2yuv_cmd}}
  end
  
  def encode_vid
    green("Video encoding")
    path = "#{@track.tempdir}\\VTS_#{'%02d' % @track.vts}"
    x264_opt = "--profile high --sar #{@track.video_stream.dx}:#{@track.video_stream.dy} --preset #{$x264preset} " +
    "--tune film --crf 18 --qpfile \"#{@track.tempdir}\\qpfile.txt\" --output \"#{path}.264\""
    if $is64OS then
      run_x264_64(x264_opt)
    else
      run_x264_32(x264_opt)
    end
  end
end

# Subtitle Streams are contained in a VobSubStream
class SubtitleStream < Stream
  def initialize(track, id, sup_index, index, info, stream)
    super track, id, index, info, stream
    @sup_index = sup_index
  end

  def mux(mux_index)
    lang = @track.disk.title_map[@track.title][:sub_langcode][@sup_index]
    "--language #{mux_index}:#{lang}"
  end
end

class VobSubStream < Stream
  def initialize(track, delay, sub_streams)
    @track = track
    @delay = delay
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
    path = "#{@track.tempdir}\\\VTS_#{'%02d' % @track.vts}b.IDX"
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
    
    make_file("#{@track.tempdir}\\VTS_#{'%02d' % @track.vts}b.idx") {
      File.open("#{@track.tempdir}\\VTS_#{'%02d' % @track.vts}b.idx", "w") do |fw|
        File.foreach("#{@track.tempdir}\\VTS_#{'%02d' % @track.vts}.idx") do |line|
          fw.puts line
          fw.puts "delay: -#{@delay}" if line =~ /id:/
        end
      end
      FileUtils.cp "#{@track.tempdir}\\VTS_#{'%02d' % @track.vts}.sub", "#{@track.tempdir}\\VTS_#{'%02d' % @track.vts}b.sub"
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
  
  def initialize(outdir, video_type, size, title, name, chapters, opt, disk, video_stream, audio_streams, sub_streams)
    @outdir = outdir
    @video_type = video_type
    @title = title
    @opt = opt
    @vts = opt[:vts] || disk.title_map[title][:vts]
    @pgc = opt[:pgc] || disk.title_map[title][:pgc]
    @name = name
    @chapters = chapters
    @disk = disk
    @video_stream = video_stream
    @audio_streams = audio_streams
    @sub_streams = sub_streams
    @size = size && size * 1024 * 1024
    @tempdir = "#{$tempdir}\\#{@disk.ord}.#{@vts}.#{@pgc}"
    if not chapters.nil? then
      x = TitleList.new(chapters).next()
      @tempdir += ".#{x}"
    end
    @path = "#{@tempdir}\\VTS_#{'%02d' % @vts}"
  end
  
  def run
    red("Processing #{@name}")
    FileUtils.mkdir_p("#{@tempdir}")
    @logfile = File.open("#{@tempdir}\\commands.log", "a")
    @logfile.puts Time.new().asctime
    File.open("#{@tempdir}\\readme.txt", "w") { |f| f.puts "#{@name}" }
    @disk.mount
    decrypt
    demux
    parse_stream_file
    encode
    mux
    @logfile.close
    cyan("Finished processing #{@name}")
  end
  
  def decrypt
    make_file ("#{@tempdir}\\VTS_#{'%02d' % @vts}_0.IFO") {
      green("Decrypting")
      decrypt_cmd = "\"#{$decrypterPath}\" /SRC #{@disk.drive_letter}: /DEST \"#{@tempdir}\" /VTS #{@vts} /PGC #{@pgc}"
      if not @chapters.nil? then
        chapter_list = TitleList.new(@chapters)
        ch = chapter_list.titles
        decrypt_cmd += " /CHAPTERS " + ch.join(" ")
      end
      decrypt_cmd += "  /ANGLE 1 /MODE IFO /START /CLOSE"
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
    substream_index = 0
    sup_index_set = []
    max_channels = 0
    video_delay = nil
    video = nil
	first_aud_stream = nil
    File.open("#{@tempdir}\\VTS_#{'%02d' % @vts} - Stream Information.txt", "r:ISO-8859-1") do |f|
      while (line = f.gets)
        s = nil
        id, type, info = line.split(' - ', 3)
        case type
        when "Subtitle"
          info =~ /(\w+)/
          language = $1
          info =~ /SubPicture (\d+)/
          sup_index = $1.to_i - 1
          if sup_index_set[sup_index].nil? then
            sup_index_set[sup_index] = true
            t = @sub_streams.find { |t| t.language == language }
            sub_streams << SubtitleStream.new(self, id, sup_index, substream_index, info, t) if t
          end
          substream_index += 1
        when "Audio"
          info = info.split(' / ', 8)
          codec = info[0]
          channels = info[1]
          channels =~ /(\d+)ch/
          channels = $1.to_i
          language = info[4]
          if codec == 'AC3' then
            t = @audio_streams.find { |t| t.language == language }
            x = AudioStream.new(self, id, audio_index, channels, info, t)
            aud_streams << x if t
            first_aud_stream ||= x
          end
          audio_index += 1
        when "Video"
          info = info.split(' / ', 7)
          dar = info[2]
          delay = info[-2]
          delay =~ /PTS: (.+)/
          video_delay = $1.gsub('.', ':')
          @video_stream.set_dar(dar)
          video = VideoStream.new(self, id, info, @video_stream)
        end
      end
    end

    # Take all the audio streams that have the lowest priority number
    if aud_streams.length != 0 then
      best_audio = aud_streams.min { |a,b| a.stream.priority <=> b.stream.priority }
      aud_streams = aud_streams.delete_if { |a| a.stream.priority > best_audio.stream.priority }
      # Keep only the ones that have the highest number of channels
      max_channels = aud_streams.max { |a,b| a.channels <=> b.channels }
      @streams = aud_streams.delete_if { |a| a.channels < max_channels.channels }
    else
      @streams << first_aud_stream
    end
    
    # Take all the subtitle streams that have the lowest priority number
    best_sub = sub_streams.min { |a,b| a.stream.priority <=> b.stream.priority }
    sub_streams = sub_streams.delete_if { |a| a.stream.priority > best_sub.stream.priority }
    @streams << VobSubStream.new(self, video_delay, sub_streams) if sub_streams.length != 0
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
        demux_cmd = "\"#{$demuxPath}\" -i \"#{path}.VOB\" -o \"#{path}\" -fo #{@type == :ff ? 1 : 0} -exit"
        @logfile.puts demux_cmd
        %x{#{demux_cmd}}
        if @video_type == "auto" then
          set_video_type 
          redo if @type != :ff
        end
        break
      end
    }
  end
  
  # Based on the video type, set the FPS and the frame type
  def set_video_type
    if @video_stream.type == "pal"
      @video_type = "pal"
    end
  
    if @video_type == "auto" && File.exists?("#{@tempdir}\\VTS_#{'%02d' % @vts}_1.log")
      @type = parse_demux_log
      @video_type = nil
    else
      @fps = 30
      case @video_type
        when "auto", "film"
          @type = :ff
        when "interlaced"
          @type = :interlaced
        when "ivtc"
          @type = :ivtc
        when "hybrid"
          @type = :hybrid
        when "pal"
          @type = :pal
      end
    end
    case @type
      when :ff, :ivtc
        @fps = 24
      when :pal
        @fps = 25
      else
        @fps = 30
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
    end
    if film_percent >= 95 then 
      type = :ff
    else
      type = :interlaced
    end
    green("Film type is #{type}")
    type
  end
  
  def mux
    # Order the streams by mux merit
    mux_streams = @streams.clone
    mux_streams.delete_if { |s| s.merit < 0 }
    mux_streams.each_with_index { |s,i| s.mux_index = i }
    track_order = mux_streams.sort { |x,y| x.merit <=> y.merit }.map{ |s| s.track_list }.join(',')
    if @opt[:tvshow] then
      basedir = "#{@outdir}\\#{@opt[:tvshow_name]}\\Season #{@opt[:season]}"
    else
      basedir = "#{@outdir}\\#{@name}"
    end
    FileUtils.mkdir_p(basedir)
    mkv_file = "#{basedir}\\#{@name}.mkv".encode("ISO-8859-1")
    temp_file = "#{basedir}\\temp.mkv"
    make_file(mkv_file) {
      green("Remuxing")
      mux_cmd = "\"#{$mkvmergePath}\" -o \"#{temp_file}\" " + @streams.map { |s| s.mux }.join(' ') + " --track-order \"#{track_order}\""
      @logfile.puts mux_cmd
      %x{#{mux_cmd}}
      $rename.Call(temp_file, mkv_file)
    }
  end
end

class TitleList
  attr_reader :titles
  
  def initialize(title_string)
    @title_string = title_string
    @title_ranges = @title_string.split(',')
    @titles = []
    each_title { |x| @titles << x }
    @current = 0
    @last = 1
  end
  
  def each_title
    @title_ranges.each do |r|
      low, high = r.split(':').map { |x| x.to_i }
      high = low if high.nil?
      (low..high).each { |x| yield x }
    end
  end
  
  def next
    if @current < @titles.length then
      title = @titles[@current]
      @last = title
      @current += 1
    else
      @last += 1
      title = @last
    end
    title
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

if Choice.choices[:clean] then
  red("CLEANING ALL TEMPORARY DATA... Last chance to interrupt")
  sleep 10
  FileUtils.rmtree $tempdir
  sleep 5
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
  video_stream = Video.new(c, project["bitrate"], project["type"])
  audio_streams = project["audio"].map { |lang, priority| Audio.new(lang, priority) }
  sub_streams = project["sub"].map { |lang, priority| Sub.new(lang, priority) }
  
  # Collect all tracks
  disks = []
  project_dir = project["directory"]
  if !project_dir.nil? then
    dir = project_dir.gsub('\\', '/').upcase + '/*.ISO'
    images = Dir.glob(dir)
    images.sort! { |f,g| File.new(f).ctime <=> File.new(g).ctime }
    disks = images.map { |f| {'image' => "#{f.upcase}"} }
  end
  disks = disks.concat project["disk"] unless project["disk"].nil?
  disk_index = 0
  episode = nil
  season = nil
  name = nil
  disks.each do |d| 
    disk_index += 1
    disk = Disk.new(d["image"], disk_index)
    disk.mount
    disk.parse_vmg
    if d["name"].nil? then
      d["image"] =~ /((\w|_|\s)+)\.ISO/
      image_name = $1
      name = image_name.downcase.titleize
    else
      name = d["name"].encode("ISO-8859-1")
    end
    raise "Invalid character in #{name}" if name =~ /[\\\/:\*\?"<>|]/
    if d["title"].nil? then
      title = disk.title_map.each_with_index.max { |a,b| a[0][:length] <=> b[0][:length] }[1]
      green("Autopicked title #{title}, duration = #{(Time.utc(2000) + disk.title_map[title][:length]).strftime("%H:%M:%S")}")
    else
      title = d["title"]
    end
    title_list = TitleList.new(title.to_s)
    season = d["season"] || season || 1
    episode = d["episode"] || episode || 1
    type = d["type"] || "auto"
    track_names = []
    names = d["tracks"]
    if !d["count"].nil? then
      names = []
      count = d["count"].to_i
      (0...count).each { |i| names << "unknown" }
    end
    if names.nil? then
      track_names << { :name => name, :title => title, :vts => d["vts"], :pgc => d["pgc"], :tvshow => false }
    else
      names.each do |t|
        if t.kind_of? String then
          title = title_list.next
          tt = t
          chapters = nil
        else
          tt = t["n"] || "unknown"
          chapters = t["c"]
        end
        track_name = "#{name} - S#{'%02d' % season}E#{'%02d' % episode} - #{tt}"
        track_names << { :name => track_name, :title => title, :chapters => chapters, :vts => d["vts"], :pgc => d["pgc"], :tvshow => true, :tvshow_name => name, :season => season }
        episode += 1
      end
    end
    
    # Skip track if done
    track_names.delete_if { |t| tracks_done.has_key?(t[:name]) }
    tracks += track_names.map { |t|
      Track.new(outdir, type, project["size"], t[:title], t[:name], t[:chapters], t,
        disk, video_stream, audio_streams, sub_streams) }
  end

  tracks.each { |t| puts "#{t.title} -> #{t.name}" }
  
  # Process all tracks
  tracks.each do |t| 
    more_work = true
    t.run
    tracks_done[t.name] = true
    File.open(TrackDoneFileName, 'w') { |f| YAML::dump(tracks_done, f) }
  end
end while more_work

if shutdown then
  shutdown_cmd = "\\bin\\psshutdown -s"
  %x{#{shutdown_cmd}}
end
