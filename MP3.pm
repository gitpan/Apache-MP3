package Apache::MP3;
 
use strict;
use Apache::Constants qw(:common REDIRECT HTTP_NO_CONTENT DIR_MAGIC_TYPE);
use Apache::File;
use MP3::Info;
use CGI qw/:standard escape *table *TR *blockquote *center *h1/;
use File::Basename 'dirname','basename';
use File::Path;
use vars '$VERSION','@ISA';
# @ISA = 'Apache';
my $CRLF = "\015\012";

$VERSION = '2.06';

# defaults:
use constant BASE_DIR     => '/apache_mp3';
use constant STYLESHEET   => 'apache_mp3.css';
use constant PARENTICON   => 'back.gif';
use constant PLAYICON     => 'play.gif';
use constant SHUFFLEICON  => 'shuffle.gif';
use constant CDICON       => 'cd_icon.gif';
use constant CDLISTICON   => 'cd_icon_small.gif';
use constant SONGICON     => 'sound.gif';
use constant ARROWICON    => 'right_arrow.gif';
use constant SUBDIRCOLUMNS => 3;
use constant HELPURL      => 'apache_mp3_help.gif:614x498';

my $NO  = '^(no|false)$';  # regular expression
my $YES = '^(yes|true)$';  # regular expression

sub handler {
  __PACKAGE__->handle_request(@_);
}

sub handle_request {
  my $pack = shift;
  my $obj = $pack->new(@_) or die "Can't create object: $!";
  $obj->run();
}

sub new {
  my $class = shift;
  unshift @_,'r' if @_ == 1;
  return bless { @_ },$class;
}

sub r { return shift->{r} }

sub run {
  my $self = shift;
  my $r = $self->r;

  # generate directory listing   
  return $self->process_directory($r->filename) 
    if -d $r->filename;  # should be $r->finfo, but STILL problems with this

  #simple download of file
  return $self->download_file($r->filename) unless param;

  # this is called to stream a file
  return $self->stream if param('stream');

  # this is called to generate a playlist on the curren directory
  return $self->send_playlist($self->find_mp3s)
    if param('Play All');

  # this is called to generate a playlist on the current directory
  # and everything beneath
  return $self->send_playlist($self->find_mp3s('recursive')) 
    if param('Play All Recursive') ;

  # this is called to generate a shuffled playlist of current directory
  return $self->send_playlist($self->find_mp3s,'shuffle')
    if param('Shuffle');

  # this is called to generate a shuffled playlist of current directory
  return $self->send_playlist($self->find_mp3s,'shuffle')
    if param('Shuffle All');

  # this is called to generate a shuffled playlist of current directory
  # and everything beneath
  return $self->send_playlist($self->find_mp3s('recursive'),'shuffle')
    if param('Shuffle All Recursive');

  # this is called to generate a playlist for one file
  if (param('play')) {
    my($basename) = $r->uri =~ m!([^/]+?)(\.m3u)?$!;
    $basename = quotemeta($basename);
    # find the MP3 file that corresponds to basename.m3u
    my @matches = grep { m!/$basename! } @{$self->find_mp3s};
    $self->send_playlist(\@matches);
    return OK;
  }

  # this is called to generate a playlist for selected files
  if (param('Play Selected')) {
    return HTTP_NO_CONTENT unless my @files = param('file');
    my $uri = dirname($r->uri);
    $self->send_playlist([map { "$uri/$_" } @files]);
    return OK;
  }

  return DECLINED;  # otherwise don't know how to deal with this
}

# this generates the top-level directory listing
sub process_directory {
  my $self = shift;
  my $dir = shift;
  
  unless ($self->r->path_info){
    #Issue an external redirect if the dir isn't tailed with a '/'
    my $uri = $self->r->uri;
    my $query = $self->r->args;
    $query = "?" . $query if defined $query;
    $self->r->header_out(Location => "$uri/$query");
    return REDIRECT;
  }

  return $self->list_directory($dir);
}

# this downloads the file
sub download_file {
  my $self = shift;
  my $file = shift;
  unless ($self->download_ok) {
    $self->r->log_reason('File downloading is forbidden');
    return FORBIDDEN;
  } else {
    return DECLINED;  # allow Apache to do its standard thing
  }
}


# stream the indicated file
sub stream {
  my $self = shift;
  my $r = $self->r;

  return DECLINED unless -e $r->filename;  # should be $r->finfo

  unless ($self->stream_ok) {
    $r->log_reason('AllowStream forbidden');
    return FORBIDDEN;
  }
  
  if ($self->check_stream_client and !$self->is_stream_client) {
    my $useragent = $r->header_in('User-Agent');
    $r->log_reason("CheckStreamClient is true and $useragent is not a streaming client");
    return FORBIDDEN;
  }

  return $self->send_stream($r->filename,$r->uri);
}

# this generates a playlist for the MP3 player
sub send_playlist {
  my $self = shift;
  my ($urls,$shuffle) = @_;
  return HTTP_NO_CONTENT unless @$urls;
  my $r = $self->r;
  my $base = $self->stream_base;

  $r->send_http_header('audio/mpegurl');
  return OK if $r->header_only;

  $self->shuffle($urls) if $shuffle;
  foreach (@$urls) {
    s!([^a-zA-Z0-9/.-])!uc sprintf("%%%02x",ord($1))!eg ;
    $r->print ("$base$_?stream=1$CRLF");
  }
  return OK;
}

# this searches the current directory for MP3 files and subdirectories
sub find_mp3s {
  my $self = shift;
  my $recurse = shift;
  my $dir = dirname($self->r->filename);
  my $uri = dirname($self->r->uri);

  my $uris = $self->_find_mp3s($dir,$recurse);
  foreach (@$uris) {
    substr($_,0,length($dir)) = '' if index($_,$dir) == 0; # strip directory part
    $_ = "$uri/$_";
  }
  return $uris;
}

# recursive find
sub _find_mp3s {
  my $self = shift;
  my ($d,$recurse) = @_;

  my ($directories,$files) = $self->read_directory($d);
  my @f = $self->sort_mp3s($files);
  # we now have sorted list of files, so add directory back
  foreach (@f) { $_ = "$d/$_" unless $d eq '.' }

  if ($recurse) {
    push @f,@{$self->_find_mp3s("$d/$_",$recurse)} foreach @$directories;
  } 

  return \@f;
}

# sort MP3s
sub sort_mp3s {
  my $self = shift;
  my $files = shift;
  return sort keys %$files;
}

# shuffle an array
sub shuffle {
  my $self = shift;
  my $list = shift;
  for (my $i=0; $i<@$list; $i++) {
    my $rand = rand(scalar @$list);
    ($list->[$i],$list->[$rand]) = ($list->[$rand],$list->[$i]);  # swap
  }
}

