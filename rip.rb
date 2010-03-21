require 'WIN32OLE'
require "fileutils"
require "yaml"

project = YAML::load(File.read('dvdrip.yaml'))

$x264preset = project["x264preset"]
$tempdir = project["tempdir"]
$clonedrivePath = project["clonedrive"]["path"]
$clonedriveLetter = project["clonedrive"]["letter"]
$clonedriveIndex = project["clonedrive"]["index"]

$decrypterPath = project["decrypter"]
$meguiPath = project["megui"]
$mkvmergePath = project["mkvmerge"]

$demuxPath = $meguiPath + '\tools\dgindex\DGIndex.exe'

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
      puts "Mounting image file #{@image}"
      mount_cmd = "\"#{$clonedrivePath}\" -mount #{$clonedriveIndex},\"#{@image}\""
      %x{#{mount_cmd}}
      sleep 10
      $last_mounted = @image
    end
  end

  def parse_vmg
    puts "Parsing Video Manager IFO"
    path = "#{@drive_letter}:\\VIDEO_TS\\VIDEO_TS.IFO"
    title_map = []
    File::open(path, 'r') do |f|
      x = f.read(256)
      offset_of_srpt = x[0xC4...0xC8].unpack('N').first
      f.seek(offset_of_srpt * 0x800)
      x = f.read(512)
      titles = x[0...2].unpack('n').first
      offset = 8
      (1..titles).each do |i| 
        a = x.slice(offset, 12).unpack("ccnnccN")
        title_map[i] = { :vts => a[4], :pgc => a[5] }
        offset += 12
      end
    end
    title_map
  end
end

class Stream
  attr_reader :id, :info, :stream
  def initialize(track, id, info, stream)
    @track = track
    @id = id
    @info = info
    @stream = stream
  end
  
  def encode
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
end

class VideoStream < Stream
  def initialize(track, id, info, stream)
    super track, id, info, stream
  end
  
  def encode
    precrop_avs
    autocrop
    avs
    autobitrate
    encode1
    encode2
  end
  
  def mux
    path = "#{@track.tempdir}\\VTS_#{'%02d' % @track.vts}.264"
    "--default-duration 0:#{@track.fps}000/1001fps " +
    "-d 0 -A -S -T \"#{path}\""
  end
  
private
  def precrop_avs
    path = "#{@track.tempdir}\\VTS_#{'%02d' % @track.vts}"
    c = @track.video_stream.crop
    x = <<EOS
LoadPlugin("#{$meguiPath}\\tools\\dgindex\\DGDecode.dll")
DGDecode_mpeg2source("#{path}_1.d2v", info=3)
LoadPlugin("#{$meguiPath}\\tools\\avisynth_plugin\\ColorMatrix.dll")
ColorMatrix(hints=true, threads=0)
EOS
    avs_file = File.open(path + '-precrop.avs', 'w') do |file|
      file.puts x
      if @track.interlaced then
        file.puts "Load_Stdcall_Plugin(\"#{$meguiPath}\\tools\\yadif\\yadif.dll\")"
        file.puts "Yadif(order=-1)"
      end
    end
  end
  
  def autocrop
    if @track.video_stream.autocrop then
      path_precrop_avs = "#{@track.tempdir}\\VTS_#{'%02d' % @track.vts}-precrop.avs"
      @ac = WIN32OLE.new('autocroplib.AutoCrop')
      @ac.GetAutoCropValues(path_precrop_avs)
      c = Crop.new(@ac.left, @ac.top, @ac.right, @ac.bottom)
      puts "Autocrop to #{c}"
      @track.video_stream.crop = c
    end
  end
    
  def avs
    path_precrop_avs = "#{@track.tempdir}\\VTS_#{'%02d' % @track.vts}-precrop.avs"
    path_avs = "#{@track.tempdir}\\VTS_#{'%02d' % @track.vts}.avs"
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
    puts "Video bitrate = %d" % @bitrate
  end
  
  def encode1
    puts "Video encoding - pass 1"
    path = "#{@track.tempdir}\\VTS_#{'%02d' % @track.vts}"
    x264_cmd1 = "\"#{$meguiPath}\\tools\\x264\\x264.exe\" --profile high --sar #{@track.video_stream.dx}:#{@track.video_stream.dy} --preset #{$x264preset} " +
    "--tune film --pass 1 --bitrate #{@bitrate} --stats \"#{path}.stats\" --thread-input --output NUL \"#{path}.avs\""
    %x{#{x264_cmd1}}
  end

  def encode2
    puts "Video encoding - pass 2"
    path = "%s\\VTS_%02d" % [@track.tempdir, @track.vts]
    x264_cmd2 = "\"#{$meguiPath}\\tools\\x264\\x264.exe\" --profile high --sar #{@track.video_stream.dx}:#{@track.video_stream.dy} --preset #{$x264preset} " +
    "--tune film --pass 2 --bitrate #{@bitrate} --stats \"#{path}.stats\" --thread-input --aud --output \"#{path}.264\" \"#{path}.avs\""
    %x{#{x264_cmd2}}
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

private
  def vobsubrip
    puts "Extracting subtitles"
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
  def initialize(track, chapter_filename)
    @track = track
    @chapter_filename = chapter_filename
  end
  
  def mux
    "--chapters \"#{@chapter_filename}\""
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
    puts "Processing #{@name}"
    @disk.mount
    decrypt
    demux
    parse_stream_file
    encode
    mux
  end
  
  def decrypt
    puts "Decrypting"
    decrypt_cmd = "\"#{$decrypterPath}\" /SRC #{@disk.drive_letter}: /DEST \"#{@tempdir}\" /VTS #{@vts} /PGC #{@pgc} /MODE IFO /START /CLOSE"
    %x{#{decrypt_cmd}}
  end
  
  def parse_stream_file
    puts "Parsing stream info file"
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
    @streams << video
    @streams << ChapterStream.new(self, "#{@path} - Chapter Information - OGG.txt")
  end
  
  def encode
    @streams.each { |s| s.encode }
  end
  
  def demux
    puts "Demuxing"
    path = "#{@path}_1"
    demux_cmd = "\"#{$demuxPath}\" -i \"#{path}.VOB\" -o \"#{path}\" -fo #{@ivtc ? 1 : 0} -exit"
    %x{#{demux_cmd}}
  end
  
  def mux
    puts "Remuxing"
    path = "#{@outdir}\\#{@name}.mkv"
    mux_cmd = "\"#{$mkvmergePath}\" -o \"#{path}\" " + @streams.map { |s| s.mux }.join(' ')
    %x{#{mux_cmd}}
  end
end

TrackDoneFileName = 'tracks-done.yaml'

disk_index = 0
begin 
  tracks_done = File.exist?(TrackDoneFileName) ? YAML::load(File.read(TrackDoneFileName)) : {}
  more_work = false
  project = YAML::load_file('dvdrip.yaml')
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
    title = d["title"] || 1
    season = d["season"] || 1
    episode = d["episode"] || 1
    type = d["type"] || "film"
    track_names = []
    if d["tracks"].nil? then
      track_names << { :name => name, :title => title }
    else
      d["tracks"].each do |t|
        track_name = "#{name} - S#{'%02d' % season}E#{'%02d' % episode} - #{t}"
        title += 1
        episode += 1
        track_names << { :name => track_name, :title => title }
      end
    end
    
    track_names.delete_if { |t| tracks_done.has_key?(t[:name]) }
    tracks = track_names.map { |t|
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

