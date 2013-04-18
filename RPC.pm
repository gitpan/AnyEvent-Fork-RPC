=head1 NAME

AnyEvent::Fork::RPC - simple RPC extension for AnyEvent::Fork

THE API IS NOT FINISHED, CONSIDER THIS A TECHNOLOGY DEMO

=head1 SYNOPSIS

   use AnyEvent::Fork::RPC;
   # use AnyEvent::Fork is not needed

   my $rpc = AnyEvent::Fork
      ->new
      ->require ("MyModule")
      ->AnyEvent::Fork::RPC::run (
         "MyModule::server",
      );

   use AnyEvent;

   my $cv = AE::cv;

   $rpc->(1, 2, 3, sub {
      print "MyModule::server returned @_\n";
      $cv->send;
   });

   $cv->recv;

=head1 DESCRIPTION

This module implements a simple RPC protocol and backend for processes
created via L<AnyEvent::Fork>, allowing you to call a function in the
child process and receive its return values (up to 4GB serialised).

It implements two different backends: a synchronous one that works like a
normal function call, and an asynchronous one that can run multiple jobs
concurrently in the child, using AnyEvent.

It also implements an asynchronous event mechanism from the child to the
parent, that could be used for progress indications or other information.

Loading this module also always loads L<AnyEvent::Fork>, so you can make a
separate C<use AnyEvent::Fork> if you wish, but you don't have to.

=head1 EXAMPLES

=head2 Example 1: Synchronous Backend

Here is a simple example that implements a backend that executes C<unlink>
and C<rmdir> calls, and reports their status back. It also reports the
number of requests it has processed every three requests, which is clearly
silly, but illustrates the use of events.

First the parent process:

   use AnyEvent;
   use AnyEvent::Fork::RPC;

   my $done = AE::cv;

   my $rpc = AnyEvent::Fork
      ->new
      ->require ("MyWorker")
      ->AnyEvent::Fork::RPC::run ("MyWorker::run",
         on_error   => sub { warn "FATAL: $_[0]"; exit 1 },
         on_event   => sub { warn "$_[0] requests handled\n" },
         on_destroy => $done,
      );

   for my $id (1..6) {
      $rpc->(rmdir => "/tmp/somepath/$id", sub {
         $_[0]
            or warn "/tmp/somepath/$id: $_[1]\n";
      });
   }

   undef $rpc;

   $done->recv;

The parent creates the process, queues a few rmdir's. It then forgets
about the C<$rpc> object, so that the child exits after it has handled the
requests, and then it waits till the requests have been handled.

The child is implemented using a separate module, C<MyWorker>, shown here:

   package MyWorker;

   my $count;

   sub run {
      my ($cmd, $path) = @_;

      AnyEvent::Fork::RPC::event ($count)
         unless ++$count % 3;

      my $status = $cmd eq "rmdir"  ? rmdir  $path
                 : $cmd eq "unlink" ? unlink $path
                 : die "fatal error, illegal command '$cmd'";

      $status or (0, "$!")
   }

   1

The C<run> function first sends a "progress" event every three calls, and
then executes C<rmdir> or C<unlink>, depending on the first parameter (or
dies with a fatal error - obviously, you must never let this happen :).

Eventually it returns the status value true if the command was successful,
or the status value 0 and the stringified error message.

On my system, running the first code fragment with the given
F<MyWorker.pm> in the current directory yields:

   /tmp/somepath/1: No such file or directory
   /tmp/somepath/2: No such file or directory
   3  requests handled
   /tmp/somepath/3: No such file or directory
   /tmp/somepath/4: No such file or directory
   /tmp/somepath/5: No such file or directory
   6  requests handled
   /tmp/somepath/6: No such file or directory

Obviously, none of the directories I am trying to delete even exist. Also,
the events and responses are processed in exactly the same order as
they were created in the child, which is true for both synchronous and
asynchronous backends.

