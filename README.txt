What is it?
-----------
A script that automates transcoding a DVD image into a MKV file.
It will:
  - mount the image with Virtual CloneDrive,
  - decrypt the movie title(s) with DVD Decrypter,
  - demux the streams with DGIndex,
  - select the best audio stream of your choice of language,
  - reencode the video with X264 with one of the presets,
  - rip the subtitles with VobSub and correct the timecodes
  - and finally remux everything into a Matroska file in MKVMerge.
  
Pros
----
  - Pretty flexible when it comes to what to streams and languages to keep.
  - Can process multiple disks.
  - Can handle multiple titles per disk. Very useful for TV show DVDs.
  - Can name your output file automatically based on a template
  - Small footprint
  
Cons
----
  - No installer.
  - No GUI.
  - Not easy to configure.
  - Lots of 3rd party tools to gather and install.
  - Need to know some YAML.

INSTALLATION
------------

1. Get and install the following tools
  - Slysoft Virtual CloneDrive
  - DVD Decrypter
  - MEGUI
  - VobSub
  - MKVToolnix
  - optionally AnyDVD because it's just the best DVD ripper
    but it's commercial
  
2. Install Ruby for Windows
3. Open an admin command prompt
  - Register autocroplib.dll
      regsvr32 autocroplib.dll
4. Edit the dvdrip.yaml file and change the first section
  This mostly means changing the paths to your tools if you haven't installed them
  in their default location
  Also change the drive letter that Virtual Clonedrive uses when it mounts its image
  If you have several virtual drives you may also need to change the index of the drive

NOTE: For better encoding quality, update the tools from time to time in MeGUI or
by downloading from http://www.x264.nl. The x264 encoder has frequent updates.

CONFIGURATION
-------------

The dvdrip.yaml file has all the configuration settings. When you edit it, keep it
mind that it's a YAML file and it doesn't like tabs.

tempdir: D:\TEMPRIP
This is where the tool will store temporary files. They are not deleted before and after
the encode. Just in case you want to take a peek of what the tool does.

outdir: e:\two
This is where the output files go.

bitrate: 1200
This is the bitrate of the video stream after reencoding.

x264preset: slower
This is the quality preset in x264.

audio:
- English
This is a list of the audio languages that you want to keep.
If you want to add the Director's Commentary you need to add this here too
The tool will only keep AC3 tracks and pick the ones that have the highest 
number of channels. Often, DVDs have a down-mixed track in stereo and the
tool will skip them.

sub:
- English
This is the list of the subtitle languages that you want to keep.

disk:
This is a list of the disks that you want the tool to process.
Ex of one disk
- image: e:\TWO_AND_A_HALF_MEN_SEASON_2_D3.iso
  name: "Two and a Half Men - S02E#{'%02d' % episode} - #{name}"
  tracks:
  - title: 6
    episode: 19
    track:
    - A Low, Guttural Tongue-Flapping Noise
    - I Always Wanted A Shaved Monkey
    - A Sympathetic Crotch To Cry On

For each disk, you have to specify:
* the image name - it's either the path of an ISO file or a single drive letter
* the template for the output file name. See below
* the list of tracks. See below

The template for the output file name is a format string in Ruby.
In this example: "Two and a Half Men - S02E#{'%02d' % episode} - #{name}",
we used #{name} which will be replaced by the actual name of the track
and #{'%02d' % episode} which uses an expression between { } that Ruby
evaluates. The expression '%02d' % episode, writes out the episode number as
a 2 digit integer with a leading 0 if needed. Any valid Ruby expression
works here.

The list of tracks is a collection of tracks that follows a sequence.
In the example, we are saying that we want the DVD titles 6, 7, 8 and
they match episode 19, 20, 21. The track names are given by the
track list. 

If your DVD does not have episodes that follow a sequence of titles, you need
to specify several track groups. The 'tracks' entry is itself a list.

The configuration file ends with the --- marker.
The rest of the file is not processed.

Optionally, you can give cropping values for the video. By default the tool will
find the black borders and autocrop it.

USAGE
-----

Once the configuration file is written. Running the tool is easy.
From an admin console,
  ruby rip.rb