# top level for directory display
sub list_directory {
  my $self = shift;
  my $dir  = shift;
  return DECLINED unless my ($directories,$mp3s) = $self->read_directory($dir);

  $self->r->send_http_header('text/html');
  return OK if $self->r->header_only;

  $self->directory_top($dir);
  $self->list_subdirs($directories) if @$directories;
  $self->list_mp3s($mp3s)           if %$mp3s;
  print hr                         unless %$mp3s;
  $self->directory_bottom($dir);
  return OK;
}

# print the HTML at the top of a directory listing
sub directory_top {
  my $self = shift;
  my $dir  = shift; # actually not used
  my $title = $self->r->uri;
  print start_html(-title => $title,
		   -style => {-src=>$self->stylesheet});

  my $links;
  if ($self->path_style eq 'staircase') {
    $links = $self->generate_navpath_staircase($title);
  } else {
    $links = $self->generate_navpath_arrows($title);
  }
  print table(
	      Tr({-align=>'LEFT'},
		 td(a({-href=>'./playlist.m3u?Play+All+Recursive=1'},
			 img({-src => $self->cd_icon, -align=>'MIDDLE',
			      -alt=> 'Play All',-border=>0})),
		       td($links))),

	      Tr({-align=>'LEFT'},
		 td({-colspan=>2},
		    a({-href=>'./playlist.m3u?Shuffle+All+Recursive=1'},
		      font({-class=>'directory'},'[Shuffle All]'))
		    .'&nbsp;'.
		    a({-href=>'./playlist.m3u?Play+All+Recursive=1'},
		      font({-class=>'directory'},'[Stream All]'))
		    )
		),
	     );
  if (my $t = $self->stream_timeout) {
    print p(strong('Note:'),"In this demo, streaming is limited to approximately $t seconds.\n");
  }
}

# staircase style path
sub generate_navpath_staircase {
  my $self = shift;
  my $uri = shift;
  my $home =  $self->home_label;

  my @components = split '/',$uri;
  unshift @components,'' unless @components;
  my ($path,$links);
  my $current_style = "line-height: 1.2; font-weight: bold; color: red;";
  my $parent_style  = "line-height: 1.2; font-weight: bold;";
  my $indent = 0;

  foreach (@components) {
    $path .= escape($_) ."/";
    if ($_ eq $components[-1]) {
      $links .= div({-style=>"text-indent: ${indent}em; $current_style"},
		    font({-size=>'+1'},$_ || $home))."\n";
    } else {
      my $l = a({-href=>$path},$_ || $home);
      $links .= div({-style=>"text-indent: ${indent}em; $parent_style"},
		    font({-size=>'+1'},$l))."\n";
    }
    $indent += 3.0;
  }
  return $links;
}

# alternative display on one line using arrows
sub generate_navpath_arrows {
  my $self = shift;
  my $uri = shift;
  my $home =  $self->home_label;

  my @components = split '/',$uri;
  unshift @components,'' unless @components;
  my $path;
  my $links = start_h1();
  my $arrow = $self->arrow_icon;
  foreach (@components) {
    $links .= '&nbsp;' . img({-src=>$arrow}) if $path;
    $path .= escape($_) . "/";
    if ($_ eq $components[-1]) {
      $links .= "&nbsp;". ($_ || $home);
    } else {
       $links .= '&nbsp;' . a({-href=>$path},$_ || $home);
    }
  }
  $links .= end_h1();
  return $links;
}

# print the HTML at the bottom of the page
sub directory_bottom {
  my $self = shift;
  my $dir  = shift;  # actually not used

  print 
    table({-width=>'100%',-border=>0},
	  TR(
	     td({-align=>'LEFT'},
		address('Apache::MP3 was written by',		
			a({-href=>'http://stein.cshl.org'},'Lincoln D. Stein'))
		),
	     td({-align=>'RIGHT'},$self->get_help))
	     );
  print end_html;
}


# print the HTML at the top of the list of subdirs
sub subdir_list_top {
  my $self   = shift;
  my $subdirs = shift;  # array reference
  print hr;
  print h2({-class=>'CDdirectories'}, sprintf('CD Directories (%d)',scalar @$subdirs));
}

# print the HTML at the bottom of the list of subdirs
sub subdir_list_bottom {
  my $self   = shift;
  my $subdirs = shift;  # array reference
}

# print the HTML to format the list of subdirs
sub subdir_list {
  my $self   = shift;
  my $subdirs = shift; #array reference
  my @subdirs = $self->sort_subdirs($subdirs);

  my $cols = $self->subdir_columns;
  my $rows =  int(0.99 + @subdirs/$cols);

  print start_center,
        start_table({-border=>0,-width=>'95%'}),"\n";

  for (my $row=0; $row < $rows; $row++) {
    print start_TR({-valign=>'BOTTOM'});
    for (my $col=0; $col<$cols; $col++) {
      my $i = $col * $rows + $row;
      my $contents = $subdirs[$i] ? $self->format_subdir($subdirs[$i]) : '&nbsp;';
      print td($contents);
    }
    print end_TR,"\n";
  }
  print end_table,end_center;
}

# given a list of CD directories, sort them
sub sort_subdirs {
  my $self = shift;
  my $subdirs = shift;
  return sort @$subdirs; # alphabetic sort by default
}

# format an subdir entry and return its HTML
sub format_subdir {
  my $self = shift;
  my $subdir = shift;
  my $nb = '&nbsp;';
  (my $title = $subdir) =~ s/\s/$nb/og;  # replace whitespace with &nbsp;
  my $result = p(
		 a({-href=>escape($subdir).'/playlist.m3u?Play+All+Recursive=1'},
		   img({-src=>$self->cd_list_icon,
			-align=>'ABSMIDDLE',
			-class=>'subdir',
			-alt=>'Play Contents',
			-border=>0}))
		 .$nb.
			  a({-href=>escape($subdir).'/'},font({-class=>'subdirectory'},$title)),
		 br,
		 a({-class=>'subdirbuttons',
		    -href=>escape($subdir).'/playlist.m3u?Shuffle+All+Recursive=1'},'[Shuffle]')
		 .$nb.
		 a({-class=>'subdirbuttons',
		    -href=>escape($subdir).'/playlist.m3u?Play+All+Recursive=1'},'[Stream]'));
  return $result;
}

# This generates the link for help
sub get_help {
  my $self = shift;
  my $help_url = $self->help_url;
  my ($url,$width,$height) = $help_url=~/(.+):(\d+)x(\d+)/;
  $url ||= $help_url;
  $width  ||= 500;
  $height ||= 400;
  return
    a({-href        => $url,
       -frame       => '_new',
       -onClick     => qq(window.open('$url','','height=$height,width=$width'); return false),
       -onMouseOver => "status='Show Help Window';return true",
      },
      'Quick Help Summary');
}

# this is called to display the subdirs (subdirectories) within the current directory
sub list_subdirs {
  my $self   = shift;
  my $subdirs = shift;  # arrayref
  $self->subdir_list_top($subdirs);
  $self->subdir_list($subdirs);
  $self->subdir_list_bottom($subdirs);
}

