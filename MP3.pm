package Apache::MP3;
 
use strict;
use Apache::Constants qw(:common REDIRECT HTTP_NO_CONTENT DIR_MAGIC_TYPE);
use MP3::Info;
use CGI qw/:standard escape *table *TR/;
use vars '$VERSION';

$VERSION = '2.02';

# defaults:
use constant ICON_DIR   => '/apache_mp3';
use constant STYLESHEET => 'apache_mp3.css';
use constant PARENTICON => 'back.gif';
use constant CDICON     => 'cd_icon.gif';
use constant CDLISTICON => 'cd_icon_small.gif';
use constant SONGICON   => 'sound.gif';

my $NO  = '^(no|false)$';  # regular expression
my $YES = '^(yes|true)$';  # regular expression

sub handler {
  my $r = shift;
  if (-d $r->filename) { #  should use $r->finfo here, but causes a crash
    unless ($r->path_info){
      #Issue an external redirect if the dir isn't tailed with a '/'
      my $uri = $r->uri;
      my $query = $r->args;
      $query = "?" . $query if defined $query;
      $r->header_out(Location => "$uri/$query");
      return REDIRECT;
    } elsif (!param('Play All')) {
      return list_directory($r);
    }
  }

  unless (param) { # simple download
    if ($r->dir_config('AllowDownload') =~ /$NO/oi) {
      $r->log_reason('AllowDownload set to false');
      return FORBIDDEN;
    }
    return DECLINED;
  }

  if (param('stream')) {
    return DECLINED unless -e _;
    if ($r->dir_config('AllowStream') =~ /$NO/oi) {
      $r->log_reason('AllowStream set to false');
      return FORBIDDEN;
    }
    if ($r->dir_config('CheckStreamClient') =~ /$YES/oi
	&& !( $r->header_in('Icy-MetaData')   # winamp/xmms
	      || $r->header_in('Bandwidth')   # realplayer
	      || $r->header_in('Accept') =~ m!\baudio/mpeg\b!  # mpg123 and others
	   )) {  
      my $useragent = $r->header_in('User-Agent');
      $r->log_reason("CheckStreamClient is true and $useragent is not a streaming client");
      return FORBIDDEN;
    }
    return send_stream($r,$r->filename,$r->uri);
  }

  if (param('Play Selected')) {
    return HTTP_NO_CONTENT unless my @files = param('file');
    send_playlist($r,\@files);
    return OK;
  }

  (my $dir = $r->filename) =~ s![^/]+$!!;
  if (param('Play All')) {
    my ($d,$mp3s) = read_directory($r,$dir,'skip info');
    return HTTP_NO_CONTENT unless %$mp3s;
    send_playlist($r,[sort keys %$mp3s]);
    return OK;
  }

  if (param('play')) {
    my($basename) = $r->uri =~ m!([^/]+)$!;
    $basename =~ s/\.m3u$//;
    $basename = "$basename.mp3" if -e "$dir/$basename.mp3";  #hack
    $basename = "$basename.MP3" if -e "$dir/$basename.MP3";  #hack again
    send_playlist($r,[$basename]);
    return OK;
  }

  return DECLINED;  # otherwise don't know how to deal with this
}

sub send_playlist {
  my $r = shift;
  my $files = shift;
  my ($path) = $r->uri =~ m!^(.*)/[^/]*$!;
  $path =~ s!([^a-zA-Z0-9/])!uc sprintf("%%%02x",ord($1))!eg;
  $r->send_http_header('audio/mpegurl');
  for my $f (@$files) {
    my $url = 'http://' . $r->hostname  . ":" 
      . $r->get_server_port
	. "$path/" . escape($f);
    $r->print ("$url?stream=1\r\n");
  }
}

