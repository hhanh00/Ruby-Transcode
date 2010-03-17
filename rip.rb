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
      puts "Mounting image file %s" % @image
      mount_cmd = "\"%s\" -mount %d,\"%s\"" % [$clonedrivePath, $clonedriveIndex, @image]
      %x{#{mount_cmd}}
      sleep 10
      $last_mounted = @image
    end
  end

  def parse_vmg
    puts "Parsing Video Manager IFO"
    path = "%s:\\VIDEO_TS\\VIDEO_TS.IFO" % @drive_letter
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
        title_map[i] = { "vts" => a[4], "pgc" => a[5] }
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
  end
  
  def mux
    path = "%s\\%s" % [@track.tempdir, @audio_filename]
    "--language 0:%s " % @stream.language +
    "--sync 0:%d " % @delay +
    "-D -a 0 -S -T \"%s\"" % path
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
    encode1
    encode2
  end
  
  def mux
    path = "%s\\VTS_%02d.264" % [@track.tempdir, @track.vts]
    "--default-duration 0:24000/1001fps " +
    "-d 0 -A -S -T \"%s\"" % path
  end
  
private
  def precrop_avs
    path = "%s\\VTS_%02d" % [@track.tempdir, @track.vts]
    c = @track.video_stream.crop
    x = <<EOS
LoadPlugin("%s\\tools\\dgindex\\DGDecode.dll")
DGDecode_mpeg2source("%s_1.d2v", info=3)
LoadPlugin("%s\\tools\\avisynth_plugin\\ColorMatrix.dll")
ColorMatrix(hints=true, threads=0)
EOS
    avs_file = File.open(path + '-precrop.avs', 'w') do |file|
      file.puts x % [$meguiPath, path, $meguiPath]
    end
  end
  
  def autocrop
    if @track.video_stream.autocrop then
      path_precrop_avs = "%s\\VTS_%02d-precrop.avs" % [@track.tempdir, @track.vts]
      ac = WIN32OLE.new('autocroplib.AutoCrop')
      ac.GetAutoCropValues(path_precrop_avs)
      c = Crop.new(ac.left, ac.top, ac.right, ac.bottom)
      puts 'Autocrop to %s' % c
      @track.video_stream.crop = c
    end
  end
    
  def avs
    path_precrop_avs = "%s\\VTS_%02d-precrop.avs" % [@track.tempdir, @track.vts]
    path_avs = "%s\\VTS_%02d.avs" % [@track.tempdir, @track.vts]
    File.open(path_avs, 'w') do |w|
      File.foreach(path_precrop_avs) do |line|
        w.puts line
      end
      c = @track.video_stream.crop
      if c.left != 0 || c.right != 0 || c.top != 0 || c.bottom != 0 then
        w.puts "crop(%d, %d, -%d, -%d)" % [c.left, c.top, c.right, c.bottom]
      end
    end
  end
  
  def encode1
    puts "Video encoding - pass 1"
    path = "%s\\VTS_%02d" % [@track.tempdir, @track.vts]
    x = <<EOS
\"%s\\tools\\x264\\x264.exe\" --profile high --sar %d:%d --preset %s --tune film --pass 1 --bitrate %d --stats "%s.stats" --thread-input --output NUL "%s.avs" 
EOS
    x264_cmd1 = x % [$meguiPath, @track.video_stream.dx, @track.video_stream.dy, $x264preset, @track.video_stream.bitrate, path, path]
    %x{#{x264_cmd1}}
  end

  def encode2
    puts "Video encoding - pass 2"
    path = "%s\\VTS_%02d" % [@track.tempdir, @track.vts]
    x = <<EOS
\"%s\\tools\\x264\\x264.exe\" --profile high --sar %d:%d --preset %s --tune film --pass 2 --bitrate %d --stats "%s.stats" --thread-input --aud --output "%s.264" "%s.avs" 
EOS
    x264_cmd2 = x % [$meguiPath, @track.video_stream.dx, @track.video_stream.dy, $x264preset, @track.video_stream.bitrate, path, path, path]
    %x{#{x264_cmd2}}
  end
end

class SubtitleStream < Stream
  def initialize(track, id, info, stream)
    super track, id, info, stream
  end

  def mux(index)
    "--language %d:%s" % [index, @stream.language]
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
  end
  
  def mux
    path = "%s\\\VTS_%02d-fix.IDX" % [@track.tempdir, @track.vts]
    x = @sub_streams.zip(0...@sub_streams.length)
    arg = x.map { |a| a[0].mux(a[1]) }.join(' ')
    arg + " -s %s -D -A -T \"%s\"" % [(0...@sub_streams.length).to_a.join(','), path]
  end

private
  def vobsubrip
    puts "Extracting subtitles"
    vobsub_param = "%s\\vobsub.txt" % @track.tempdir
    File.open(vobsub_param, 'w') do |f|
      f.puts "%s\\VTS_%02d_0.IFO" % [@track.tempdir, @track.vts]
      f.puts "%s\\VTS_%02d" % [@track.tempdir, @track.vts]
      f.puts @track.pgc
      f.puts 0
      f.puts @sub_streams.map { |s| "#{s.id}" }.join(' ')
      f.puts 'CLOSE'
      end
      
    vobsub_cmd = "rundll32.exe vobsub.dll,Configure %s" % vobsub_param
    %x{#{vobsub_cmd}}
  end
  
  def timecorrect
    delays = []
    File.open("%s\\VTS_%02d.IDX" % [@track.tempdir, @track.vts], "r") do |f|
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
          delay = (sign < 0 ? "-" : "" ) + "%s:%d" % [delay.strftime("%H:%M:%S"), delay.usec / 1000]
          delays[id] = delay
          look_for_id = true
        end
      end
    end

    File.open("%s\\VTS_%02d-fix.IDX" % [@track.tempdir, @track.vts], "w") do |fw|
      File.foreach("%s\\VTS_%02d.IDX" % [@track.tempdir, @track.vts]) do |line|
        fw.puts line
        if line =~ /index: (\d+)/ then
          id = $1.to_i
          fw.puts "delay: %s" % delays[id]
        end
      end
    end
    
    FileUtils.cp "%s\\VTS_%02d.SUB" % [@track.tempdir, @track.vts],
      "%s\\VTS_%02d-fix.SUB" % [@track.tempdir, @track.vts]
  end
end

class ChapterStream < Stream
  def initialize(track, chapter_filename)
    @track = track
    @chapter_filename = chapter_filename
  end
  
  def mux
    "--chapters \"%s\"" % @chapter_filename
  end
end

class Track
  attr_reader :tempdir, :vts, :pgc, :name, :video_stream, :audio_streams, :sub_streams
  
  def initialize(outdir, vts, pgc, name, disk, video_stream, audio_streams, sub_streams)
    @outdir = outdir
    @vts = vts
    @pgc = pgc
    @name = name
    @disk = disk
    @video_stream = video_stream
    @audio_streams = audio_streams
    @sub_streams = sub_streams
    @tempdir = "%s\\%d.%d.%d" % [$tempdir, @disk.ord, @vts, @pgc]
  end
  
  def run
    puts "Processing %s" % @name
    @disk.mount
    decrypt
    demux
    parse_stream_file
    encode
    mux
  end
  
  def decrypt
    puts "Decrypting"
    decrypt_cmd = "\"%s\" /SRC %s: /DEST \"%s\" /VTS %d /PGC %d /MODE IFO /START /CLOSE" % 
    [$decrypterPath, @disk.drive_letter, @tempdir, @vts, @pgc]
    %x{#{decrypt_cmd}}
  end
  
  def parse_stream_file
    puts "Parsing stream info file"
    @streams = []
    aud_streams = []
    sub_streams = []
    sub_index = 0
    max_channels = 0
    File.foreach("%s\\VTS_%02d - Stream Information.txt" % [@tempdir, @vts]) do |line|
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
        s = VideoStream.new(self, id, info, @video_stream)
        @streams << s
      end
    end

    @streams = @streams.concat(aud_streams.delete_if { |s| s.channels < max_channels })
    @streams << VobSubStream.new(self, sub_streams) if sub_streams.length != 0
    @streams << ChapterStream.new(self, "%s\\VTS_%02d - Chapter Information - OGG.txt" % [@tempdir, @vts])
  end
  
  def encode
    @streams.each { |s| s.encode }
  end
  
  def demux
    puts "Demuxing"
    path = "%s\\VTS_%02d_1" % [@tempdir, @vts]
    demux_cmd = "\"%s\" -i \"%s.VOB\" -o \"%s\" -fo 1 -exit" %
    [$demuxPath, path, path]
    %x{#{demux_cmd}}
  end
  
  def mux
    puts "Remuxing"
    path = "%s\\%s.mkv" % [@outdir, @name]
    mux_cmd = "\"%s\" -o \"%s\" " % [$mkvmergePath, path] + @streams.map { |s| s.mux }.join(' ')
    %x{#{mux_cmd}}
  end
end

TrackDoneFileName = 'tracks-done.yaml'
tracks_done = File.exist?(TrackDoneFileName) ? YAML::load(File.read(TrackDoneFileName)) : {}

disk_index = 0
begin 
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
  project["disk"].each |d|
	disk_index += 1
    disk = Disk.new(d["image"], disk_index)
    disk.mount
    title_map = disk.parse_vmg
    format_name = d["name"] || '#{name}'
    d["tracks"].each do |t|
      title = t["title"] || 1
      episode = t["episode"] || 1
      t["track"].each do |name|
        vts = title_map[title]["vts"]
        pgc = title_map[title]["pgc"]
        track_name = eval "\"#{format_name}\""
        title += 1
        episode += 1
        if !tracks_done.has_key?(track_name) then
          tracks << Track.new(outdir, vts, pgc, track_name, disk, video_stream, audio_streams, sub_streams) 
          more_work = true
        end
      end
    end
  end
  tracks.each do |t| 
    t.run
    tracks_done[t.name] = true
  end

  File.open(TrackDoneFileName, 'w') { |f| YAML::dump(tracks_done, f) }
end while more_work

