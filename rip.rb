require 'Win32/Console/ANSI'
require 'WIN32OLE'
require "fileutils"
require "yaml"

def red(text)
    puts "\033[0;31;40m#{text}\033[0m"
end

def green(text)
    puts "\033[0;32;40m#{text}\033[0m"
end

def cyan(text)
    puts "\033[0;36;40m#{text}\033[0m"
end

def read_config
  config = YAML::load_file('config.yaml')
  project = YAML::load_file('dvdrip.yaml')
  project.merge!(config)
  project
end

project = read_config()

$x264preset = project["x264preset"]
$tempdir = project["tempdir"]
$clonedrivePath = project["clonedrive"]["path"]
$clonedriveLetter = project["clonedrive"]["letter"]
$clonedriveIndex = project["clonedrive"]["index"]

$decrypterPath = project["decrypter"]
$meguiPath = project["megui"]
$mkvmergePath = project["mkvmerge"]

$demuxPath = $meguiPath + '\tools\dgindex\DGIndex.exe'

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

class Audio
  attr_reader :language
  def initialize(language)
    @language = language
  end
  def to_s
    "Audio #{@language}"
  end
end

class Sub
  attr_reader :language
  def initialize(language)
    @language = language
  end
  def to_s
    "Sub #{@language}"
  end
end

class Disk
  attr_reader :image, :ord, :drive_letter
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
  
  def parse_len(vts, pgc)
    path = "#{@drive_letter}:\\VIDEO_TS\\VTS_#{'%02d' % vts}_0.IFO"
    File::open(path, 'r') do |f|
      x = f.read(256)
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

  def parse_vmg
    green("Parsing Video Manager IFO")
    path = "#{@drive_letter}:\\VIDEO_TS\\VIDEO_TS.IFO"
    title_map = []
    title_map[0] = { :length => 0 }
    File::open(path, 'r') do |f|
      x = f.read(256)
      offset_of_srpt = x[0xC4...0xC8].unpack('N').first
      f.seek(offset_of_srpt * 0x800)
      x = f.read(512)
      titles = x[0...2].unpack('n').first
      offset = 8
      (1..titles).each do |i| 
        a = x.slice(offset, 12).unpack("ccnnccN")
        title_map[i] = { :vts => a[4], :pgc => a[5], :length => parse_len(a[4], a[5]) }
        offset += 12
      end
    end
    title_map
  end
end

class Stream
  attr_reader :id, :info, :stream
  attr_accessor :index
  def initialize(track, id, info, stream)
    @track = track
    @id = id
    @info = info
    @stream = stream
  end
  
  def encode
  end
  
  def track_list
    "#{@index}:0"
  end
end

