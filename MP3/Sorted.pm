package Apache::MP3::Sorted;

# example of how to subclass Apache::MP3 in order to provide
# control over the sorting of the rows of the MP3 table

use strict;
use Apache::MP3;
use CGI 'param';
use vars '@ISA';
@ISA = 'Apache::MP3';

# to choose the right type of sort for each of the mp3 fields
my %sort_modes = (
		  # config        field       sort type
		  title       => [qw(title        alpha)],
		  artist      => [qw(artist       alpha)],
		  duration    => [qw(seconds      numeric)],
		  seconds     => [qw(seconds      numeric)],
		  genre       => [qw(genre        alpha)],
		  album       => [qw(album        alpha)],
		  comment     => [qw(comment      alpha)],
		  description => [qw(description  alpha)],
		  bitrate     => [qw(bitrate      numeric)],
		  filename    => [qw(filename     alpha)],
		  kbps        => [qw(kbps         numeric)],
		  track       => [qw(track        numeric)],
		 );

sub handler {
  __PACKAGE__->handle_request(@_);
}

sub sort_field {
  my $self = shift;
  return lc param('sort') if param('sort');
  return lc $self->r->dir_config('SortField');
}

# sort MP3s
sub sort_mp3s {
  my $self = shift;
  my $files = shift;
  my $field       = $self->sort_field;

  # look up how we should do the sorting
  (my $base_field = $field) =~ s/^[+-]//;
  my $sort_field   = $sort_modes{$base_field}[0];
  my $sort_type    = $sort_modes{$base_field}[1];

  # no known sort type chosen
  unless ($sort_field) {
    $self->r->warn("unsupported sort field $field passed to sort_mp3s()") if $field;
    return $self->SUPER::sort_mp3s($files);  
  }

  # do the sort
  my @sorted;
  @sorted = sort { $files->{$a}{$sort_field} cmp
		     $files->{$b}{$sort_field} } keys %$files if $sort_type eq 'alpha';

  @sorted = sort { $files->{$a}{$sort_field} <=>
		     $files->{$b}{$sort_field} } keys %$files if $sort_type eq 'numeric';

  # reverse order if sort field begins with - (hyphen)
  return  $field =~ /^-/ ? reverse @sorted : @sorted;
}

sub mp3_table_header {
  my $self = shift;
  my $url = url(-absolute=>1,-path_info=>1);
  my @fields;

  foreach ($self->fields) {
    my $sort = param('sort') eq lc($_)  ? lc("-$_") : lc($_);
    push @fields,a({-href=>"$url?sort=$sort"},ucfirst($_));
  }

  print TR({-class=>'title',-align=>'LEFT'},
	   th({-colspan=>2,-align=>'CENTER'},p($self->stream_ok ? 'Select' : '')),
	   th(\@fields)),"\n";
}

# Add hidden field for sorting
sub mp3_list_bottom {
  my $self = shift;
  print hidden('sort');
  $self->SUPER::mp3_list_bottom(@_);
}


1;

=head1 NAME

Apache::MP3::Sorted - Generate sorted streamable directories of MP3 files

=head1 SYNOPSIS

 # httpd.conf or srm.conf
 AddType audio/mpeg    mp3 MP3

 # httpd.conf or access.conf
 <Location /songs>
   SetHandler perl-script
   PerlHandler Apache::MP3::Sorted
   PerlSetVar  SortField     Title
   PerlSetVar  Fields        Title,Artist,Album,Duration
 </Location>

=head1 DESCRIPTION

Apache::MP3::Sorted subclasses Apache::MP3 to allow for sorting of MP3
listings by various criteria.  See L<Apache::MP3> for details on
installing and using.

=head1 CUSTOMIZING

This class adds one new Apache configuration variable, B<SortField>.
This is the name of the field to sort by default when the MP3 file
listing is first displayed, after which the user can change the sort
field by clicking on the column headers.

The value of B<SortField> may be the name of any of the fields in the
listing, such as I<Title>, I<Description>, I<Album> or I<Duration>.
Example: 

  PerlSetVar SortField Title

Sorry, but sorting on multiple fields is not supported at this time.

=head1 METHODS

Apache::MP3::Sorted overrides the following methods:

 sort_mp3s()  mp3_table_header()   mp3_list_bottom()

It adds one new method:

=over 4

=item $field = $mp3->sort_field

Returns the name of the field to sort on by default.

=back

=head1 BUGS

Let me know.

=head1 SEE ALSO

L<Apache::MP3>, L<MP3::Info>, L<Apache>

=head1 AUTHOR

Copyright 2000, Lincoln Stein <lstein@cshl.org>.

This module is distributed under the same terms as Perl itself.  Feel
free to use, modify and redistribute it as long as you retain the
correct attribution.

=cut

 
 