sub list_directory {
  my $r = shift;
  my $dir = $r->filename;
  my $uri = $r->uri;
  my $default_dir = $r->dir_config('IconDir')    || ICON_DIR;
  my $stylesheet  = $r->dir_config('Stylesheet') || STYLESHEET;
  my $parent_icon = $r->dir_config('ParentIcon') || PARENTICON;
  my $cd_icon     = $r->dir_config('TitleIcon')     || CDICON;
  my $cd_list_icon= $r->dir_config('DirectoryIcon') || CDLISTICON;
  my $song_icon   = $r->dir_config('SongIcon')   || SONGICON;
  foreach (\$stylesheet,\$parent_icon,\$cd_icon,\$cd_list_icon,\$song_icon) {
    $$_ = "$default_dir/$$_" unless $$_ =~ m!^/!;
  }

  my $download_ok = $r->dir_config('AllowDownload') !~ /$NO/oi;
  my $stream_ok   = $r->dir_config('AllowStream')   !~ /$NO/oi;

  return DECLINED unless my ($directories,$mp3s) = read_directory($r,$dir);

  my $title = $uri;

  print header(),
        start_html(-title  =>$uri,
		   $stylesheet ? (-style => {-src=>$stylesheet}) :()
		  ),
        h1(img({-src=>$cd_icon},$title));

  print img({-src=>$parent_icon}),a({-href=>'..'},'Parent Directory'),br,"\n";

  if (%$directories) {
    print h2({-align=>'LEFT'},'CD Directories');

    print start_table({-border=>0,-width=>'100%'}),"\n";
    # two-column list
    my @d = sort keys %$directories;
    my $rows = @d/2;
    for (my $row=0; $row < $rows; $row++) {
      my $d1 = $d[$row];
      my $d2 = $d[$rows+$row];
      print start_TR({-valign=>'BOTTOM'});
      for (0,1) {
	my $d = $d[$_ * $rows + $row];
	print td(img({-src=>$cd_list_icon}),
		 a({-href=>escape($d).'/'},$d)),
	      td(a({-href=>escape($d).'/playlist.m3u?Play+All=1'},'[play all]'));
      }
      print end_TR,"\n";
    }
    print end_table;
  }

  if (%$mp3s) {
    print hr if %$directories;

    $uri =~ s!([^a-zA-Z0-9/])!uc sprintf("%%%02x",ord($1))!eg;
    print start_form(-action=>"${uri}playlist.m3u");

    print
      a({-name=>'cds'}),
      start_table({-border=>0,-cellspacing=>0,-width=>'100%'}),"\n";
    print  TR(
	      td(),
	      td({-align=>'LEFT',-colspan=>4},
		 submit('Play Selected'),submit('Play All'))) if $stream_ok;
    print TR({-class=>'title'},
	     th(),th({-align=>'LEFT'},[
				   $stream_ok ? 'Select/Stream' : '',
				   $download_ok ? 'Title (download)' : 'Title',
				   'Artist','Duration','Bitrate'])),"\n";

    my $count = 0;
    for my $song (sort keys %$mp3s) {
      my $url = escape($song);
      (my $play = $url) =~ s/(\.[^.]+)?$/.m3u/;
      my $highlight = $count++ % 2 ? 'highlight' : 'normal';
      print TR(
	       td({-class=>$highlight},
		  [img({-src=>$song_icon}),
		   $stream_ok ? checkbox(-name=>'file',-value=>$song,-label=>' ') .
		                a({-href=>"$play?play=1"},b('[play]'))
                              : '' ,
		   $download_ok ? a({-href=>$url},$mp3s->{$song}{title} || $song)
		                : $mp3s->{$song}{title} || $song ,
		   map { $_ || '&nbsp;' } @{$mp3s->{$song}}{qw(artist duration bps)}
		  ])),"\n";
      
    }
    print  TR(td(),
	      td({-align=>'LEFT',-colspan=>4},
		 submit('Play Selected'),submit('Play All'))) if $stream_ok;
    print end_table,"\n";
    print end_form;
  }
  print end_html;
  return OK;
}

sub read_directory {
  my ($r,$dir,$no_info) = @_;
  my (%directories,%mp3s);
  opendir D,$dir or return;
  while (defined(my $d = readdir(D))) {
    next if $d eq '.';
    next if $d eq '..';
    my $mime = $r->lookup_file("$dir/$d")->content_type;
    $directories{$d}++ if $mime eq DIR_MAGIC_TYPE;
    next unless $mime eq 'audio/mpeg';
    $mp3s{$d} = $no_info ? 1 : fetch_info("$dir/$d"); 
  }
  closedir D;
  return \(%directories,%mp3s);
}


# return title, artist, duration, and bps
sub fetch_info {
  my $file = shift;
  return unless my $info = get_mp3info($file);
  my $tag  = get_mp3tag($file);
  my ($title,$artist,$album,$year,$comment,$genre,$duration,$bps);
  if ($tag) {
    ($title,$artist,$album,$year,$comment,$genre) = @{$tag}{qw(TITLE ARTIST ALBUM YEAR COMMENT GENRE)};
  }
  $duration = "$info->{MM}m $info->{SS}s";
  $bps      = "$info->{BITRATE} bps";
  return { title    => $title,
	   artist   => $artist,
	   duration => $duration,
	   bps      => $bps,
	   genre    => $genre,
	   album    => $album,
	   comment  => $comment,
	 };
}

