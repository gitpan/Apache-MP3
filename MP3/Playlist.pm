package Apache::MP3::Playlist;
# $Id: Playlist.pm,v 1.2 2001/05/01 02:31:02 lstein Exp $
# generates playlists in cookies

use strict;
use vars qw(@ISA $VERSION);
use Apache::Constants qw(:common REDIRECT HTTP_NO_CONTENT);
use File::Basename 'dirname','basename';
use CGI qw(:standard);
use CGI::Cookie;
use Apache::MP3::Sorted;

@ISA = 'Apache::MP3::Sorted';
$VERSION = 1.03;
# $Id: Playlist.pm,v 1.2 2001/05/01 02:31:02 lstein Exp $

#sub handler {
#  __PACKAGE__->handle_request(@_);
#}

sub run {
  my $self = shift;
  my $result = $self->process_playlist;
  return $result if defined $result;
  $self->SUPER::run();
}

sub process_playlist {
  my $self = shift;
  my $r = $self->r;
  my (@playlist,$changed);

  if (my $cookies = CGI::Cookie->parse($r->header_in('Cookie'))) {
    my $playlist = $cookies->{playlist};
    @playlist = $playlist->value if $playlist;
    if ($playlist[-1] && 
	$r->lookup_uri($playlist[-1])->content_type ne 'audio/mpeg') {
      $self->{possibly_truncated}++;
      pop @playlist;  # get rid of the last
    }
  }

  if (param('Clear All')) {
    @playlist = ();
    $changed++;
  }

  if (param('Clear Selected')) {
    my %clear = map { $_ => 1 } param('file') or return HTTP_NO_CONTENT;
    @playlist = grep !$clear{$_},@playlist;
    $changed++;
  }

  if (param('Add All to Playlist')) {
    my %seen;
    @playlist = grep !$seen{$_}++,(@playlist,@{$self->find_mp3s});
    $changed++;
  }

  if (param('Add to Playlist')) {
    my $dir = dirname($r->uri);
    my @new = param('file') or return HTTP_NO_CONTENT;
    my %seen;
    @playlist = grep !$seen{$_}++,(@playlist,map {"$dir/$_"} @new);
    $changed++;
  }

  if (param('Play Selected') and param('playlist')) {
    my @uris = param('file') or return HTTP_NO_CONTENT;
    return $self->send_playlist(\@uris);
  }

  if (param('Shuffle All') and param('playlist')) {
    return HTTP_NO_CONTENT unless @playlist;
    return $self->send_playlist(\@playlist,'shuffle');
  }

  if (param('Play All') and param('playlist')) {
    return HTTP_NO_CONTENT unless @playlist;
    return $self->send_playlist(\@playlist);
  }

  if ($changed) {
    my $c = CGI::Cookie->new(-name  => 'playlist',
			     -value => \@playlist);
    tied(%{$r->err_headers_out})->add('Set-Cookie' => $c);
    (my $uri = $r->uri) =~ s!playlist\.m3u$!!;
    $self->path_escape(\$uri);
    $r->err_header_out(Location => $uri);
    return REDIRECT;
  }

  $self->playlist(@playlist);
  return;
}

sub directory_bottom {
  my $self = shift;
  if ($self->playlist) {
    my $r = $self->r;
    my $uri = $r->uri;  # for self referencing
    $self->path_escape(\$uri);

    my $descriptions = $self->lookup_descriptions($self->playlist);
    my @ok = grep { $descriptions->{$_} } $self->playlist;

    print
      a({-name=>'playlist'}),
      table({-width=>'100%',-border=>1},
	    Tr({-class=>'playlist'},
	       td(
		  h3('Current Playlist'),
		  start_form(-action=>"${uri}playlist.m3u",-method=>'GET'),
		  checkbox_group(-class=>'playlist',
				 -name      => 'file',
				 -linebreak => 1,
				 -value     => \@ok,
				 -labels    => $descriptions),
		  submit(-name=>'Clear All'),
		  submit(-class=>'playlist',-name=>'Clear Selected'),
		  submit(-class=>'playlist',-name=>'Play Selected'),
		  submit(-class=>'playlist',-name=>'Shuffle All'),
		  submit(-class=>'playlist',-name=>'Play All'),
		  hidden(-name=>'playlist',-value=>1,-override=>1),
		  end_form(),
		  ))
	   );
  }
  $self->SUPER::directory_bottom(@_);
}

sub control_buttons {
  my $self = shift;
  return (
	  $self->{possibly_truncated}
	  ? ()
	  : (submit({-class=>'playlist',
		     -name=>'Add to Playlist'}), 
	     submit({-class=>'playlist',
		     -name=>'Add All to Playlist'})
	    ),
	  submit('Play Selected'),  submit('Shuffle All'),  submit('Play All')); 
}

sub lookup_descriptions {
  my $self = shift;
  my $r = $self->r;
  my %d;
  for my $song (@_) {
    next unless my $sub  = $r->lookup_uri($song);
    next unless my $file = $sub->filename;
    next unless -r $file;
    next unless my $info = $self->fetch_info($file);
    $d{$song} = " $info->{description}";
  }
  return \%d;
}