Note that the parentheses in the call to C<AnyEvent::Fork::RPC::event> are
not optional. That is because the function isn't defined when the code is
compiled. You can make sure it is visible by pre-loading the correct
backend module in the call to C<require>:

      ->require ("AnyEvent::Fork::RPC::Sync", "MyWorker")

Since the backend module declares the C<event> function, loading it first
ensures that perl will correctly interpret calls to it.

And as a final remark, there is a fine module on CPAN that can
asynchronously C<rmdir> and C<unlink> and a lot more, and more efficiently
than this example, namely L<IO::AIO>.

=head3 Example 1a: the same with the asynchronous backend

This example only shows what needs to be changed to use the async backend
instead. Doing this is not very useful, the purpose of this example is
to show the minimum amount of change that is required to go from the
synchronous to the asynchronous backend.

To use the async backend in the previous example, you need to add the
C<async> parameter to the C<AnyEvent::Fork::RPC::run> call:

      ->AnyEvent::Fork::RPC::run ("MyWorker::run",
         async      => 1,
         ...

And since the function call protocol is now changed, you need to adopt
C<MyWorker::run> to the async API.

First, you need to accept the extra initial C<$done> callback:

   sub run {
      my ($done, $cmd, $path) = @_;

And since a response is now generated when C<$done> is called, as opposed
to when the function returns, we need to call the C<$done> function with
the status:

      $done->($status or (0, "$!"));

A few remarks are in order. First, it's quite pointless to use the async
backend for this example - but it I<is> possible. Second, you can call
C<$done> before or after returning from the function. Third, having both
returned from the function and having called the C<$done> callback, the
child process may exit at any time, so you should call C<$done> only when
you really I<are> done.

=head2 Example 2: Asynchronous Backend

This example implements multiple count-downs in the child, using
L<AnyEvent> timers. While this is a bit silly (one could use timers in te
parent just as well), it illustrates the ability to use AnyEvent in the
child and the fact that responses can arrive in a different order then the
requests.

It also shows how to embed the actual child code into a C<__DATA__>
section, so it doesn't need any external files at all.

And when your parent process is often busy, and you have stricter timing
requirements, then running timers in a child process suddenly doesn't look
so silly anymore.

Without further ado, here is the code:

   use AnyEvent;
   use AnyEvent::Fork::RPC;

   my $done = AE::cv;

   my $rpc = AnyEvent::Fork
      ->new
      ->require ("AnyEvent::Fork::RPC::Async")
      ->eval (do { local $/; <DATA> })
      ->AnyEvent::Fork::RPC::run ("run",
         async      => 1,
         on_error   => sub { warn "FATAL: $_[0]"; exit 1 },
         on_event   => sub { print $_[0] },
         on_destroy => $done,
      );

   for my $count (3, 2, 1) {
      $rpc->($count, sub {
         warn "job $count finished\n";
      });
   }

   undef $rpc;

   $done->recv;

   __DATA__

   # this ends up in main, as we don't use a package declaration

   use AnyEvent;

   sub run {
      my ($done, $count) = @_;

      my $n;

      AnyEvent::Fork::RPC::event "starting to count up to $count\n";

      my $w; $w = AE::timer 1, 1, sub {
         ++$n;

         AnyEvent::Fork::RPC::event "count $n of $count\n";

         if ($n == $count) {
            undef $w;
            $done->();
         }
      };
   }

The parent part (the one before the C<__DATA__> section) isn't very
different from the earlier examples. It sets async mode, preloads
the backend module (so the C<AnyEvent::Fork::RPC::event> function is
declared), uses a slightly different C<on_event> handler (which we use
simply for logging purposes) and then, instead of loading a module with
the actual worker code, it C<eval>'s the code from the data section in the
child process.

It then starts three countdowns, from 3 to 1 seconds downwards, destroys
the rpc object so the example finishes eventually, and then just waits for
the stuff to trickle in.

The worker code uses the event function to log some progress messages, but
mostly just creates a recurring one-second timer.

The timer callback increments a counter, logs a message, and eventually,
when the count has been reached, calls the finish callback.

On my system, this results in the following output. Since all timers fire
at roughly the same time, the actual order isn't guaranteed, but the order
shown is very likely what you would get, too.

   starting to count up to 3
   starting to count up to 2
   starting to count up to 1
   count 1 of 3
   count 1 of 2
   count 1 of 1
   job 1 finished
   count 2 of 2
   job 2 finished
   count 2 of 3
   count 3 of 3
   job 3 finished

While the overall ordering isn't guaranteed, the async backend still
guarantees that events and responses are delivered to the parent process
in the exact same ordering as they were generated in the child process.

And unless your system is I<very> busy, it should clearly show that the
job started last will finish first, as it has the lowest count.

This concludes the async example. Since L<AnyEvent::Fork> does not
actually fork, you are free to use about any module in the child, not just
L<AnyEvent>, but also L<IO::AIO>, or L<Tk> for example.

=head1 PARENT PROCESS USAGE

This module exports nothing, and only implements a single function:

=over 4

=cut

package AnyEvent::Fork::RPC;

use common::sense;

use Errno ();
use Guard ();

use AnyEvent;
use AnyEvent::Fork; # we don't actually depend on it, this is for convenience

our $VERSION = 0.1;

=item my $rpc = AnyEvent::Fork::RPC::run $fork, $function, [key => value...]

The traditional way to call it. But it is way cooler to call it in the
following way:

=item my $rpc = $fork->AnyEvent::Fork::RPC::run ($function, [key => value...])

This C<run> function/method can be used in place of the
L<AnyEvent::Fork::run> method. Just like that method, it takes over
the L<AnyEvent::Fork> process, but instead of calling the specified
C<$function> directly, it runs a server that accepts RPC calls and handles
responses.

It returns a function reference that can be used to call the function in
the child process, handling serialisation and data transfers.

The following key/value pairs are allowed. It is recommended to have at
least an C<on_error> or C<on_event> handler set.

=over 4

=item on_error => $cb->($msg)

Called on (fatal) errors, with a descriptive (hopefully) message. If
this callback is not provided, but C<on_event> is, then the C<on_event>
callback is called with the first argument being the string C<error>,
followed by the error message.

If neither handler is provided it prints the error to STDERR and will
start failing badly.

=item on_event => $cb->(...)

Called for every call to the C<AnyEvent::Fork::RPC::event> function in the
child, with the arguments of that function passed to the callback.

Also called on errors when no C<on_error> handler is provided.

=item on_destroy => $cb->()

Called when the C<$rpc> object has been destroyed and all requests have
been successfully handled. This is useful when you queue some requests and
want the child to go away after it has handled them. The problem is that
the parent must not exit either until all requests have been handled, and
this can be accomplished by waiting for this callback.

=item init => $function (default none)

When specified (by name), this function is called in the child as the very
first thing when taking over the process, with all the arguments normally
passed to the C<AnyEvent::Fork::run> function, except the communications
socket.

It can be used to do one-time things in the child such as storing passed
parameters or opening database connections.

It is called very early - before the serialisers are created or the
C<$function> name is resolved into a function reference, so it could be
used to load any modules that provide the serialiser or function. It can
not, however, create events.

=item async => $boolean (default: 0)

The default server used in the child does all I/O blockingly, and only
allows a single RPC call to execute concurrently.

Setting C<async> to a true value switches to another implementation that
uses L<AnyEvent> in the child and allows multiple concurrent RPC calls (it
does not support recursion in the event loop however, blocking condvar
calls will fail).

The actual API in the child is documented in the section that describes
the calling semantics of the returned C<$rpc> function.

If you want to pre-load the actual back-end modules to enable memory
sharing, then you should load C<AnyEvent::Fork::RPC::Sync> for
synchronous, and C<AnyEvent::Fork::RPC::Async> for asynchronous mode.

If you use a template process and want to fork both sync and async
children, then it is permissible to load both modules.

=item serialiser => $string (default: $AnyEvent::Fork::RPC::STRING_SERIALISER)

All arguments, result data and event data have to be serialised to be
transferred between the processes. For this, they have to be frozen and
thawed in both parent and child processes.

By default, only octet strings can be passed between the processes, which
is reasonably fast and efficient and requires no extra modules.

For more complicated use cases, you can provide your own freeze and thaw
functions, by specifying a string with perl source code. It's supposed to
return two code references when evaluated: the first receives a list of
perl values and must return an octet string. The second receives the octet
string and must return the original list of values.

If you need an external module for serialisation, then you can either
pre-load it into your L<AnyEvent::Fork> process, or you can add a C<use>
or C<require> statement into the serialiser string. Or both.

Here are some examples - some of them are also available as global
variables that make them easier to use.

=over 4

=item octet strings - C<$AnyEvent::Fork::RPC::STRING_SERIALISER>

This serialiser concatenates length-prefixes octet strings, and is the
default.

Implementation:

   (
      sub { pack   "(w/a*)*", @_ },
      sub { unpack "(w/a*)*", shift }
   )

=item json - C<$AnyEvent::Fork::RPC::JSON_SERIALISER>

This serialiser creates JSON arrays - you have to make sure the L<JSON>
module is installed for this serialiser to work. It can be beneficial for
sharing when you preload the L<JSON> module in a template process.

L<JSON> (with L<JSON::XS> installed) is slower than the octet string
serialiser, but usually much faster than L<Storable>, unless big chunks of
binary data need to be transferred.

Implementation:

   use JSON ();
   (
      sub {    JSON::encode_json \@_ },
      sub { @{ JSON::decode_json shift } }
   )

=item storable - C<$AnyEvent::Fork::RPC::STORABLE_SERIALISER>

This serialiser uses L<Storable>, which means it has high chance of
serialising just about anything you throw at it, at the cost of having
very high overhead per operation. It also comes with perl.

Implementation:

   use Storable ();
   (
      sub {    Storable::freeze \@_ },
      sub { @{ Storable::thaw shift } }
   )

=back

=back

See the examples section earlier in this document for some actual
examples.

=cut

our $STRING_SERIALISER   = '(sub { pack "(w/a*)*", @_ }, sub { unpack "(w/a*)*", shift })';
our $JSON_SERIALISER     = 'use JSON (); (sub { JSON::encode_json \@_ }, sub { @{ JSON::decode_json shift } })';
our $STORABLE_SERIALISER = 'use Storable (); (sub { Storable::freeze \@_ }, sub { @{ Storable::thaw shift } })';

sub run {
   my ($self, $function, %arg) = @_;

   my $serialiser = delete $arg{serialiser} || $STRING_SERIALISER;
   my $on_event   = delete $arg{on_event};
   my $on_error   = delete $arg{on_error};
   my $on_destroy = delete $arg{on_destroy};
   
   # default for on_error is to on_event, if specified
   $on_error ||= $on_event
               ? sub { $on_event->(error => shift) }
               : sub { die "AnyEvent::Fork::RPC: uncaught error: $_[0].\n" };

   # default for on_event is to raise an error
   $on_event ||= sub { $on_error->("event received, but no on_event handler") };

   my ($f, $t) = eval $serialiser; die $@ if $@;

   my (@rcb, %rcb, $fh, $shutdown, $wbuf, $ww);
   my ($rlen, $rbuf, $rw) = 512 - 16;

   my $wcb = sub {
      my $len = syswrite $fh, $wbuf;

      unless (defined $len) {
         if ($! != Errno::EAGAIN && $! != Errno::EWOULDBLOCK) {
            undef $rw; undef $ww; # it ends here
            $on_error->("$!");
         }
      }

      substr $wbuf, 0, $len, "";

      unless (length $wbuf) {
         undef $ww;
         $shutdown and shutdown $fh, 1;
      }
   };

   my $module = "AnyEvent::Fork::RPC::" . ($arg{async} ? "Async" : "Sync");

   $self->require ($module)
        ->send_arg ($function, $arg{init}, $serialiser)
        ->run ("$module\::run", sub {
      $fh = shift;

      my ($id, $len);
      $rw = AE::io $fh, 0, sub {
         $rlen = $rlen * 2 + 16 if $rlen - 128 < length $rbuf;
         $len = sysread $fh, $rbuf, $rlen - length $rbuf, length $rbuf;

         if ($len) {
            while (8 <= length $rbuf) {
               ($id, $len) = unpack "LL", $rbuf;
               8 + $len <= length $rbuf
                  or last;

               my @r = $t->(substr $rbuf, 8, $len);
               substr $rbuf, 0, 8 + $len, "";

               if ($id) {
                  if (@rcb) {
                     (shift @rcb)->(@r);
                  } elsif (my $cb = delete $rcb{$id}) {
                     $cb->(@r);
                  } else {
                     undef $rw; undef $ww;
                     $on_error->("unexpected data from child");
                  }
               } else {
                  $on_event->(@r);
               }
            }
         } elsif (defined $len) {
            undef $rw; undef $ww; # it ends here

            if (@rcb || %rcb) {
               $on_error->("unexpected eof");
            } else {
               $on_destroy->();
            }
         } elsif ($! != Errno::EAGAIN && $! != Errno::EWOULDBLOCK) {
            undef $rw; undef $ww; # it ends here
            $on_error->("read: $!");
         }
      };

      $ww ||= AE::io $fh, 1, $wcb;
   });

   my $guard = Guard::guard {
      $shutdown = 1;
      $ww ||= $fh && AE::io $fh, 1, $wcb;
   };

   my $id;

   $arg{async}
      ? sub {
           $id = ($id == 0xffffffff ? 0 : $id) + 1;
           $id = ($id == 0xffffffff ? 0 : $id) + 1 while exists $rcb{$id}; # rarely loops

           $rcb{$id} = pop;

           $guard; # keep it alive

           $wbuf .= pack "LL/a*", $id, &$f;
           $ww ||= $fh && AE::io $fh, 1, $wcb;
        }
      : sub {
           push @rcb, pop;

           $guard; # keep it alive

           $wbuf .= pack "L/a*", &$f;
           $ww ||= $fh && AE::io $fh, 1, $wcb;
        }
}

=item $rpc->(..., $cb->(...))

The RPC object returned by C<AnyEvent::Fork::RPC::run> is actually a code
reference. There are two things you can do with it: call it, and let it go
out of scope (let it get destroyed).

If C<async> was false when C<$rpc> was created (the default), then, if you
call C<$rpc>, the C<$function> is invoked with all arguments passed to
C<$rpc> except the last one (the callback). When the function returns, the
callback will be invoked with all the return values.

If C<async> was true, then the C<$function> receives an additional
initial argument, the result callback. In this case, returning from
C<$function> does nothing - the function only counts as "done" when the
result callback is called, and any arguments passed to it are considered
the return values. This makes it possible to "return" from event handlers
or e.g. Coro threads.

The other thing that can be done with the RPC object is to destroy it. In
this case, the child process will execute all remaining RPC calls, report
their results, and then exit.

See the examples section earlier in this document for some actual
examples.

=back

=head1 CHILD PROCESS USAGE

The following function is not available in this module. They are only
available in the namespace of this module when the child is running,
without having to load any extra modules. They are part of the child-side
API of L<AnyEvent::Fork::RPC>.

=over 4

=item AnyEvent::Fork::RPC::event ...

Send an event to the parent. Events are a bit like RPC calls made by the
child process to the parent, except that there is no notion of return
values.

See the examples section earlier in this document for some actual
examples.

=back

=head1 ADVANCED TOPICS

=head2 Choosing a backend

So how do you decide which backend to use? Well, that's your problem to
solve, but here are some thoughts on the matter:

=over 4

=item Synchronous

The synchronous backend does not rely on any external modules (well,
except L<common::sense>, which works around a bug in how perl's warning
system works). This keeps the process very small, for example, on my
system, an empty perl interpreter uses 1492kB RSS, which becomes 2020kB
after C<use warnings; use strict> (for people who grew up with C64s around
them this is probably shocking every single time they see it). The worker
process in the first example in this document uses 1792kB.

Since the calls are done synchronously, slow jobs will keep newer jobs
from executing.

The synchronous backend also has no overhead due to running an event loop
- reading requests is therefore very efficient, while writing responses is
less so, as every response results in a write syscall.

If the parent process is busy and a bit slow reading responses, the child
waits instead of processing further requests. This also limits the amount
of memory needed for buffering, as never more than one response has to be
buffered.

The API in the child is simple - you just have to define a function that
does something and returns something.

It's hard to use modules or code that relies on an event loop, as the
child cannot execute anything while it waits for more input.

=item Asynchronous

The asynchronous backend relies on L<AnyEvent>, which tries to be small,
but still comes at a price: On my system, the worker from example 1a uses
3420kB RSS (for L<AnyEvent>, which loads L<EV>, which needs L<XSLoader>
which in turn loads a lot of other modules such as L<warnings>, L<strict>,
L<vars>, L<Exporter>...).

It batches requests and responses reasonably efficiently, doing only as
few reads and writes as needed, but needs to poll for events via the event
loop.

Responses are queued when the parent process is busy. This means the child
can continue to execute any queued requests. It also means that a child
might queue a lot of responses in memory when it generates them and the
parent process is slow accepting them.

The API is not a straightforward RPC pattern - you have to call a
"done" callback to pass return values and signal completion. Also, more
importantly, the API starts jobs as fast as possible - when 1000 jobs
are queued and the jobs are slow, they will all run concurrently. The
child must implement some queueing/limiting mechanism if this causes
problems. Alternatively, the parent could limit the amount of rpc calls
that are outstanding.

Blocking use of condvars is not supported.

Using event-based modules such as L<IO::AIO>, L<Gtk2>, L<Tk> and so on is
easy.

=back

=head2 Passing file descriptors

Unlike L<AnyEvent::Fork>, this module has no in-built file handle or file
descriptor passing abilities.

The reason is that passing file descriptors is extraordinary tricky
business, and conflicts with efficient batching of messages.

There still is a method you can use: Create a
C<AnyEvent::Util::portable_socketpair> and C<send_fh> one half of it to
the process before you pass control to C<AnyEvent::Fork::RPC::run>.

Whenever you want to pass a file descriptor, send an rpc request to the
child process (so it expects the descriptor), then send it over the other
half of the socketpair. The child should fetch the descriptor from the
half it has passed earlier.

Here is some (untested) pseudocode to that effect:

   use AnyEvent::Util;
   use AnyEvent::Fork::RPC;
   use IO::FDPass;

   my ($s1, $s2) = AnyEvent::Util::portable_socketpair;

   my $rpc = AnyEvent::Fork
      ->new
      ->send_fh ($s2)
      ->require ("MyWorker")
      ->AnyEvent::Fork::RPC::run ("MyWorker::run"
           init => "MyWorker::init",
        );

   undef $s2; # no need to keep it around

   # pass an fd
   $rpc->("i'll send some fd now, please expect it!", my $cv = AE::cv);

   IO::FDPass fileno $s1, fileno $handle_to_pass;

   $cv->recv;

The MyWorker module could look like this:

   package MyWorker;

   use IO::FDPass;

   my $s2;

   sub init {
      $s2 = $_[0];
   }

   sub run {
      if ($_[0] eq "i'll send some fd now, please expect it!") {
         my $fd = IO::FDPass::recv fileno $s2;
         ...
      }
   }

Of course, this might be blocking if you pass a lot of file descriptors,
so you might want to look into L<AnyEvent::FDpasser> which can handle the
gory details.

=head1 SEE ALSO

L<AnyEvent::Fork>, to create the processes in the first place.

L<AnyEvent::Fork::Pool>, to manage whole pools of processes.

=head1 AUTHOR AND CONTACT INFORMATION

 Marc Lehmann <schmorp@schmorp.de>
 http://software.schmorp.de/pkg/AnyEvent-Fork-RPC

=cut

1

