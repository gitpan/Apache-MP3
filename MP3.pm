package Apache::MP3;
# file: Apache/MP3.pm
 
use strict;
use Apache::Constants qw(:common REDIRECT);
use MP3::Info;
use IO::Dir;
use Apache::File;
use vars '$VERSION';
$VERSION = '1.00';

# Intercept requests for audio/mpegurl (.pls) files and convert them
# into an appropriately-formatted playlist.
# Intercept requests for audio/x-shoutcast-stream (.mps) and convert them
# into appropriate shoutcast/icecast output

# to install:
#
# AddType audio/mpeg .mp3
# AddType audio/mpegurl .pls
# AddType audio/x-shoutcast-stream .mps
#
# <Files ~ "\.(pls|mps)$">
#   SetHandler perl-script
#   PerlHandler Apache::MP3
# </Files>

# entry point for mod_perl
sub handler {
  my $r = shift;
  my $filename = $r->filename;
  
  # Reconstruct the requested URL.  We need it at various places.
  my $server_url = join '', 'http://',
                            $r->server->server_hostname,
                            ":",
			    $r->get_server_port;

  my $filename = $r->filename;
  my ($basename)   = $filename  =~ m!([^/]+)\.[^/.]*$!;  # get the base name
  (my $directory   = $filename) =~ s!/[^/]+$!!;        # get the directory part
  (my $virtual_dir = $r->uri)   =~ s!/[^/]+$!!;        # get the directory part
    
  if ($r->content_type eq 'audio/mpegurl') {
    # If this is a request for a file of type audio/mpegurl, then
    # strip off the extension and look for a directory
    # containing the name.  Generate a playlist from all mp3 files
    # in the directory.
    return dir2playlist($r,
			"$directory/$basename",
			'',
			"$server_url/$virtual_dir/$basename/") 
      if -d "$directory/$basename";
      
    # If none found, then search for a file of type audio/mpeg that shares the 
    # basename, and generate a playlist from that.
    return dir2playlist($r,$directory,$basename,"$server_url$virtual_dir/");
  } 

  # Otherwise is this a request for stream data?
  elsif ($r->content_type eq 'audio/x-shoutcast-stream') {
    my ($mp3_file) = search4mp3($r,$directory,$basename);
    return DECLINED unless $mp3_file;
    return send_stream($r,"$directory/$mp3_file",$server_url);
  }
  
}

# search for an mp3 file that matches a basename
sub search4mp3 {
  my ($r,$dir,$basename) = @_;
  my $pattern = quotemeta $basename;
  my @mp3;
  my $dh = IO::Dir->new($dir) || return;
  while ( defined($_ = $dh->read) ) {
    next if $pattern && !/^$pattern(\.\w+)?$/;
    next if $r->lookup_file("$dir/$_")->content_type ne 'audio/mpeg';
    push (@mp3,$_);
  }
  return @mp3;
}
    
# send the playlist...
sub dir2playlist {
    my ($r,$dir,$basename,$url) = @_;

    my @mp3 = search4mp3($r,$dir,$basename);
    return DECLINED unless @mp3;

    $r->content_type('audio/mpegurl');
    $r->send_http_header;
    return OK if $r->header_only;

    $r->print ("[playlist]\r\n\r\n");
    $r->print ("NumberOfEntries=",scalar(@mp3),"\r\n");

    for (my $i=1;$i<=@mp3;$i++) {
      (my $file = $mp3[$i-1]) =~ s/(\.[^.]+)?$/.mps/;
      $file =~ s/([^a-zA-Z0-9.])/uc sprintf("%%%02x",ord($1))/eg;
      $r->print ("File$i=$url$file\r\n");
    }
    return OK;
}