sub directory_top {
  my $self = shift;
  $self->SUPER::directory_top(@_);
  my @p = $self->playlist;
  print div({-align=>'CENTER'},
	    a({-href=>'#playlist',-class=>'playlist'},'Playlist contains',scalar(@p),'songs.'),br,
	    $self->{possibly_truncated} ? font({-color=>'red'},
					       strong('Your playlist is now full. No more songs can be added.')) : '') 
    if @p;
}

sub playlist {
  my $self = shift;
  my @p = $self->{playlist} ? @{$self->{playlist}} : ();
  $self->{playlist} = [@_] if @_;
  return unless @p;
  return wantarray ? @p : \@p;
}

1;

=head1 NAME

Apache::MP3::Playlist - Manage directories of MP3 files with sorting and persistent playlists

=head1 SYNOPSIS

 # httpd.conf or srm.conf
 AddType audio/mpeg    mp3 MP3

 # httpd.conf or access.conf
 <Location /songs>
   SetHandler perl-script
   PerlHandler Apache::MP3::Playlist
   PerlSetVar  SortField     Title
   PerlSetVar  Fields        Title,Artist,Album,Duration
 </Location>

=head1 DESCRIPTION

Apache::MP3::Playlist subclasses Apache::MP3::Sorted to allow the user
to build playlists across directories.  Playlists are stored in
cookies and are persistent for the life of the browser.  See
L<Apache::MP3> and L<Apache::MP3::Sorted> for details on installing
and using.

=head1 CUSTOMIZATION

The "playlist" class in the F<apache_mp3.css> cascading stylesheet
defines the color of the playlist area and associated buttons.

=head1 METHODS

Apache::MP3::Playlist overrides the following methods:

 run(), directory_bottom(), control_buttons() and directory_top().

It adds several new methods:

=over 4

=item $result = $mp3->process_playlist

Process buttons that affect the playlist.

=item $hashref = $mp3->lookup_descriptions(@uris)

Look up the description fields for the MP3 files indicated by the list
of URIs (not paths) and return a hashref.

=item @list = $mp3->playlist([@list])

Get or set the current stored playlist.  In a list context returns the
list of URIs of stored MP3 files.  In a scalar context returns an
array reference.  Pass a list of URIs to set the playlist.

=head1 Linking to this module

The following new linking conventions apply:

=item Add MP3 files to the user's playlist

Append "/playlist.m3u?Add+to+Playlist;file=file1;file=file2..." to the
name of the directory that contains the files:

 <a
 href="/Songs/Madonna/playlist.m3u?Add+to+Playlist=1;file=like_a_virgin.mp3;file=evita.mp3">
 Two favorites</a>

=item Add all MP3 files in a directory to the user's playlist:

Append "/playlist.m3u?Add+All+to+Playlist" to the name of the
directory that contains the files:

 <a
 href="/Songs/Madonna/playlist.m3u?Add+All+to+Playlist=1">
 Madonna'a a Momma</a>

=item Delete some MP3 files from the user's playlist:

Append
"/playlist.m3u?Clear+Selected=1;playlist=1;file=file1;file=file2..."
to the name of the current directory.  

NOTE: the file names must be absolute URLs, not relative URLs.  This
is because the playlist spans directories.  By the same token, the
current directory does not have to contain the removed song(s).
Example:

 <a
 href="/Songs/Springsteen/playlist.m3u?Clear+Selected=1;
      playlist=1;file=/Songs/Madonna/like_a_virgin.mp3">
 No longer a virgin, alas</a>

=item Clear user's playlist:

Append "/playlist.m3u?Clear+All=1;playlist=1" to the name of the
current directory.

Example:

 <a href="/Songs/Springsteen/playlist.m3u?Clear+All=1;playlist=1">
   A virgin playlist</a>

=item Stream the playlist

Append "/playlist.m3u?Play+All=1;playlist=1" to the name of the
current directory.

Example:

 <a href="/Songs/Madonna/playlist.m3u?Play+All=1;playlist=1">
    Stream me!</a>

=item Stream the playlist in random order

As above, but use "Shuffle+All" rather than "Play+All".

=item Stream part of the playlist

Append
"/playlist.m3u?Play+Selected=1;playlist=1;file=file1;file=file2..."
to the name of the current directory.

NOTE: the files must be full URLs.  It is not strictly necessary for
them to be on the current playlist, so this allows you to stream
playlists of arbitrary sets of MP3 files.

Example:

 <a
 href="/Songs/playlist.m3u?Play+Selected=1;
      playlist=1;file=/Songs/Madonna/like_a_virgin.mp3;
      file=/Songs/Madonna/working_girl.mp3;
      file=/Songs/Beatles/let_it_be.mp3">
 Madonna and John, together again for the first time</a>

=head1 BUGS

This module uses client-side cookies to mantain the playlist.  This
limits the number of songs that can be placed in the playlist to about
50 songs.

=head1 ACKNOWLEDGEMENTS

Chris Nandor came up with the idea for the persistent playlist and
implemented it using server-side DBM files.  I reimplemented it using
client-side cookies, which simplifies maintenance and security, but
limits playlists in size.

=head1 AUTHOR

Copyright 2000, Lincoln Stein <lstein@cshl.org>.

This module is distributed under the same terms as Perl itself.  Feel
free to use, modify and redistribute it as long as you retain the
correct attribution.

=head1 SEE ALSO

L<Apache::MP3::Sorted>, L<Apache::MP3>, L<MP3::Info>, L<Apache>

=cut