# this is called to display the MP3 files within the current directory
sub list_mp3s {
  my $self = shift;
  my $mp3s = shift;  #hashref

  $self->mp3_list_top($mp3s);
  $self->mp3_list($mp3s);
  $self->mp3_list_bottom($mp3s);
}

# top of MP3 file listing
sub mp3_list_top {
  my $self = shift;
  my $mp3s = shift;  #hashref
  print hr;

  my $uri = $self->r->uri;  # for self referencing
  $uri =~ s!([^a-zA-Z0-9/])!uc sprintf("%%%02x",ord($1))!eg;

  print start_form(-action=>"${uri}playlist.m3u");  

  print
    a({-name=>'cds'}),
    start_table({-border=>0,-cellspacing=>0,-width=>'100%'}),"\n";

  print  TR(td(),
	    td({-align=>'LEFT',-colspan=>4},
	       submit('Play Selected'),submit('Shuffle All'),submit('Play All'))) 
    if $self->stream_ok and keys %$mp3s > $self->file_list_is_long;

  my $count = keys %$mp3s;
  print h2({-class=>'SongList'},"Song List ($count)"),"\n";
  $self->mp3_table_header;
}

sub mp3_table_header {
  my $self = shift;
  my $url = url(-absolute=>1,-path_info=>1);

  my @fields = map { ucfirst($_) } $self->fields;
  print TR({-class=>'title',-align=>'LEFT'},
	   th({-colspan=>2,-align=>'CENTER'},p($self->stream_ok ? 'Select' : '')),
	   th(\@fields)),"\n";
}

# bottom of MP3 file listing
sub mp3_list_bottom {
  my $self = shift;
  my $mp3s = shift;  #hashref
  print  TR(td(),
	    td({-align=>'LEFT',-colspan=>4},
	       submit('Play Selected'),submit('Shuffle All'),submit('Play All'))) 
    if $self->stream_ok;
  print end_table,"\n";
  print end_form;
  print hr;
}

# each item of the list
sub mp3_list {
  my $self = shift;
  my $mp3s = shift;  #hashref

  my @f = $self->sort_mp3s($mp3s);
  my $count = 0;
  for my $song (@f) {
    my $highlight = $count++ % 2 ? 'highlight' : 'normal';
    my $contents   = $self->format_song($song,$mp3s->{$song},$count);
    print TR({-class=>$highlight},td($contents));
  }
}

# return the contents of the table for each mp3
sub format_song {
  my $self = shift;
  my ($song,$info,$count) = @_;
  my @contents = ($self->format_song_controls($song,$info,$count),
		  $self->format_song_fields  ($song,$info,$count));
  return \@contents;
}

# format the control part of each mp3 in the listing (checkbox, etc)
# each list item becomes a cell in the table
sub format_song_controls {
  my $self = shift;
  my ($song,$info,$count) = @_;  

  my $song_title = sprintf("%3d. %s", $count, $info->{title} || $song);
  my $url = escape($song);
  (my $play = $url) =~ s/(\.[^.]+)?$/.m3u?play=1/;

  my $controls .= checkbox(-name=>'file',-value=>$song,-label=>'') if $self->stream_ok;
  $controls    .= a({-href=>$url}, b('&nbsp;[fetch]'))             if $self->download_ok;
  $controls    .= a({-href=>$play},b('&nbsp;[stream]'))            if $self->stream_ok;

  return (
	  p(
	    $self->stream_ok ? a({-href=>$play},img({-src=>$self->song_icon,-alt=>'Play Song',-border=>0}))
	                     : img({-src=>$self->song_icon})
	   ),
	  p(
	    $controls
	    )
	 );
}

# format the fields of each mp3 in the listing (artist, bitrate, etc)
sub format_song_fields {
  my $self = shift;
  my ($song,$info,$count) = @_;
  return map { $info->{lc $_}=~/^\d+$/ ? 
                   p({-align=>'RIGHT'},$info->{lc($_)},'&nbsp') : 
                   p($info->{lc($_)} || '&nbsp;') } $self->fields;
}

# read a single directory, returning lists of subdirectories and MP3 files
sub read_directory {
  my $self      = shift;
  my $dir       = shift;

  my (@directories,%seen,%mp3s);

  opendir D,$dir or return;
  while (defined(my $d = readdir(D))) {
    next if $self->skip_directory($d);
    my $mime = $self->r->lookup_file("$dir/$d")->content_type;
    push(@directories,$d) if !$seen{$d}++ && $mime eq DIR_MAGIC_TYPE;
    next unless $mime eq 'audio/mpeg';
    $mp3s{$d} = $self->fetch_info("$dir/$d");
  }
  closedir D;
  return \(@directories,%mp3s);
}


# return title, artist, duration, and kbps
sub fetch_info {
  my $self = shift;
  my $file = shift;

  if (!$self->read_mp3_info) {  # don't read config info
    my $f = basename($file);
    return {
	    filename    => $f,
	    description => $f,
	   };
  }

  my %data = $self->read_cache($file);
  return \%data if %data;

  return unless my $info = get_mp3info($file);

  my $tag  = get_mp3tag($file);
  my ($title,$artist,$album,$year,$comment,$genre,$track) = 
    @{$tag}{qw(TITLE ARTIST ALBUM YEAR COMMENT GENRE TRACKNUM)} if $tag;
  my $duration = sprintf "%dm %2.2ds", $info->{MM}, $info->{SS};
  my $seconds  = ($info->{MM} * 60) + $info->{SS};
  my $kbps     = "$info->{BITRATE} kbps";

  my $base = basename($file,".mp3",".MP3",".mpeg",".MPEG");
  my $title_string = $title || $base;

  $title_string .= " - $artist" if $artist;
  $title_string .= " ($album)"  if $album;

  %data =(title        => $title || $base,
	  artist       => $artist,
	  duration     => $duration,
	  kbps         => $kbps,
	  genre        => $genre,
	  album        => $album,
	  comment      => $comment,
	  seconds      => $seconds,
	  description  => $title_string,
	  track        => $track || '',
	  bitrate      => $info->{BITRATE},
	  filename     => basename($file),
	 );
  $self->write_cache($file => \%data);
  return \%data;
}

# get fields to display in list of MP3 files
sub fields {
  my $self = shift;
  my @f = split /\W+/,$self->r->dir_config('Fields');
  return map { lc $_  } @f if @f;          # lower case
  return qw(title artist duration bitrate); # default
}

# read from the cache
sub read_cache {
  my $self = shift;
  my $file = shift;
  return unless my $cache = $self->cache_dir;
  my $cache_file = "$cache$file";
  my $file_age = -M $file;
  return unless -e $cache_file && -M $cache_file <= $file_age;
  return unless my $c = Apache::File->new($cache_file);
  my $data;
  read($c,$data,5000);  # read to end of file
  return split $;,$data;   # split into fields
}

