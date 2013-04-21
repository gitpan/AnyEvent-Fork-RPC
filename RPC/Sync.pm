package AnyEvent::Fork::RPC::Sync;

use common::sense; # actually required to avoid spurious warnings...

# declare only
sub AnyEvent::Fork::RPC::event;

# the goal here is to keep this simple, small and efficient
sub run {
   my ($function, $init, $serialiser) = splice @_, -3, 3,;
   my $master = shift;

   {
      package main;
      &$init if length $init;
      $function = \&$function; # resolve function early for extra speed
   }

   my ($f, $t) = eval $serialiser; die $@ if $@;

   my $write = sub {
      my $got = syswrite $master, $_[0];

      while ($got < length $_[0]) {
         my $len = syswrite $master, $_[0], 1<<30, $got;

         defined $len
            or die "AnyEvent::Fork::RPC::Sync: write error ($!), parent gone?";

         $got += $len;
      }
   };

   *AnyEvent::Fork::RPC::event = sub {
      $write->(pack "LL/a*", 0, &$f);
   };

   my ($rlen, $rbuf) = 512 - 16;

   while (sysread $master, $rbuf, $rlen - length $rbuf, length $rbuf) {
      $rlen = $rlen * 2 + 16 if $rlen - 128 < length $rbuf;

      while () {
         last if 4 > length $rbuf;
         my $len = unpack "L", $rbuf;
         last if 4 + $len > length $rbuf;

         $write->(pack "LL/a*", 1, $f->($function->($t->(substr $rbuf, 4, $len))));

         substr $rbuf, 0, 4 + $len, "";
      }
   }

   shutdown $master, 1;
   exit; # work around broken win32 perls
}

1