sub send_stream {
    my ($r,$file,$url) = @_;
    my $info = fetch_info($file);
    return DECLINED unless $info;  # not a legit mp3 file?
    open (FILE,$file) || return DECLINED;

    my ($base) = $file =~ m!([^/]+)$!;
    $base =~ s/\.\w+$//;
    my $title = $info->{title} || $base;
    foreach ( qw(artist album year comment) ) {
	$title .= ', ' . $info->{$_} if defined $info->{$_};
    }
    my $genre = $info->{genre} || 'unknown';
	
    $r->print("ICY 200 OK\r\n");
    $r->print("icy-notice1:<BR>This stream requires a shoutcast/icecast compatible player.<BR>\r\n");
    $r->print("icy-notice2:Apache::MP3 module<BR>\r\n");
    $r->print("icy-name:$title\r\n");
    $r->print("icy-genre:$genre\r\n");
    $r->print("icy-url:",'http://',$r->hostname,':',$r->server->port,"\r\n");
    $r->print("icy-pub:1\r\n");
    $r->print("icy-br:$info->{BITRATE}\r\n");
    $r->print("\r\n");
    return OK if $r->header_only;

    my $buffer;
    $r->print($buffer) while read(FILE,$buffer,2048);
    return OK;
}

1;
__END__

=head1 NAME

Apache::MP3 - Generate browsable directories of MP3 files

=head1 SYNOPSIS

 # httpd.conf or srm.conf
 AddType audio/mpeg    mp3 MP3

 # httpd.conf or access.conf
 <Location /songs>
   SetHandler perl-script
   PerlHandler Apache::MP3
   PerlSetVar  AllowDownload     yes
   PerlSetVar  AllowStream       yes
   PerlSetVar  CheckStreamClient yes
 </Location>

=head1 DESCRIPTION

This module takes an MP3 file directory hierarchy and makes it
browsable.  

MP3 files are displayed in a list that shows the MP3 title, artist,
duration and bitrate.  Subdirectories are displayed with "CD" icons.
The user can download an MP3 file to disk by clicking on its title,
stream it to an MP3 decoder by clicking on the "play" link, or select
a subset of songs to stream by selecting checkboxes and pressing a
"Play Selected" button.  Users can also stream the entire contents
of a directory.

NOTE: This version of Apache::MP3 is substantially different from the
pre-2.0 version described in The Perl Journal.  Specifically, the
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
root, and copy into it the contents of the "icons" directory from the
Apache-MP3 distribution.

The I<Customizing> section describes how to choose a different
location for the icons.

=item 4. Set Apache::MP3 as handler for MP3 directory

In httpd.conf or access.conf, create a E<lt>LocationE<gt> or
E<lt>DirectoryE<gt> section, and make Apache::MP3 the handler for this
directory.  This example assumes you are using the URL /songs as the
directory where you will be storing song files:

  <Location /songs>
    SetHandler perl-script
    PerlHandler Apache::MP3
  </Location>

=item 5. Load MP3::Info in the Perl Startup file (optional)

To avoid a mysterious segfault problem, you may need to load the
MP3::Info module at server startup time.  See B<BUGS> below for
details.

=item 6. Set up MP3 directory

Create a directory in the web server document tree that will
contain the MP3 files to be served.  The module recognizes and handles
subdirectories appropriately.  I suggest organizing directories by
artist and or CD title.  For directories containing multiple tracks
from the same CD, proceed each mp3 file with the track number.  This
will ensure that the directory listing sorts in the right order.

=back

Open up the MP3 URL in your favorite browser.  If things don't seem to
be working, checking the server error log for informative messages.

=head2 Customizing

Apache::MP3 can be customized in two ways: (1) by changing
per-directory variables, and (2) changing settings in the Apache::MP3
cascading stylesheet.

Per-directory variables are set by PerlSetVar directives in the
Apache::MP3 E<lt>LocationE<gt> or E<lt>DirectoryE<gt> section.  For
example, to change the icon displayed next to subdirectories of MP3s,
you would use PerlSetVar to change the DirectoryIcon variable:

  PerlSetVar DirectoryIcon big_cd.gif

=over 4

=item PerlSetVar IconDir I<URL>

The B<IconDir> variable sets the URL in which Apache::MP3 will look
for its icons and stylesheet.  The default is /apache_mp3.  The
directory name must begin with a slash and is a URL, not a physical
directory.

=item PerlSetVar Stylesheet I<stylesheet.css>

Set the URL of the cascading stylesheet to use, "apache_mp3.css" by
default.  If the URL begins with a slash it is treated as an absolute
URL.  Otherwise it is interpreted as relative to the IconDir
directory.