# write to the cache
sub write_cache {
  my $self = shift;
  my ($file,$data) = @_;
  return unless my $cache = $self->cache_dir;
  my $cache_file = "$cache$file";
  my $dirname = dirname($cache_file);
  -d $dirname || eval{mkpath($dirname)} || return;
  if (my $c = Apache::File->new(">$cache_file")) {
    print $c join $;,%$data;
  }
  1;
}

# stream an MP3 file
sub send_stream {
  my $self = shift;
  my ($file,$url) = @_;
  my $r = $self->r;
  
  my $info = $self->fetch_info($file);
  return DECLINED unless $info;  # not a legit mp3 file?
  open (FILE,$file) || return DECLINED;
  
  my $title = $info->{description};
  my $genre = $info->{genre} || 'unknown';
  
  $r->print("ICY 200 OK$CRLF");
  $r->print("icy-notice1:<BR>This stream requires a shoutcast/icecast compatible player.<BR>$CRLF");
  $r->print("icy-notice2:Apache::MP3 module<BR>$CRLF");
  $r->print("icy-name:$title$CRLF");
  $r->print("icy-genre:$genre$CRLF");
  $r->print("icy-url:",$self->stream_base(),$CRLF);  # interferes with nice scrolling display in xmms
  $r->print("icy-pub:1$CRLF");
  $r->print("icy-br:$info->{BITRATE}$CRLF");
  $r->print("$CRLF");
  return OK if $r->header_only;

  if (my $timeout = $self->stream_timeout) {
    my $seconds  = $info->{seconds};
    my $fraction = $timeout/$seconds;
    my $bytes    = int($fraction * -s $file);
    while ($bytes > 0) {
      my $data;
      my $b = read(FILE,$data,2048) || last;
      $bytes -= $b;
      $r->print($data);
    }
    return OK;
  }

  # we get here for untimed transmits
  $r->send_fd(\*FILE);
  return OK;
}

#################################################
# interesting configuration directives start here
#################################################

#utility subroutine for configuration
sub get_dir {
  my $self = shift;
  my ($config,$default) = @_;
  my $dir = $self->r->dir_config($config) || $default;
  return $dir if $dir =~ m!^/!;       # looks like a path
  return $dir if $dir =~ m!^\w+://!;  # looks like a URL
  return $self->default_dir . '/' . $dir;
}

# return true if downloads are allowed from this directory
sub download_ok {
  shift->r->dir_config('AllowDownload') !~ /$NO/oi;
}

# return true if streaming is allowed from this directory
sub stream_ok {
  shift->r->dir_config('AllowStream') !~ /$NO/oi;
}

# return true if we should check that the client can accomodate streaming
sub check_stream_client {
  shift->r->dir_config('CheckStreamClient') =~ /$YES/oi;
}

# return true if client can stream
sub is_stream_client {
  my $r = shift->r;
  $r->header_in('Icy-MetaData')   # winamp/xmms
    || $r->header_in('Bandwidth')   # realplayer
      || $r->header_in('Accept') =~ m!\baudio/mpeg\b!;  # mpg123 and others
}

# whether to read info for each MP3 file (might take a long time)
sub read_mp3_info { 
  shift->r->dir_config('ReadMP3Info') !~ /$NO/oi;
}

# whether to time out streams
sub stream_timeout { 
  shift->r->dir_config('StreamTimeout') || 0;
}

# how long an album list is considered so long we should put buttons
# at the top as well as the bottom
sub file_list_is_long { shift->r->dir_config('LongList') || 10 }

sub home_label {
  my $self = shift;
  my $home = $self->r->dir_config('HomeLabel') || 'Home';
  return lc($home) eq 'hostname' ? $self->r->hostname : $home;
}

sub path_style {  # style for the path to parent directories
  lc(shift->r->dir_config('PathStyle')) || 'staircase';
}

# where is our cache directory (if any)
sub cache_dir    { 
  my $self = shift;
  return unless my $dir  = $self->r->dir_config('CacheDir');
  return $self->r->server_root_relative($dir);
}

# columns to display
sub subdir_columns {shift->r->dir_config('SubdirColumns') || SUBDIRCOLUMNS  }

# various configuration variables
sub default_dir  { shift->r->dir_config('BaseDir') || BASE_DIR  }
sub stylesheet   { shift->get_dir('Stylesheet', STYLESHEET)     }
sub parent_icon  { shift->get_dir('ParentIcon',PARENTICON)      }
sub cd_icon      { shift->get_dir('TitleIcon',CDICON)           }
sub cd_list_icon { shift->get_dir('DirectoryIcon',CDLISTICON)   }
sub song_icon    { shift->get_dir('SongIcon',SONGICON)          }
sub arrow_icon   { shift->get_dir('ArrowIcon',ARROWICON)        }
sub help_url     { shift->get_dir('HelpURL',HELPURL)  }
sub stream_base {
  my $self = shift;
  my $r = $self->r;
  my $basename = $r->dir_config('StreamBase');
  return $basename if $basename;
  my $auth_info;
  my ($res,$pw) = $r->get_basic_auth_pw;
  if ($res == 0) { # authentication in use
    my $user = $r->connection->user;
    $auth_info = "$user:$pw\@";
  }
  $basename = "http://$auth_info" . $r->hostname;
  $basename .= ':' . $r->get_server_port 
    unless $r->get_server_port == 80;
  return $basename;
}


# patterns to skip
sub skip_directory { 
  my $self = shift;
  my $dir = shift;
  return 1 if $dir =~ /^\./;
  return 1 if $dir eq 'CVS';
  return 1 if $dir eq 'RCS';
  return 1 if $dir eq 'SCCS';
  undef;
}

1;
__END__

=head1 NAME

Apache::MP3 - Generate streamable directories of MP3 files

=head1 SYNOPSIS

 # httpd.conf or srm.conf
 AddType audio/mpeg    mp3 MP3

 # httpd.conf or access.conf
 <Location /songs>
   SetHandler perl-script
   PerlHandler Apache::MP3
 </Location>

  # Or use the Apache::MP3::Sorted subclass to get sortable directory listings
 <Location /songs>
   SetHandler perl-script
  PerlHandler Apache::MP3::Sorted
 </Location>

A B<demo version> can be browsed at http://www.modperl.com/Songs/.

=head1 DESCRIPTION

This module makes it possible to browse a directory hierarchy
containing MP3 files, sort them on various fields, download them,
stream them to an MP3 decoder like WinAmp, and construct playlists.
The display is configurable and subclassable.

ppNOTE: This version of Apache::MP3 is substantially different from
the pre-2.0 version described in The Perl Journal.  Specifically, the
format to use for HREF links has changed.  See I<Linking> for details.

=head2 Installation

This section describes the installation process.

=over 4

=item 1. Prequisites

This module requires mod_perl and MP3::Info, both of which are
available on CPAN.

=item 2. Configure MIME types

