$| = 1;
print "1..13\n";

use AnyEvent;
use AnyEvent::Fork::RPC;

print "ok 1\n";

my $done = AE::cv;

my $rpc = AnyEvent::Fork
   ->new
   ->eval (do { local $/; <DATA> })
   ->AnyEvent::Fork::RPC::run ("run",
      on_error   => sub { print "Bail out! $_[0]\n"; exit 1 },
      on_event   => sub { print "$_[0]\n" },
      on_destroy => $done,
   );

print "ok 2\n";

for (3..6) {
   $rpc->($_ * 2 - 1, sub { print $_[0] });
}

print "ok 3\n";

undef $rpc;

print "ok 4\n";

$done->recv;

print "ok 13\n";

__DATA__

sub run {
   my ($count) = @_;

   AnyEvent::Fork::RPC::event ("ok $count");

   "ok " . ($count + 1) . "\n"
}

