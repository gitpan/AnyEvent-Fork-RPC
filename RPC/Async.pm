package AnyEvent::Fork::RPC::Async;

use common::sense; # actually required to avoid spurious warnings...

use Errno ();

use AnyEvent;

# declare only
sub AnyEvent::Fork::RPC::event;

sub run {
   my ($function, $init, $serialiser) = splice @_, -3, 3,;
   my $master = shift;

   {
      package main;
      &$init if length $init;
      $function = \&$function; # resolve function early for extra speed
   }

   my $busy = 1; # exit when == 0

   my ($f, $t) = eval $serialiser; die $@ if $@;
   my ($wbuf, $ww);

   my $wcb = sub {
      my $len = syswrite $master, $wbuf;

      unless (defined $len) {
         if ($! != Errno::EAGAIN && $! != Errno::EWOULDBLOCK) {
            undef $ww;
            die "AnyEvent::Fork::RPC: write error ($!), parent gone?\n";
         }
      }

      substr $wbuf, 0, $len, "";

      unless (length $wbuf) {
         undef $ww;
         exit unless $busy;
      }
   };

   my $write = sub {
      $wbuf .= $_[0];
      $ww ||= AE::io $master, 1, $wcb;
   };

   *AnyEvent::Fork::RPC::event = sub {
      $write->(pack "LL/a*", 0, &$f);
   };

   my ($rlen, $rbuf, $rw) = 512 - 16;

   my $len;

   $rw = AE::io $master, 0, sub {
      $rlen = $rlen * 2 + 16 if $rlen - 128 < length $rbuf;
      $len = sysread $master, $rbuf, $rlen - length $rbuf, length $rbuf;

      if ($len) {
         while (8 <= length $rbuf) {
            (my $id, $len) = unpack "LL", $rbuf;
            8 + $len <= length $rbuf
               or last;

            my @r = $t->(substr $rbuf, 8, $len);
            substr $rbuf, 0, 8 + $len, "";
            
            ++$busy;
            $function->(sub {
               --$busy;
               $write->(pack "LL/a*", $id, &$f);
            }, @r);
         }
      } elsif (defined $len) {
         undef $rw;
         --$busy;
         $ww ||= AE::io $master, 1, $wcb;
      } elsif ($! != Errno::EAGAIN && $! != Errno::EWOULDBLOCK) {
         undef $rw;
         die "AnyEvent::Fork::RPC: read error in child: $!\n";
      }
   };

   $AnyEvent::MODEL eq "EV"
      ? EV::loop ()
      : AE::cv->recv;
}

1