Apache must be configured to recognize the mp3 and MP3 extensions as
MIME type audio/mpeg.  Add the following to httpd.conf or srm.conf:

 AddType audio/mpeg mp3 MP3

=item 3. Install icons and stylesheet

This module uses a set of icons and a cascading stylesheet to generate
its song listings.  By default, the module expects to find them at the
url /apache_mp3.  Create a directory named apache_mp3 in your document
root, and copy into it the contents of the F<apache_mp3> directory
from the Apache-MP3 distribution.

You may change the location of this directory by setting the
I<BaseDir> configuration variable.  See the I<Customizing> section for
more details.

=item 4. Set Apache::MP3 or Apache::MP3::Sorted as handler for MP3 directory

In httpd.conf or access.conf, create a E<lt>LocationE<gt> or
E<lt>DirectoryE<gt> section, and make Apache::MP3 the handler for this
directory.  This example assumes you are using the URL /Songs as the
directory where you will be storing song files:

  <Location /Songs>
    SetHandler perl-script
    PerlHandler Apache::MP3
  </Location>

If you would prefer an MP3 file listing that allows the user to sort
it in various ways, set the handler to use the Apache::MP3::Sorted
subclass instead.  This is recommended

=item 5. Load MP3::Info in the Perl Startup file (optional)

For the purposes of faster startup and memory efficiency, you may load
the MP3::Info module at server startup time.

=item 6. Set up MP3 directory

Create a directory in the web server document tree that will
contain the MP3 files to be served.  The module recognizes and handles
subdirectories appropriately.  I suggest organizing directories by
artist and or CD title.  For directories containing multiple tracks
from the same CD, proceed each mp3 file with the track number.  This
will ensure that the directory listing sorts in the right order.

=item 7. Set up an information cache directory (optional)

In order to generate its MP3 listing, Apache::MP3 must open each sound
file, extract its header information, and close it.  This is time
consuming, particularly when recursively generating playlists across
multiple directories.  To speed up this process, Apache::MP3 has the
ability cache MP3 file information in a separate directory area.

To configure this, create a directory that the Web server sill have
write access to, such as /usr/tmp/mp3_cache, and add this
configuration variable to the <Location> directive:

 PerlSetVar  CacheDir       /usr/tmp/mp3_cache

If the designated does not exist, Apache::MP3 will attempt to create
it, limited of course by the Web server's privileges.

=back

Open up the MP3 URL in your favorite browser.  If things don't seem to
be working, checking the server error log for informative messages.

=head1 CUSTOMIZING

Apache::MP3 can be customized in three ways: (1) by changing
per-directory variables; (2) changing settings in the Apache::MP3
cascading stylesheet; and (3) subclassing Apache::MP3 or
Apache::MP3::Sorted.

=head2 Per-directory configuration variables

Per-directory variables are set by PerlSetVar directives in the
Apache::MP3 E<lt>LocationE<gt> or E<lt>DirectoryE<gt> section.  For
example, to change the icon displayed next to subdirectories of MP3s,
you would use PerlSetVar to change the DirectoryIcon variable:

  PerlSetVar DirectoryIcon big_cd.gif

This table summarizes the configuration variables.  A more detailed
explanation of each follows.

 CONFIGURATION VARIABLES FOR PerlSetVar

 Name                  Value	        Default
 ----                  -----            -------

 AllowDownload	       yes|no		yes
 AllowStream	       yes|no		yes
 CheckStreamClient     yes|no		no
 ReadMP3Info	       yes|no		yes

 StreamTimout          integer          0
 SubdirColumns	       integer		3
 LongList	       integer		10
 Fields                list             title,artist,duration,bitrate
 SortField             field name       filename
 PathStyle             Staircase|Arrows Staircase

 BaseDir	       URL		/apache_mp3
 CacheDir              path             -none-
 HomeLabel	       string		"Home"
 StreamBase            URL              -none-

 Stylesheet	       URL		apache_mp3.css
 TitleIcon	       URL		cd_icon.gif
 DirectoryIcon	       URL		cd_icon_small.gif
 SongIcon	       URL		sound.gif
 ArrowIcon	       URL		right_arrow.gif
 ParentIcon	       URL		back.gif    # defunct

=over 4

=item AllowDownload I<yes|no>

You may wish for users to be able to stream songs but not download
them to their local disk.  If you set AllowDownload to "no",
Apache::MP3 will not generate a download link for MP3 files.  It will
also activate some code that makes it inconvenient (although not
impossible) for users to download the MP3s.

The arguments "yes", "no", "true" and "false" are recognized.  The
default is "yes".

=item AllowStream I<yes|no>

If you set AllowStream to "no", users will not be able to stream songs
or generate playlists.  I am not sure why one would want this feature,
but it is included for completeness.  The default is "yes."

=item CheckStreamClient I<yes|no>

Setting CheckStreamClient to "yes" enables code that checks whether
the client claims to be able to accept streaming MPEG data.  This
check isn't foolproof, but supports at least the most popular MP3
decoders (WinAmp, RealPlayer, xmms, mpg123).  It also makes it harder
for users to download songs by pretending to be a streaming player.

The default is "no".

=item ReadMP3Info I<yes|no>

This controls whether to extract field information from the MP3
files.  The default is "yes".

If "no" is specified, all fields in the directory listing will be
blank except for I<filename> and I<description>, which will both be
set to the physical filename of the MP3 file.

=item StreamTimeout I<integer>

For demo mode, you can specify a stream timeout in seconds.
Apache::MP3 will cease streaming the file after the time specified.
Because this feature does not take into account TCP-buffered song
data, the actual music may not stop playing until five or 10 seconds
later.

=item SubdirColumns I<integer>

The number of columns in which to display subdirectories (the small
"CD icons").  Default 3.

=item LongList I<integer>

The number of lines in the list of MP3 files after which it is
considered "long".  In long lists, the control buttons are placed at
the top as well as at the bottom of the table.  Defaults to 10.

=item Fields I<title,artist,duration,bitrate>

Specify what MP3 information fields to display in the song listing.
This should be a list delimited by commas, "|" symbols, or any other
non-word character.

The following are valid fields:

    Field        Description

    title        The title of the song
    artist       The artist
    album	 The album
    track	 The track number
    genre        The genre
    description	 Description in the form "title - artist (album)"
    comment      The comment field
    duration     Duration of the song in hour, minute, second format
    seconds      Duration of the song in seconds
    kbps         Streaming rate of song in kilobits/sec
    filename	 The physical name of the .mp3 file

Note that MP3 rip and encoding software differ in what fields they
capture and the exact format of such fields as the title and album.

=item SortField I<field>

This configuration variable sets the default sort field when file
listings are initially displayed.  Any of the MP3 information fields
listed in the previous section are allowed.  By default, the sort
direction will be alphabetically or numerically ascending.  Reverse
this by placing a "-" in front of the field name.  Examples:

  PerlSetVar SortField  title      # sort ascending by title
  PerlSetVar SortField  -kbps      # sort descending by kbps