class AudioStream < Stream
  attr_reader :audio_filename, :channels
  def initialize(track, id, channels, info, stream)
    super track, id, info, stream
    @channels = channels
    track_number = "T%02x" % id
    @audio_filename = Dir.foreach(@track.tempdir).find { |f| f =~ /#{track_number}/ }
    @audio_filename =~ /DELAY (.*)ms/
    @delay = $1.to_i
    @path = "#{@track.tempdir}\\#{@audio_filename}"
  end
  
  def mux
    "--language 0:#{@stream.language} " +
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
    1
  end
end

class VideoStream < Stream
  def initialize(track, id, info, stream)
    super track, id, info, stream
    @path = "#{@track.tempdir}\\VTS_#{'%02d' % @track.vts}"
  end
  
  def encode
    precrop_avs
    autocrop
    avs
    autobitrate
    qpfile
    make_file ("#{@path}.264") {
      encode1
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
  
  def run_x264_64(x264_opt)
    avs2yuv_cmd = "\"#{$meguiPath}\\tools\\x264\\avs2yuv.exe\" #{@path}.avs -o -"
    x264_cmd = "\"#{$meguiPath}\\tools\\x264\\x264_64.exe\" - --stdin y4m #{x264_opt}"
    cmd = "\"#{$meguiPath}\\tools\\x264\\pipebuf.exe\" #{avs2yuv_cmd} : #{x264_cmd} : 0"
    %x{#{cmd}}
  end
  
  def run_x264_32(x264_opt)
    x264_cmd = "\"#{$meguiPath}\\tools\\x264\\x264.exe\" #{x264_opt} #{@path}.avs"
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

class SubtitleStream < Stream
  def initialize(track, id, info, stream)
    super track, id, info, stream
  end

  def mux(index)
    "--language #{index}:#{@stream.language}"
  end
end

class VobSubStream < Stream
  def initialize(track, sub_streams)
    @track = track
    @sub_streams = sub_streams
  end
  
  def encode
    vobsubrip
    timecorrect
    @track.size -= size unless @track.size.nil?
  end
  
  def size
    path = "#{@track.tempdir}\\\VTS_#{'%02d' % @track.vts}-fix.SUB"
    File.size(path)
  end
  
  def mux
    path = "#{@track.tempdir}\\\VTS_#{'%02d' % @track.vts}-fix.IDX"
    x = @sub_streams.zip(0...@sub_streams.length)
    arg = x.map { |a| a[0].mux(a[1]) }.join(' ')
    arg + " -s #{(0...@sub_streams.length).to_a.join(',')} -D -A -T \"#{path}\""
  end
  
  def track_list
    (0...@sub_streams.length).map { |i| "#{@index}:#{i}" }.join(',')
  end

  def merit
    2
  end
  
private
  def vobsubrip
    make_file("#{@track.tempdir}\\VTS_#{'%02d' % @track.vts}.idx") {
      green("Extracting subtitles")
      vobsub_param = "#{@track.tempdir}\\vobsub.txt"
      path = "#{@track.tempdir}\\VTS_#{'%02d' % @track.vts}"
      File.open(vobsub_param, 'w') do |f|
        f.puts "#{path}_0.IFO"
        f.puts "#{path}"
        f.puts @track.pgc
        f.puts 0
        f.puts @sub_streams.map { |s| "#{s.id}" }.join(' ')
        f.puts 'CLOSE'
        end
        
      vobsub_cmd = "rundll32.exe vobsub.dll,Configure #{vobsub_param}"
      %x{#{vobsub_cmd}}
    }
  end
  
  def timecorrect
    delays = []
    File.open("#{@track.tempdir}\\VTS_#{'%02d' % @track.vts}.IDX", "r") do |f|
      look_for_id = true
      id = -1
      ts = nil
      while line = f.gets
        if look_for_id && line =~ /index: (\d+)/ then
          id = $1.to_i
          look_for_id = false
        elsif !look_for_id && line =~ /timestamp: (\d+):(\d+):(\d+):(\d+)/ then
          ts_idx = Time.utc(2000, 1, 1, $1.to_i, $2.to_i, $3.to_i, $4.to_i * 1000)
          s = @sub_streams.find { |s| s.id == id }
          s.info =~ /PTS: (\d+):(\d+):(\d+)\.(\d+)/
          ts_stream = Time.utc(2000, 1, 1, $1.to_i, $2.to_i, $3.to_i, $4.to_i * 1000)
          delay = ts_idx - ts_stream
          sign = delay <=> 0
          delay = delay.abs
          delay = Time.utc(2000) + delay
          delay = (sign < 0 ? "-" : "" ) + "#{delay.strftime("%H:%M:%S")}:#{delay.usec / 1000}"
          delays[id] = delay
          look_for_id = true
        end
      end
    end

    path = "#{@track.tempdir}\\VTS_#{'%02d' % @track.vts}"
    File.open("#{path}-fix.IDX", "w") do |fw|
      File.foreach("#{path}.IDX") do |line|
        fw.puts line
        if line =~ /index: (\d+)/ then
          id = $1.to_i
          fw.puts "delay: #{delays[id]}"
        end
      end
    end
    
    FileUtils.cp "#{path}.SUB", "#{path}-fix.SUB"
  end
end

class ChapterStream < Stream
  def initialize(track)
    @track = track
    @path = "#{@track.tempdir}\\VTS_#{'%02d' % @track.vts} - Chapter Information - OGG"
  end
  
  def encode
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

class Track
  attr_reader :type, :tempdir, :vts, :pgc, :name, :video_stream, :audio_streams, :sub_streams,
    :fps, :ivtc, :interlaced
  attr_accessor :size
  
  def initialize(outdir, type, size, vts, pgc, name, disk, video_stream, audio_streams, sub_streams)
    @outdir = outdir
    @type = type
    @vts = vts
    @pgc = pgc
    @name = name
    @disk = disk
    @video_stream = video_stream
    @audio_streams = audio_streams
    @sub_streams = sub_streams
    @size = size && size * 1024 * 1024
    @tempdir = "#{$tempdir}\\#{@disk.ord}.#{@vts}.#{@pgc}"
    @path = "#{@tempdir}\\VTS_#{'%02d' % @vts}"
    case @type
      when "film"
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
  
  def run
    red("Processing #{@name}")
    FileUtils.mkdir_p("#{@tempdir}")
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
      %x{#{decrypt_cmd}}
    }
  end
  
  def parse_stream_file
    green("Parsing stream info file")
    @streams = []
    aud_streams = []
    sub_streams = []
    sub_index = 0
    max_channels = 0
    video = nil
    File.foreach("#{@tempdir}\\VTS_#{'%02d' % @vts} - Stream Information.txt") do |line|
      s = nil
      id, type, info = line.split(' - ', 3)
      case type
      when "Subtitle"
        info =~ /(\w+)/
        language = $1
        t = @sub_streams.find { |t| t.language == language }
        sub_streams << SubtitleStream.new(self, sub_index, info, t) if t
        sub_index += 1
      when "Audio"
        info = info.split(' / ', 8)
        codec = info[0]
        channels = info[1]
        channels =~ /(\d+)ch/
        channels = $1.to_i
        max_channels = channels if channels > max_channels
        language = info[4]
        if codec == 'AC3' then
          t = @audio_streams.find { |t| t.language == language }
          aud_streams << AudioStream.new(self, id, channels, info, t) if t
        end
      when "Video"
        info = info.split(' / ', 7)
        dar = info[2]
        @video_stream.set_dar(dar)
        video = VideoStream.new(self, id, info, @video_stream)
      end
    end

    @streams = aud_streams.delete_if { |s| s.channels < max_channels }
    @streams << VobSubStream.new(self, sub_streams) if sub_streams.length != 0
    @streams << ChapterStream.new(self)
    @streams << video
  end
  
  def encode
    @streams.each { |s| s.encode }
  end
  
  def demux
    make_file ("#{@tempdir}\\VTS_#{'%02d' % @vts}_1.d2v") {
      green("Demuxing")
      path = "#{@path}_1"
      demux_cmd = "\"#{$demuxPath}\" -i \"#{path}.VOB\" -o \"#{path}\" -fo #{@ivtc ? 1 : 0} -exit"
      %x{#{demux_cmd}}
    }
  end
  
  def mux
    mux_streams = @streams.clone
    mux_streams.delete_if { |s| s.merit < 0 }
    mux_streams.each_with_index { |s,i| s.index = i }
    track_order = mux_streams.sort { |x,y| x.merit <=> y.merit }.map{ |s| s.track_list }.join(',')
    path = "#{@outdir}\\#{@name}.mkv"
    make_file(path) {
      green("Remuxing")
      mux_cmd = "\"#{$mkvmergePath}\" -o \"#{path}\" " + @streams.map { |s| s.mux }.join(' ') + " --track-order \"#{track_order}\""
      %x{#{mux_cmd}}
    }
  end
end

def make_file(file)
  return if File.exists?(file)
  begin
    yield
  rescue Interrupt
    sleep 5
    File.unlink(file) if File.exists?(file)
    raise $!
  end
end

TrackDoneFileName = 'tracks-done.yaml'

disk_index = 0
shutdown = false
begin 
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
  audio_streams = project["audio"].map { |lang| Audio.new(lang) }
  sub_streams = project["sub"].map { |lang| Sub.new(lang) }
  project["disk"].each do |d| 
    disk_index += 1
    disk = Disk.new(d["image"], disk_index)
    disk.mount
    title_map = disk.parse_vmg
    name = d["name"]
    if d["title"].nil? then
      title = title_map.each_with_index.max { |a,b| a[0][:length] <=> b[0][:length] }[1]
      green("Autopicked title #{title}, duration = #{(Time.utc(2000) + title_map[title][:length]).strftime("%H:%M:%S")}")
    else
      title = d["title"]
    end
    season = d["season"] || 1
    episode = d["episode"] || 1
    type = d["type"] || "film"
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
    
    track_names.delete_if { |t| tracks_done.has_key?(t[:name]) }
    tracks += track_names.map { |t|
      Track.new(outdir, type, project["size"], title_map[t[:title]][:vts], title_map[t[:title]][:pgc], t[:name], 
        disk, video_stream, audio_streams, sub_streams) }
  end

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