# send the music stream...
sub send_stream {
    my ($r,$file,$url) = @_;
    my $tag  = get_mp3tag($file);
    my $info = get_mp3info($file);
    return DECLINED unless $info;  # not a legit mp3 file?

    my $fh = Apache::File->new($file) || return DECLINED;

    my $title = $tag->{TITLE} || $url . $r->uri;
    foreach ( qw(ARTIST ALBUM YEAR COMMENT) ) {
	$title .= ' - ' . $tag->{$_} if $tag->{$_};
    }
    my $genre = $tag->{GENRE} || 'unknown';
	
    $r->print("ICY 200 OK\r\n");
    $r->print("icy-notice1:<BR>This stream requires a shoutcast/icecast compatible player.<BR>\r\n");
    $r->print("icy-notice2:Apache::MP3 module<BR>\r\n");
    $r->print("icy-name:$title\r\n");
    $r->print("icy-genre:$genre\r\n");
    $r->print("icy-url:$url\r\n");
    $r->print("icy-pub:1\r\n");
    $r->print("icy-br:$info->{BITRATE}\r\n");
    $r->print("\r\n");
    return OK if $r->header_only;

    $r->send_fd($fh);
    return OK;
}

1;
__END__

=head1 NAME

Apache::MP3 - Play streaming audio from Apache

=head1 SYNOPSIS

  AddType audio/mpeg .mp3
  AddType audio/mpegurl .pls
  AddType audio/x-shoutcast-stream .mps

  <Files ~ "\.(pls|mps)$">
    SetHandler perl-script
    PerlHandler Apache::MP3
  </Files>

=head1 DESCRIPTION

Apache::MP3 is designed to respond to requests for a playlist
document, ending in the extension .pls, or a streaming MP3 document,
ending in the extension .mps (the first of these extensions is
standard; the second one I made up for this application).  Neither of
these documents exist as static files, but are generated as needed
dynamically from a directory structure containing MP3 files.

The rules for the playlist construction are a bit tricky.  Consider a
Web root that contains a top-level directory named "samples", and that
it contains four files arranged in the following manner:

 /samples/the_wheel/Imbolc.mp3
 /samples/the_wheel/Samhain.mp3
 /samples/the_wheel/Merry_Men.mp3
 /samples/the_wheel/The_Process.mp3

A request for the URL /samples/the_wheel/Merry_Men.pls will cause
Apache::MP3 to look into the /samples/the_wheel directory.  Notice
that there is a MP3 file that uses the same basename as the requested
playlist, and autogenerate a playlist containing the single URL
http://your.site/samples/the_wheel/Merry_men.mps.  Notice that the URL
Apache::MP3 generates is a request for a .mps URL rather than for the
MP3 file itself.  The .mps URL will be used in a second request to
generate an MP3 stream.

Apache::MP3 can also generate a playlist for an entire directory's
worth of MP3 files.  Just take the directory name and add a .pls
extension.  For example, if the browser requests the URL
"/samples/the_wheel.pls", then Apache::MP3 will construct a playlist
containing the four URLs /samples/the_wheel/Imbolc.mps through
/samples/the_wheel/The_Process.mps.

When Apache::MP3 receives a request for a URL ending in the extension
".mps", it looks for the corresponding MP3 file, extracts its ID3 tags
with MPEG::MP3Info, constructs a Shoutcast/Icecast header, and streams
the file to the client.

To summarize, your links should look like this:

=over 4

=item Download an mp3 file, no streaming:

  http://your.site/samples/the_wheel/Merry_Men.mp3

=item Stream an mp3 file:

  http://your.site/samples/the_wheel/Merry_Men.mps

=item Stream an entire directory of mp3's as a playlist:

  http://your.site/samples/the_wheel.pls

=back

NOTE: This module requires the MP3::Info module.

=head1 MORE INFORMATION

See my article in the The Perl Journal volume 16 (www.tpj.com).

=head1 AUTHOR

Lincoln Stein <lstein@cshl.org>.

=head1 COPYRIGHT

Copyright (c) 2000 Cold Spring Harbor Laboratory. All rights reserved.
This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 SEE ALSO

L<MP3::Info>

=cut