B<NOTE:> Sorting is only implemented in the Apache::MP3::Sorted
module.

=item PathStyle I<Staircase|Arrows>

Controls the style with which the parent directories are displayed.
The options are "Staircase" (the default), which creates a
staircase-style display (each child directory is on a new line and
offset by 0.3 em).  The other is "Arrows", in which the entire
directory list is on a single line and separated by graphic arrows.
Try them both and choose the one you prefer.

=item BaseDir I<URL>

The B<BaseDir> variable sets the URL in which Apache::MP3 will look
for its icons and stylesheet.  You may use an absolutea local or
remote URL. Relative URLs are not accepted.

The default is "/apache_mp3."

=item CacheDir I<path>

This variable sets the directory path for Apache::MP3's cache of MP3
file information.  This must be an absolute path in the physical file
system and be writable by Apache.

=item Stylesheet I<URL>

Set the URL of the cascading stylesheet to use, "apache_mp3.css" by
default.  If the URL begins with a slash it is treated as an absolute
URL.  Otherwise it is interpreted as relative to the BaseDir
directory.

=item TitleIcon I<URL>

Set the icon displayed next to the current directory's name,
"cd_icon.gif" by default.  In this, and the other icon-related
directives, relative URLs are treated as relative to I<BaseDir>.

The default is "cd_icon.gif".

=item DirectoryIcon I<URL>

Set the icon displayed next to subdirectories in directory listings,
"cd_icon_small.gif" by default.

=item SongIcon I<URL>

Set the icon displayed at the beginning of each line of the MP3 file
list, "sound.gif" by default.

=item ArrowIcon I<URL>

Set the icon used for the arrows displayed between the components of
the directory path at the top of the directory listing.

=item ParentIcon I<URL>

This configuration variable is no longer used, but remains for
backward compatibility.

=item HomeLabel I<string>

This is the label for the link used to return to the site's home
page.  You may use plain text or any fragment of HTML, such as an
<IMG> tag.

=item StreamURL I<URL>

A URL to use as the base for streaming.  The default is to use the
same host for both directory listings and streaming.  This may be of
use for transparent reverse proxies.

Example:

If the song requested is http://www.foobar.com/Songs/Madonna_live.m3u?stream=1

and B<StreamURL> is set to I<http://streamer.myhost.net>, then the URL
placed in the playlist will be

 http://streamer.myhost.net/Songs/Madonna_live.m3u?stream=1

A more general rewrite facility is not available, but might be added
if requested.

=item HelpURL I<URL:widthxheight>

The URL of the page to display when the user presses the "Quick Help
Summary" link at the bottom of the page.  In the current
implementation, the module pops up a plain window containing a
marked-up GIF of a typical page. You can control the size of this page
by adding ":WxH" to the end of the URL, where W and H are the width
and height, respectively.  

Default: apache_mp3_help.gif:614x498

=back

=head2 Stylesheet-Based Configuration

You can change the appearance of the page by changing the cascading
stylesheet that accompanies this module, I<apache_mp3.css>.  The
following table describes the tags that can be customized:

 Class Name           Description
 ----------           ----------

 BODY                 General defaults
 H1                   Current directory path
 H2                   "CD Directories" and "Song List" headings
 TR.title             Style for the top line of the song listing
 TR.normal            Style for odd-numbered song listing lines
 TR.highlight         Style for even-numbered song listing lines
 .directory           Style for the title of the current directory
 .subdirectory        Style for the title of subdirectories
 P                    Ordinary paragraphs
 A                    Links
 INPUT                Fill-out form fields

=head2 Subclassing this Module

For more extensive customization, you can subclass this module.  The
Apache::MP3::Sorted module illustrates how to do this.  

Briefly, your module should inherit from Apache::MP3 (or
Apache::MP3::Sorted) either by setting the C<@ISA> package global or,
in Perl 5.6 and higher, with the C<use base> directive.  Your module
should define a handler() subroutine that creates a new instance of
the subclass and immediately calls its handle_request() method.  This
illustrates the idiom:

  package Apache::MP3::EvenBetter;
  use strict;
  use Apache::MP3::Sorted;
  use base Apache::MP3::Sorted;

  sub handler {
    __PACKAGE__->handle_request(@_);
  }

  # new and overridden methods, etc....
  1;

I decided not to use Apache method handlers for this after I
discovered that I had to completely stop and relaunch the server every
time I made a change to the module (even with PerlFreshRestart on).

See I<The Apache::MP3 API> below for more information on overriding
Apache::MP3 methods.

=head1 Linking to this module

You may wish to create links to MP3 files and directories manually.
The rules for creating HREFs are different from those used in earlier
versions of Apache::MP3, a decision forced by the fact that the
playlist format used by popular MP3 decoders has changed.

The following rules apply:

=over 4

=item Download an MP3 file

Create an HREF using the unchanged name of the MP3 file.  For example, 
to download the song at /songs/Madonna/like_a_virgin.mp3, use:

 <a href="/Songs/Madonna/like_a_virgin.mp3">Like a Virgin</a>

=item Stream an MP3 file

Replace the MP3 file's extension with .m3u and add the query string
"play=1".  Apache::MP3 will generate a playlist for the streaming MP3
decoder to load.  Example:

 <a href="/Songs/Madonna/like_a_virgin.m3u?play=1">
         Like a streaming Virgin</a>

=item Stream a directory

Append "/playlist.m3u?Play+All=1" to the end of the directory name:

 <a href="/Songs/Madonna/playlist.m3u?Play+All=1">Madonna Lives!</a>

The capitalization of "Play All" is significant.  Apache::Mp3 will
generate a playlist containing all MP3 files within the directory.

=item Stream a directory heirarchy recursively

Append "/playlist.m3u?Play+All+Recursive=1" to the end of the directory name:

 <a href="/Songs/HipHop/playlist.m3u?Play+All+Recursive=1">Rock me</a>

The capitalization of "Play All Recursive" is significant.
Apache::MP3 will generate a playlist containing all MP3 files within
the directory and all its subdirectories.

=item Shuffle and stream a directory

Append "/playlist.m3u?Shuffle+All=1" to the end of the directory name:

 <a href="/Songs/HipHop/playlist.m3u?Shuffle+All">Rock me</a>

Apache::MP3 will generate a playlist containing all MP3 files within
the directory and all its subdirectories, and then randomize its order.

=item Shuffle an entire directory heirarchy recursively

Append "/playlist.m3u?Shuffle+All+Recursive=1" to the end of the directory name:

 <a href="/Songs/HipHop/playlist.m3u?Shuffle+All+Recursive=1">Rock me</a>

Apache::MP3 will generate a playlist containing all MP3 files within
the directory and all its subdirectories, and then randomize its order.

=item Play a set of MP3s within a directory

Append "/playlist.m3u?Play+Selected=1;file=file1;file=file2..." to the 
directory name:

 <a
 href="/Songs/Madonna/playlist.m3u?Play+Selected=1;file=like_a_virgin.mp3;file=evita.mp3">
 Two favorites</a>