=item PerlSetVar ParentIcon I<icon.gif>

Set the URL of the icon to use for moving to the parent directory,
"back.gif" by default.  Here and in the other icon-related directives,
URLs that do not begin with a slash are treated as relative to
IconDir.

=item PerlSetVar TitleIcon I<icon.gif>

Set the icon displayed next to the current directory's name,
"cd_icon.gif" by default.

=item PerlSetVar DirectoryIcon I<icon.gif>

Set the icon displayed next to subdirectories in directory listings,
"cd_icon_small.gif" by default.

=item PerlSetVar SongIcon I<icon.gif>

Set the icon displayed next to MP3 files, "sound.gif" by default.

=item PerlSetVar AllowDownload I<yes|no>

You may wish for users to be able to stream songs but not download
them to their local disk.  If you set AllowDownload to "no",
Apache::MP3 will not generate a download link for MP3 files.  It will
also activate some code that makes it very inconvenient (although not
impossible) for users to download the MP3s.

The arguments "yes", "no", "true" and "false" are recognized.  The
default is "yes".

=item PerlSetVar AllowStream I<yes|no>

If you set AllowStream to "no", users will not be able to stream songs
or generate playlists.  I am not sure why one would want this feature,
but it is included for completeness.  The default is "yes."

=item PerlSetVar CheckStreamClient I<yes|no>

Setting CheckStreamClient to "yes" enables code that checks whether
the client claims to be able to accept streaming MPEG data.  This
check isn't foolproof, but supports at least the most popular MP3
decoders (WinAmp, RealPlayer, xmms, mpg123).  It also makes it harder
for users to download songs by pretending to be a streaming player.

The default is "no".

=back

You may change the appearance of Apache::MP3-generated pages by
editing its cascading stylesheet.  In addition to the normal tags,
three style classes are defined:

=over 4

=item TR.title

This class applies to the top line of the table that lists the MP3
files.  It is used to give the line a distinctive mustard-colored
background.

=item TD.normal

This class applies to even-numbered lines in the MP3 file table.  It
is used to give these lines a white background.

=item TD.highlight

This class applies to odd-numbered lines in the MP3 file table.  It is 
used to give these lines a light blue background.

=back

=head2 Linking

You may wish to create links to MP3 files and directories manually.
The rules for creating HREFs are different from those used in earlier
versions of Apache::MP3, a decision forced by the fact that the
playlist format used by popular MP3 decoders has changed.

The following rules apply:

=over 4

=item Download an MP3 file

Create an HREF using the unchanged name of the MP3 file.  For example, 
to download the song at /songs/Madonna/like_a_virgin.mp3, use:

 <a href="/songs/Madonna/like_a_virgin.mp3">Like a Virgin</a>

=item Stream an MP3 file

Replace the MP3 file's extension with .m3u and add the query string
"play=1".  Apache::MP3 will generate a playlist for the streaming MP3
decoder to load.  Example:

 <a href="/songs/Madonna/like_a_virgin.m3u?play=1">
         Like a streaming Virgin</a>

=item Play a whole directory

Append "/playlist.m3u?Play+All=1" to the end of the directory name:

 <a href="/songs/Madonna/playlist.m3u?Play+All=1">Madonna Lives!</a>

The capitalization of "Play All" is significant.  Apache::Mp3 will
generate a playlist containing all MP3 files within the directory.

=item Play a set of MP3s within a directory

Append "/playlist.m3u?Play+Selected=1;file=file1;file=file2..." to the 
directory name:

 <a
 href="/songs/Madonna/playlist.m3u?Play+Selected=1;file=like_a_virgin.mp3;file=evita.mp3">
 Two favorites</a>

Again, the capitalization of "Play Selected" counts.

=back

=head1 BUGS

I sometimes see random segfaults in the httpd children when using this
module.  The problem appears to be related to the MP3::Info module.
Loading MP3::Info at server startup time using the mod_perl
perl.startup script seems to make the problem go away.  This is an
excerpt from my perl.startup file:
 
 #!/usr/local/bin/perl
 ...
 use Apache::Registry ();
 use Apache::Constants();
 use MP3::Info();
 use CGI();
 use CGI::Carp ();


=head1 SEE ALSO

L<MP3::Info>, L<Apache>

=head1 AUTHOR

Copyright 2000, Lincoln Stein <lstein@cshl.org>.

This module is distributed under the same terms as Perl itself.  Feel
free to use, modify and redistribute it as long as you retain the
correct attribution.

=cut
