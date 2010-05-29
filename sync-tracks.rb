require 'aws'
require 'Yaml'
require 'set'

$disk_name = 'st1000'
$sdb = Aws::SdbInterface.new('<access key>', '<secret key>')

#$sdb.delete_domain('dvd')
#$sdb.create_domain('dvd')

def upload_tracks(array)
  tracks_yaml = YAML::load_file('tracks-done.yaml')
  s = Set.new(array)
  a = s.to_a.map { |t| Aws::SdbInterface::Item.new(t, {'hd' => $disk_name }, true) }
  i = 0
  while true do
    batch = a[i*25...(i+1)*25]
    break if batch.nil? 
    $sdb.batch_put_attributes('dvd', batch)
    i = i + 1
  end
end

def download_tracks
  x = []
  next_token = nil
  while true do
    tracks_sdb = $sdb.select('select * from dvd', next_token)
    next_token = tracks_sdb[:next_token]
    x = x.concat(tracks_sdb[:items].map { |t| t.keys[0] })
    break if next_token.nil?
  end
  Set.new(x)
end

def delete_tracks(array)
  array.each { |t| $sdb.delete_attributes('dvd', t) }
end

def create_hash
  tracks_sdb = download_tracks
  tracks_done = Hash.new
  tracks_sdb.each { |t| tracks_done[t] = $disk_name }
  File.open('t-out.yaml', 'w') { |f| YAML::dump(tracks_done, f) }
end

def upload
  tracks_yaml = Set.new(YAML::load_file('tracks-done.yaml').keys)
  tracks_sdb = download_tracks

  #to_del = tracks_sdb - tracks_yaml
  #delete_tracks(to_del.to_a) unless to_del.empty?

  to_add = tracks_yaml - tracks_sdb
  upload_tracks(to_add.to_a) unless to_add.empty?
end

create_hash
#upload