Again, the capitalization of "Play Selected" counts.

=item Display a sorted directory

Append "?sort=field" to the end of the directory name, where field is
any of the MP3 field names:

 <a href="/Songs/Madonna/?sort=duration">Madonna lives!</a>

=back

=head1 The Apache::MP3 API

The Apache::MP3 object is a blessed hash containing a single key,
C<r>, which points at the current request object.  This can be
retrieved conveniently using the r() method.

Apache::MP3 builds up its directory listing pages in pieces, using a
hierarchical scheme.  The following diagram summarizes which methods() 
are responsible for generating the various parts.  It might help to
study it alongside a representative HTML page:

 list_directory()
 -------------------------  page top --------------------------------
    directory_top()

    <CDICON> <DIRECTORY> -> <DIRECTORY> -> <DIRECTORY>
    [Shuffle All] [Stream All]

    list_subdirs()

         subdir_list_top()
         ------------------------------------------------------------
         <CD Directories (6)>

         subdir_list()
               <cdicon> <title>   <cdicon> <title>  <cdicon> <title>
               <cdicon> <title>   <cdicon> <title>  <cdicon> <title>

         subdir_list_bottom()  # does nothing
         ------------------------------------------------------------

    list_mp3s()
         mp3_list_top()
         ------------------------------------------------------------
         <Song List (4)>

         mp3_list()
             mp3_list_top()
               mp3_table_header()
                  <Select>                  Title          Kbps

               format_song() # called for each row
                  <icon>[] [fetch][stream]  Like a virgin  128
                  <icon>[] [fetch][stream]  American Pie   128
                  <icon>[] [fetch][stream]  Santa Evita     96
                  <icon>[] [fetch][stream]  Boy Toy        168

             mp3_list_bottom()
               [Play Selected] [Shuffle All] [Play All]

    directory_bottom()
 -------------------------  page bottom -----------------------------

=head2 Method Calls

This section lists each of the Apache::MP3 method calls briefly.

=over 4 

=item $response_code = handler($request)

This is a the standard mod_perl handler() subroutine.  It is a simple
front-end to Apache::MP3->handle_request().  As described above under
I<Subclassing this Module>, you will need to provide a minimal
handler() subroutine for each subclass you create.

=item $mp3 = Apache::MP3->new(@args)

This is a constructor.  It stores the passed args in a hash and
returns a new Apache::MP3 object.  If a single argument is passed it
assumes that it is an Apache::Request object and stores it under the
key "r".  You should not have to modify this method.

=item $response_code = Apache::MP3->handle_request(@args)

This is the other constructor.  It calls new() to create a new $mp3
argument and immediately calls its run() method.  You should not have
to modify this method.

=item $request = $mp3->r()

Return the stored request object.

=item $response_code = $mp3->run()

This is the method that interprets the CGI parameters and dispatches
to the routines that draw the directory listing, generate playlists,
and stream songs.

=item $response_code = $mp3->process_directory($dir)

This is the top-level method for generating the directory listing.  It
performs various consistency checks on the passed directory URL and
returns an Apache response code.  The list_directory() method actually 
does most of the formatting work.

=item $response_code = $mp3->download_file($file)

This method is called to download a file (not stream it).  It is
passed the URL of the requested file and returns an Apache response
code.  It checks whether downloads are allowed and if so allows Apache 
to take its default action.

=item $response_code = $mp3->stream($file)

This method is called to stream an MP3 file.  It is passed the URL of
the requested file and returns an Apche response code.  It checks
whether streaming is allowed and then passes the request on to
send_stream().

-item $mp3->send_playlist($urls,$shuffle)

This method generates a playlist that is sent to the browser.  It is
called from various places.  C<$urls> is an array reference containing 
the MP3 URLs to incorporate into the playlist, and C<$shuffle> is a
flag indicating that the order of the playlist should be randomized
prior to sending it.  No return value is returned.

=item $mp3_info = $mp3->find_mp3s($recurse)

This method searches for all MP3 files in the currently requested
directory.  C<$recurse>, if true, causes the method to recurse through
all subdirectories.  The return value is a hashref in which the keys
are the URLs of the found MP3s, and the values are hashrefs containing
the MP3 tag fields recovered from the files ("title", etc.).

=item @urls = $mp3->sort_mp3s($mp3_info)

This method sorts the hashref of MP3 files returned from find_mp3s(),
returning an array.  The implementation of this method in Apache::MP3
sorts by physical file name only.  Apache::MP3::Sorted has a more
sophisticated implementation.

=item $response_code = $mp3->list_directory($dir)

This is the top level formatter for directory listings.  It is passed
the URL of a directory and returns an Apache response code.

=item $mp3->directory_top($dir)

This method lists the top part of the directory, including the title,
the directory navigation list, and the big CD Icon in the upper left.

=item $mp3->generate_navpath_staircase($dir)

This method generates the list of parent directories, displaying them
as links so that the user can navigate.  It takes the URL of the
current directory and returns no result.

=item $mp3->generate_navpath_arrows($dir)

This method does the same, except that the parent directories are
displayed on a single line, separated by arrows.

=item $mp3->directory_bottom($dir)

This method generates the bottom part of the directory listing,
including the module attribution and help information.

=item $mp3->subdir_list_top($directories)

This method generates the heading at the top of the list of
subdirectories.  C<$directories> is an arrayref containing the
subdirectories to list.

=item $mp3->subdir_list_bottom($directories)

This method generates the footer at the bottom of the list of
subdirectories given by C<$directories>.  Currently it does nothing.

=item $mp3->subdir_list($directories)

This method invokes sort_subdirs() to sort the subdirectories given by
C<$directories> and displays them in a nicely-formatted table.

=item @directories = $mp3->sort_subdirs($directories)

This method sorts the subdirectories given in C<$directories> and
returns a sorted B<list> (not an arrayref).

=item $html = $mp3->format_subdir($directory)

This method formats the indicated subdirectory by creating a fragment
of HTML containing the little CD icon, the shuffle and stream links,
and the subdirectory's name.  It returns an HTML fragment used by
subdir_list().

=item $mp3->get_help

This subroutine generates the "Quick Help Summary" link at the bottom
of the page.

=item $mp3->list_subdirs($subdirectories)

This is the top-level subroutine for listing subdirectories (the part
of the page in which the little CD icons appears).  C<$subdirectories>
is an array reference containing the subdirectories to display

=item $mp3->list_mp3s($mp3s)

This is the top-level subroutine for listing MP3 files.  C<$mp3s> is a
hashref in which the key is the path of the MP3 file and the value is
a hashref containing MP3 tag info about it.  This generates the
buttons at the top of the table and then calls mp3_table_header() and
mp3_list_bottom().

=item $mp3->mp3_table_header

This creates the first row (table headers) of the list of MP3 files.

=item $mp3->mp3_list_bottom($mp3s)

