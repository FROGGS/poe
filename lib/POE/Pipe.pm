# Common routines for POE::Pipe::OneWay and ::TwoWay.  This is meant
# to be inherited.  This is ugly, messy code right now.  It fails
# terribly upon the slightest error, which is generally bad.

package POE::Pipe;

use strict;

use vars qw($VERSION);
$VERSION = '1.354'; # NOTE - Should be #.### (three decimal places)

use Symbol qw(gensym);
use IO::Socket qw(
  PF_INET SOCK_STREAM SOL_SOCKET SO_REUSEADDR 
  pack_sockaddr_in unpack_sockaddr_in inet_aton
  SOMAXCONN SO_ERROR
);
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use Errno qw(EINPROGRESS EWOULDBLOCK);

# CygWin seems to have a problem with socketpair() and exec().  When
# an exec'd process closes, any data on sockets created with
# socketpair() is not flushed.  From irc.rhizomatic.net #poe:
#
# <dngnand>   Sounds like a lapse in cygwin's exec implementation.  It
#             works ok under Unix-ish systems?
# <jdeluise2> yes, it works perfectly
# <jdeluise2> but, if we just use POE::Pipe::TwoWay->new("pipe") it
#             always works fine on cygwin
# <jdeluise2> by the way, it looks like the reason is that
#             POE::Pipe::OneWay works because it tries to make a pipe
#             first instead of a socketpair
# <jdeluise2> this socketpair problem seems like a long-standing one
#             with cygwin, according to searches on google, but never
#             been fixed.

# The order of pipe primitives depends on our platform.  Placed in the
# base class and given accessors so we can use it from both OneWay and
# TwoWay.

my @preference;
if ($^O eq "MSWin32" or $^O eq "MacOS") {
  @preference = qw(inet socketpair pipe);
}
elsif ($^O eq "cygwin") {
  @preference = qw(pipe inet socketpair);
}
else {
  @preference = qw(socketpair pipe inet);
}

sub _get_next_preference {
  return $preference[0];
}

sub _shift_preference {
  shift @preference;
}

# Provide dummy constants so things at least compile.  These constants
# aren't used if we're RUNNING_IN_HELL, but Perl needs to see them.

BEGIN {
  # older perls than 5.10 needs a kick in the arse to AUTOLOAD the constant...
  eval "F_GETFL" if $] < 5.010;

  if ( ! defined &Fcntl::F_GETFL ) {
    if ( ! defined prototype "F_GETFL" ) {
      *F_GETFL = sub { 0 };
      *F_SETFL = sub { 0 };
    } else {
      *F_GETFL = sub () { 0 };
      *F_SETFL = sub () { 0 };
    }
  }
}

# Make a socket.  This is a homebrew socketpair() for systems that
# don't support it.  The things I must do to make Windows happy.

sub _make_socket {

  ### Server side.

  my $acceptor = gensym();
  my $accepted = gensym();

  my $tcp = getprotobyname('tcp') or die "getprotobyname: $!";
  socket( $acceptor, PF_INET, SOCK_STREAM, $tcp ) or die "socket: $!";

  setsockopt( $acceptor, SOL_SOCKET, SO_REUSEADDR, 1) or die "reuse: $!";

  my $server_addr = inet_aton('127.0.0.1') or die "inet_aton: $!";
  $server_addr = pack_sockaddr_in(0, $server_addr)
    or die "sockaddr_in: $!";

  bind( $acceptor, $server_addr ) or die "bind: $!";

  $acceptor->blocking(0);

  $server_addr = getsockname($acceptor);

  listen( $acceptor, SOMAXCONN ) or die "listen: $!";

  ### Client side.

  my $connector = gensym();

  socket( $connector, PF_INET, SOCK_STREAM, $tcp ) or die "socket: $!";

  $connector->blocking(0);

  unless (connect( $connector, $server_addr )) {
    die "connect: $!" if $! and ($! != EINPROGRESS) and ($! != EWOULDBLOCK);
  }

  my $connector_address = getsockname($connector);
  my ($connector_port, $connector_addr) =
    unpack_sockaddr_in($connector_address);

  ### Loop around 'til it's all done.  I thought I was done writing
  ### select loops.  Damnit.

  my $in_read  = '';
  my $in_write = '';

  vec( $in_read,  fileno($acceptor),  1 ) = 1;
  vec( $in_write, fileno($connector), 1 ) = 1;

  my $done = 0;
  while ($done != 0x11) {
    my $hits = select( my $out_read   = $in_read,
                       my $out_write  = $in_write,
                       undef,
                       5
                     );
    unless ($hits) {
      next if ($! and ($! == EINPROGRESS) or ($! == EWOULDBLOCK));
      die "select: $!" unless $hits;
    }

    # Accept happened.
    if (vec($out_read, fileno($acceptor), 1)) {
      my $peer = accept($accepted, $acceptor);
      my ($peer_port, $peer_addr) = unpack_sockaddr_in($peer);

      if ( $peer_port == $connector_port and
           $peer_addr eq $connector_addr
         ) {
        vec($in_read, fileno($acceptor), 1) = 0;
        $done |= 0x10;
      }
    }

    # Connect happened.
    if (vec($out_write, fileno($connector), 1)) {
      $! = unpack('i', getsockopt($connector, SOL_SOCKET, SO_ERROR));
      die "connect: $!" if $!;

      vec($in_write, fileno($connector), 1) = 0;
      $done |= 0x01;
    }
  }

  # Turn blocking back on, damnit.
  $accepted->blocking(1);
  $connector->blocking(1);

  return ($accepted, $connector);
}

1;

__END__

=head1 NAME

POE::Pipe - common methods for POE::Pipe::OneWay and POE::Pipe::TwoWay

=head1 SYNOPSIS

  None.

=head1 DESCRIPTION

POE::Pipe implements lower-level internal methods that are common
among its subclasses: POE::Pipe::OneWay and POE::Pipe::TwoWay.

The POE::Pipe classes may be used outside of POE, as they don't use
POE internally.

=head1 BUGS

The functions implemented here die outright upon failure, requiring
eval{} around their calls.

=head1 SEE ALSO

L<POE::Pipe::OneWay>, L<POE::Pipe::TwoWay>, L<POE>

=head1 AUTHOR & COPYRIGHT

POE::Pipe is copyright 2001-2013 by Rocco Caputo.  All rights
reserved.  POE::Pipe is free software; you may redistribute it and/or
modify it under the same terms as Perl itself.

=cut

# rocco // vim: ts=2 sw=2 expandtab
# TODO - Edit.
