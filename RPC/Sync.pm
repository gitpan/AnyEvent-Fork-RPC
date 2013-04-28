package AnyEvent::Fork::RPC::Sync;

use common::sense; # actually required to avoid spurious warnings...

# declare only
sub AnyEvent::Fork::RPC::event;

# the goal here is to keep this simple, small and efficient
sub run {
   my ($function, $init, $serialiser) = splice @_, -3, 3;
   my $rfh = shift;
   my $wfh = fileno $rfh ? $rfh : *STDOUT;

   {
      package main;
      &$init if length $init;
      $function = \&$function; # resolve function early for extra speed
   }

   my ($f, $t) = eval $serialiser; die $@ if $@;

   my $write = sub {
      my $got = syswrite $wfh, $_[0];

      while ($got < length $_[0]) {
         my $len = syswrite $wfh, $_[0], 1<<30, $got;

         defined $len
            or die "AnyEvent::Fork::RPC::Sync: write error ($!), parent gone?";

         $got += $len;
      }
   };

   *AnyEvent::Fork::RPC::event = sub {
      $write->(pack "NN/a*", 0, &$f);
   };

   my ($rlen, $rbuf) = 512 - 16;

   while (sysread $rfh, $rbuf, $rlen - length $rbuf, length $rbuf) {
      $rlen = $rlen * 2 + 16 if $rlen - 128 < length $rbuf;

      while () {
         last if 4 > length $rbuf;
         my $len = unpack "N", $rbuf;
         last if 4 + $len > length $rbuf;

         $write->(pack "NN/a*", 1, $f->($function->($t->(substr $rbuf, 4, $len))));

         substr $rbuf, 0, 4 + $len, "";
      }
   }

   shutdown $wfh, 1;
   exit; # work around broken win32 perls
}

1

