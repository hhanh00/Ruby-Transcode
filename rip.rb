require "rexml/document"
require "fileutils"
require "yaml"
$tempdir = 'D:\TEMPRIP'

$clonedrivePath = 'C:\Program Files\Elaborate Bytes\VirtualCloneDrive\Daemon.exe'
$clonedriveLetter = 'F'
$clonedriveIndex = 0

$decrypterPath = 'C:\Program Files\DVD Decrypter\DVDDecrypter.exe'
$meguiPath = 'C:\Program Files\megui'
$mkvmergePath = 'C:\Program Files\MKVtoolnix\mkvmerge.exe'

$demuxPath = $meguiPath + '\tools\dgindex\DGIndex.exe'

class Crop
  attr_accessor :top, :bottom, :left, :right
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
  attr_accessor :crop, :bitrate
  attr_reader :dx, :dy
  def initialize(crop, dar, bitrate)
    @crop = crop
    dar =~ /(\d+):(\d+)/
    darX, darY = $1.to_i, $2.to_i
    @dx = darX * 2
    @dy = darY * 3
    @bitrate = bitrate
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
  attr_accessor :image
  def initialize(image)
    @image = image
    @mounted = false
  end
  
  def mount
    if !@mounted then
      puts "Mounting image file %s" % @image
      mount_cmd = "\"%s\" -mount %d,\"%s\"" % [$clonedrivePath, $clonedriveIndex, @image]
      %x{#{mount_cmd}}
      sleep 10
      @mounted = true
    end
  end
end

class IncInt
  attr_reader :value
  def initialize(str)
    str =~ /(\d+)(\+?)/
    @value = $1.to_i
    @inc = $2
  end
  
  def next
    @value += 1 if @inc == '+' 
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
  attr_reader :audio_filename
  def initialize(track, id, info, stream)
    super track, id, info, stream
    path = "%s\\%s" % [$tempdir, @track.subdir]
    track_number = "T%02x" % id
    @audio_filename = Dir.foreach(path).find { |f| f =~ /#{track_number}/ }
    @audio_filename =~ /DELAY (.*)ms/
    @delay = $1.to_i
  end
  
  def mux
    path = "%s\\%s\\%s" % [$tempdir, @track.subdir, @audio_filename]
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
    avs
    encode1
    encode2
  end
  
  def mux
    path = "%s\\%s\\VTS_%02d.264" % [$tempdir, @track.subdir, @track.vts]
    "--default-duration 0:24000/1001fps " +
    "-d 0 -A -S -T \"%s\"" % path
  end
  
private
  def avs
    path = "%s\\%s\\VTS_%02d" % [$tempdir, @track.subdir, @track.vts]
    c = @track.video_stream.crop
    x = <<EOS
LoadPlugin("%s\\tools\\dgindex\\DGDecode.dll")
DGDecode_mpeg2source("%s_1.d2v", info=3)
LoadPlugin("%s\\tools\\avisynth_plugin\\ColorMatrix.dll")
ColorMatrix(hints=true, threads=0)
EOS
    avs_file = File.open(path + '.avs', 'w') do |file|
      file << x % [$meguiPath, path, $meguiPath]
      if c.left != 0 || c.right != 0 || c.top != 0 || c.bottom != 0 then
        file << "crop(%d, %d, -%d, -%d)" % [c.left, c.top, c.right, c.bottom]
      end
    end
  end
  
  def encode1
    puts "Video encoding - pass 1"
    path = "%s\\%s\\VTS_%02d" % [$tempdir, @track.subdir, @track.vts]
    x = <<EOS
\"%s\\tools\\x264\\x264.exe\" --profile high --sar %d:%d --preset slower --tune film --pass 1 --bitrate %d --stats "%s.stats" --thread-input --output NUL "%s.avs" 
EOS
    x264_cmd1 = x % [$meguiPath, @track.video_stream.dx, @track.video_stream.dy, @track.video_stream.bitrate, path, path]
    %x{#{x264_cmd1}}
  end

  def encode2
    puts "Video encoding - pass 2"
    path = "%s\\%s\\VTS_%02d" % [$tempdir, @track.subdir, @track.vts]
    x = <<EOS
\"%s\\tools\\x264\\x264.exe\" --profile high --sar %d:%d --preset slower --tune film --pass 2 --bitrate %d --stats "%s.stats" --thread-input --aud --output "%s.264" "%s.avs" 
EOS
    x264_cmd2 = x % [$meguiPath, @track.video_stream.dx, @track.video_stream.dy, @track.video_stream.bitrate, path, path, path]
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
    path = "%s\\%s\\\VTS_%02d-fix.IDX" % [$tempdir, @track.subdir, @track.vts]
    x = @sub_streams.zip(0...@sub_streams.length)
    arg = x.inject("") { |s, a| s + a[0].mux(a[1]) }
    arg + " -s %s -D -A -T \"%s\"" % [(0...@sub_streams.length).to_a.join(','), path]
  end

private
  def vobsubrip
    puts "Extracting subtitles"
    vobsub_param = "%s\\%s\\vobsub.txt" % [$tempdir, @track.subdir]
    File.open(vobsub_param, 'w') do |f|
      f.puts "%s\\%s\\VTS_%02d_0.IFO" % [$tempdir, @track.subdir, @track.vts]
      f.puts "%s\\%s\\VTS_%02d" % [$tempdir, @track.subdir, @track.vts]
      f.puts @track.pgc
      f.puts 0
      @sub_streams.each { |s| f.puts "#{s.id} " }
      f.puts 'CLOSE'
      end
      
    vobsub_cmd = "rundll32.exe vobsub.dll,Configure %s" % vobsub_param
    %x{#{vobsub_cmd}}
  end
  
  def timecorrect
    delays = []
    File.open("%s\\%s\\VTS_%02d.IDX" % [$tempdir, @track.subdir, @track.vts], "r") do |f|
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

    File.open("%s\\%s\\VTS_%02d.IDX" % [$tempdir, @track.subdir, @track.vts], "r") do |fr|
      File.open("%s\\%s\\VTS_%02d-fix.IDX" % [$tempdir, @track.subdir, @track.vts], "w") do |fw|
        while line = fr.gets
          fw.puts line
          if line =~ /index: (\d+)/ then
            id = $1.to_i
            fw.puts "delay: %s" % delays[id]
          end
        end
      end
    end
    
    FileUtils.cp "%s\\%s\\VTS_%02d.SUB" % [$tempdir, @track.subdir, @track.vts],
      "%s\\%s\\VTS_%02d-fix.SUB" % [$tempdir, @track.subdir, @track.vts]
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
  attr_reader :subdir, :vts, :pgc, :name, :video_stream, :audio_streams, :sub_streams
  
  def initialize(outdir, vts, pgc, name, disk, video_stream, audio_streams, sub_streams)
    @outdir = outdir
    @vts = vts
    @pgc = pgc
    @name = name
    @disk = disk
    @video_stream = video_stream
    @audio_streams = audio_streams
    @sub_streams = sub_streams
    @subdir = "%d.%d" % [@vts, @pgc]
  end
  
  def run
    puts "Processing %s" % @name
    mount
    decrypt
    demux
    parse_stream_file
    encode
    mux
  end
  
  def mount
    @disk.mount
  end
  
  def decrypt
    puts "Decrypting"
    decrypt_cmd = "\"%s\" /SRC %s: /DEST \"%s\\%s\" /VTS %d /PGC %d /MODE IFO /START /CLOSE" % 
    [$decrypterPath, $clonedriveLetter, $tempdir, @subdir, @vts, @pgc]
    %x{#{decrypt_cmd}}
  end
  
  def parse_stream_file
    @streams = []
    sub_streams = []
    stream_file = File.open("%s\\%s\\VTS_%02d - Stream Information.txt" % [$tempdir, @subdir, @vts], 'r') do |file|
      while line = file.gets
        s = nil
        id, type, info = line.split(' - ', 3)
        case type
        when "Subtitle"
          language, x = info.split(' - ', 2)
          info =~ /SubPicture (\d+)/
          index = $1.to_i - 1
          t = @sub_streams.find { |t| t.language == language }
          sub_streams << SubtitleStream.new(self, index, info, t) if t
        when "Audio"
          x, x, x, x, language, x, x, x = info.split(' / ', 8)
          t = @audio_streams.find { |t| t.language == language }
          s = AudioStream.new(self, id, info, t) if t
        when "Video"
          s = VideoStream.new(self, id, info, @video_stream)
        end
        @streams << s if s
      end
    end

    @streams << VobSubStream.new(self, sub_streams) if sub_streams.length != 0
    @streams << ChapterStream.new(self, "%s\\%s\\VTS_%02d - Chapter Information - OGG.txt" % [$tempdir, @subdir, @vts])
  end
  
  def encode
    @streams.each { |s| s.encode }
  end
  
  def demux
    puts "Demuxing"
    path = "%s\\%s\\VTS_%02d_1" % [$tempdir, @subdir, @vts]
    demux_cmd = "\"%s\" -i \"%s.VOB\" -o \"%s\" -fo 1 -exit" %
    [$demuxPath, path, path]
    %x{#{demux_cmd}}
  end
  
  def mux
    puts "Remuxing"
    path = "%s\\%s.mkv" % [@outdir, @name]
    mux_cmd = "%s -o \"%s\"" % [$mkvmergePath, path] + @streams.reduce("") { |arg, s| arg + ' ' + s.mux }
    %x{#{mux_cmd}}
  end
end

project = YAML::load(File.read('dvdrip.yaml'))
tracks = []
outdir = project["outdir"]
c = Crop.new(project["crop"]["left"], project["crop"]["top"], project["crop"]["right"], project["crop"]["bottom"])
video_stream = Video.new(c, project["dar"], project["bitrate"])
audio_streams = project["audio"].map { |lang| Audio.new(lang) }
sub_streams = project["sub"].map { |lang| Sub.new(lang) }
project["disk"].each do |d|
  disk = Disk.new(d["image"])
  format_name = d["name"]
  d["tracks"].each do |t|
    ipgc = IncInt.new(t["pgc"])
    ivts = IncInt.new(t["vts"])
    iepisode = IncInt.new(t["episode"])
    t["track"].each do |name|
      pgc, vts, episode = ipgc.value, ivts.value, iepisode.value
      track_name = eval "\"#{format_name}\""
      ipgc.next
      ivts.next
      iepisode.next
      tracks << Track.new(outdir, vts, pgc, track_name, disk, video_stream, audio_streams, sub_streams)
    end
  end
end

tracks.each { |t| t.run }