This method generates the buttons at the bottom of the MP3 file
listing. C<$mp3s> is a hashref containing information about each file.

=item $mp3->mp3_list($mp3s)

This routine sorts the MP3 files contained in C<$mp3s> and invokes
format_song() to format it for the table.

=item $arrayref = $mp3->format_song($song,$info,$count)

This method is called with three arguments.  C<$song> is the path to
the MP3 file, C<$info> is a hashref containing tag information from
the song, and C<$count> is an integer containing the song's position
in the list (which currently is unusued).  The method invokes
format_song_controls() and format_song_fields() to generate a list of
elements to be incorporated into cells of the table, and returns an
array reference.

=item @array = $mp3->format_song_controls($song,$info,$count)

This method is called with the same arguments as format_song().  It
returns a list (not an arrayref) containing the "control" elements of
one row of the MP3 list.  The control elements are all the doo-dads on
the left-hand side of the display, including the music icon, the
checkbox, and the [fetch] and [stream] links.

=item @array = format_song_fields($song,$info,$count)

This method is called with the same arguments as format_song().  It
returns a list (not an arrayref) containing the rest of a row of the
MP3 file display.  This will include the title, artist, and so forth,
depending on the values of the Fields configuration. variable.

=item ($directories,$mp3s) = $mp3->read_directory($dir)

This method reads the directory in C<$dir>, generating an arrayref
containing the subdirectories and a hashref containing the MP3 files
and their information, which are returned as a two-element list.

=item $hashref = $mp3->fetch_info($file)

This method fetches the MP3 information for C<$file> and returns a
hashref containing the MP3 tag information as well as some synthesized
fields.  The synthesized fields are I<track>, which contains the same
information as I<tracknum>; I<description>, which contains the title,
album and artist merged together; and I<duration>, which contains the
duration of the song expressed as hours, minutes and seconds.  Other
fields are taken directly from the MP3 tag, but are downcased (for
convenience to other routines).

=item @fields = $mp3->fields

Return the fields to display for each MP3 file.  Reads the I<Fields>
configuration variable, or uses a default list.

=item $hashref = $mp3->read_cache($file)

Reads the cache for MP3 information about the indicated file.  Returns
a hashref of the same format used by fetch_info().

=item $boolean = $mp3->write_cache($file,$info)

Writes MP3 information to cache.  C<$file> and C<$info> are the path
to the file and its MP3 tag information, respectively.  Returns a
boolean indicating the success of the operation.

=item $result_code = $mp3->send_stream($file,$uri)

The send_stream() method generates an ICY (shoutcast) header for the
indicated file (given by physical path C<$file> and URI C<$uri>) and
streams it to the client.  It returns an Apache result code indicating 
the success of the operation.

=item $boolean = $mp3->download_ok

Returns true if downloading files is allowed.

=item $boolean = $mp3->stream_ok

Returns true if streaming files is allowed.

=item $boolean = $mp3->check_stream_client

Returns true if the module should check the browser/MP3 player for
whether it accepts streaming.

=item $boolean = $mp3->is_stream_client

Returns true if this MP3 player can accept streaming.  Note that this
is not a foolproof method because it checks a variety of
non-standardized headers and user agent names!

=item $boolean = $mp3->read_mp3_info

Returns true if the module should read MP3 info (true by default).

=item $seconds = $mp3->stream_timeout

Returns the number of seconds after which streaming should time out.
Used for "demo mode".

=item $lines = $mp3->file_list_is_long

Returns the number of lines in the MP3 file listing after which the
list is considered to be "long".  When a long list is encountered, the 
module places the control buttons at both the top and bottom of the
MP3 file table, rather than at the bottom only.  This method 

=item $html = $mp3->home_label

Returns a fragment of HTML to use as the "Home" link in the list of
parent directories.

=item $style = $mp3->path_style

Returns the style of the list of parent directories.  Either "arrows"
or "staircase".

=item $path = $mp3->cache_dir

Returns the directory for use in caching MP3 tag information

=item $int = $mp3->subdir_columns

Returns the number of columns to use in displaying subdirectories
(little CD icons).

=item $dir = $mp3->default_dir

Returns the base directory used for resolving relative paths in the
directories to follow.

=item miscellaneous directories and files

The following methods return the values of their corresponding
configuration variables, resolved against the base directory, if need
be:

 stylesheet()   URI to the stylesheet file
 parent_icon()	URI to the icon to use to move up in directory
                     hierarchy (no longer used)
 cd_icon        URI for the big CD icon printed in the upper left corner
 cd_list_icon   URI for the little CD icons in the subdirectory listing
 song_icon	URI for the music note icons printed for each MP3 file
 arrow_icon	URI for the arrow used in the navigation bar
 help_url	URI of the document to display when user asks for help

=item $boolean = $mp3->skip_directory($dir)

This method is called during directory listings.  It returns true if
the directory should not be displayed.  Currently it skips directories
beginning with a dot and various source code management directories.
You may subclass this to skip over other directories.

=back

=head1 BUGS

Although it is pure Perl, this module relies on an unusual number of
compiled modules.  Perhaps for this reason, it appears to be sensitive
to certain older versions of modules.

=head2 Can't find Apache::File at run time

David Wheeler <dwheeler@salon.com> has reported problems relating to
Apache::File, in which the module fails to run, complaining that it
can't find Apache::File in @INC.  This affects Apache/1.3.12
mod_perl/1.24.  Others have not yet reported this problem.  This can
be worked around by replacing all occurrences of Apache::File with
IO::File.

=head2 Random segfaults in httpd children

Before upgrading to Apache/1.3.6 mod_perl/1.24, I would see random
segfaults in the httpd children when using this module.  This problem
disappeared when I installed a newer mod_perl.

If you experience this problem, I have found that one workaround is to
load the MP3::Info module at server startup time using the mod_perl
perl.startup script made the problem go away.  This is an excerpt from
my perl.startup file:

 # the !/usr/local/bin/perl
 ...
 use Apache::Registry ();
 use Apache::Constants();
 use MP3::Info;
 use Apache::MP3;
 use CGI();
 use CGI::Carp ();

=head2 Can't use -d $r->finfo

Versions of mod_perl prior to 1.22 crash when using the idiom -d
$r->finfo (or any other idiom).  Since there are many older versions
still out there, I have replaced $r->finfo with $r->filename and
marked their locations in comments.  To get increased performance,
change back to $r->finfo.

=head2 Misc

In the directory display, the alignment of subdirectory icon with the
subdirectory title is a little bit off.  I want to move the title a
bit lower using some stylesheet magic.  Can anyone help?

=head1 SEE ALSO

L<Apache::MP3::Sorted>, L<MP3::Info>, L<Apache>

=head1 AUTHOR

Copyright 2000, Lincoln Stein <lstein@cshl.org>.

This module is distributed under the same terms as Perl itself.  Feel
free to use, modify and redistribute it as long as you retain the
correct attribution.

=cut
