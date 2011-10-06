package POE::Wheel::ZeroMQ;
use strict;
use warnings;

use vars qw($VERSION);
$VERSION = '1.020'; # NOTE - Should be #.### (three decimal places)

use POE qw(Wheel);
use base qw(POE::Wheel);
use Symbol qw(gensym);

use ZeroMQ qw(:all) ;
use Carp qw( croak carp );
use POSIX qw(EAGAIN);

sub SOCKET()			{ 0 }
sub HANDLE()			{ 1 }
sub EVENT_INPUT()		{ 2 }
sub EVENT_INPUT_CTX(){ 3 }
sub EVENT_ERROR()		{ 4 }
sub STATE_EVENTS()	{ 5 }
sub BUFFER_OUT()		{ 6 } 
sub UNIQUE_ID()		{ 7 }

=head1 NAME

POE::Wheel::ZeroMQ - POE Wheel to use non-blocking ZeroMQ sockets in POE.

=head1 SYNOPSIS
	
This implements a 'echo-server' POE app, suitable for running
together with ZeroMQ distributions perf/remote_lat tool (ie, this
replaces local_lat)

	use ZeroMQ qw(:all);
	use POE::Wheel::ZeroMQ;
	use POE;

	POE::Session->create(
		inline_states => {
			_start => sub {
				my $ctx = ZeroMQ::Context->new();
				$_[HEAP]{wheel} = POE::Wheel::ZeroMQ->new(
					Context => $ctx,
					SocketType => ZMQ_REP,
					SocketBind => 'tcp://127.0.0.1:5555',
					InputEvent => 'on_remote_data',
					InputEventContext => 'main socket'
				);
			},
			on_remote_data => sub {
				my $msgs = $_[ARG0];
				my $ctx = $_[ARG1];
				#print "Received ".(scalar @$msgs)." msgs on $ctx\n";
				$_[HEAP]{wheel}->send($msgs->[0]);
			},
		},
	);
	POE::Kernel->run();

Some quickly observed test result:

	zeromq-2.1.1/perf$ ./remote_lat tcp://127.0.0.1:5555 1024 1000
	message size: 1024 [B]
	roundtrip count: 1000
	average latency: 155.037 [us]

Compared to running against local_lat.cpp on the same laptop:

	zeromq-2.1.1/perf$ ./remote_lat tcp://127.0.0.1:5555 1024 1000
	message size: 1024 [B]
	roundtrip count: 1000
	average latency: 75.133 [us]

So, performance-wise, much worse! But it works.

For more examples, please see the tests.

=head1 DESCRIPTION

POE::Wheel::ZeroMQ is a simple wrapper around the ZeroMQ::Socket. It does not try
to be very smart, it just allows using the ZeroMQ::Socket's async.
This should be seen as an alterative to the AnyEvent::ZeroMQ library which
is similar, but adds additional dependency on AnyEvent and Moose. 

=head1 METHODS

=head2 new

new() creates and returns a ZeroMQ socket wheel based on a few named parameters.
You can either feed it an already
created socket, or you can use the convenience methods to let it create the
socket on the fly. Connect and bind operations can be done aswell.

=over 4

=item Socket

If you already have a ZeroMQ::Socket ready to use, you can give a reference to it
through this parameter.

=item SocketType

If Socket is unspecified, this indicates what type of socket to create. Should be one
of the ZMQ_REP, ZMQ_REQ etc constants. Requires the Context parameter.

=item Context

If a socket is to be created (ie no Socket parameter set), we require a reference to
a running ZMQ::Context. The caller should make sure it is alive at all times by keeping
a reference to it. If the reference is dropped right after the POE::Wheel::ZeroMQ is created,
the socket will be non-functional!

=item SocketBind

A convenience function to call bind() on the socket. Should contain the argument which is
passed to bind().

=item SocketConnect

Same as SocketBind, but for connect().

=item Subscribe

A convenience function to setsockopt(ZMQ_SUBSCRIBE, ..). Will be called right before
any bind/conncet is performed (if SocketBind/Connect is specified).

=item Identity

A convenience function to setsockopt(ZMQ_IDENTITY, ..). Will be called right before
any bind/conncet is performed (if SocketBind/Connect is specified).

=item InputEvent

This is called whenever a new message has been received. ARG0 will be an array
reference containing all the messages in the "set" of messages as indicated 
by the ZMQ_RCVMORE flag.
This might be bad if you are planning to receive a lot of large messages, in which
case a large amount of memory would have to be allocated at once. If such 
funcitonality is desired one could pretty easily modify the library to take
a flag to indicate "deliver on at a time". Not implemented now though.

=item InputEventContext

Optional free data which is passed as ARG1 to the input event.
This could be used to associate the socket with some app-specific details.

=back

=cut

sub new {
	my $type = shift;
	my %params = @_;

	croak "$type requires a working Kernel" unless defined $poe_kernel;

	my ($socket, $sockettype, $bind, $connect,
		$inputevent, $inputeventctx, $errorevent,
		$subscribe, $identity, $ctx);

	$ctx = delete $params{Context};

	if(defined $params{Socket}) {
		# Socket parameter always overrides any other
		carp "Ignoring SocketType parameter, Socket overrides"
			if defined $params{SocketType};
		$socket = delete $params{Socket};
	} else {
		croak "No Socket parameter, Context parameter required"
			unless defined $ctx;

		# If we have no specific socket, we require SocketType.
		croak "Socket or SocketType parameter requried"
			unless defined $params{SocketType};

		$sockettype = delete $params{SocketType};
	}

	# Binding or connecting? ZeroMQ allows both, on the same socket,
	# in certain socket types. Let the user do what he wants, lets not
	# try to be smart for him!
	$bind = delete $params{SocketBind}
  		if(defined $params{SocketBind}) ;
	$connect = delete $params{SocketConnect}
  		if(defined $params{SocketConnect}) ;

	$inputevent = delete $params{InputEvent};
	$inputeventctx = delete $params{InputEventContext};
	$errorevent = delete $params{ErrorEvent};

	$subscribe = delete $params{Subscribe};
	$identity = delete $params{Identity};


	# Anything else is error
	if (scalar keys %params) {
		carp("unknown parameters in $type constructor call: ",
			join(', ', keys %params)
		);
	}

	# All params accounted for. Lets create a socket
	# Create a socket, or use an existing one.
	# Now it is important that we dont let $ctx drop out of 
	# scope, if that happens then the sockets will just stop
	# working. 
	if(!defined $socket) {
		# And the socket
		$socket = $ctx->socket($sockettype);
	}

	# If we got subscription, try to subscribe. Only for ZMQ_SUB sockets,
	# but again, the user should know what he does.
	# This have to be done before connect()
	if(defined $subscribe) {
		$socket->setsockopt(ZMQ_SUBSCRIBE, $subscribe);
	}

	if(defined $identity) {
		$socket->setsockopt(ZMQ_IDENTITY, $identity);
	}

	# Bind/Connect if requested 
	$socket->bind($bind) if(defined $bind) ;
	$socket->connect($connect) if(defined $connect) ;

	# Fetch the ZMQ_FD
	my $fd = $socket->getsockopt(ZMQ_FD);
	
	# To be able to use the FD with POE's select loop, we need a filehandle.
	# We could get one with IO::Handle->new_from_fd, which would naturally wrap the 
	# existing fd with a Perl Filehandle. The problem comes when the filehandle is closed.
	# The new_from_fd call ultimately calls C<open $h, "<&=$fd">. What this does is 
	# "Instead, it will just make something of an alias to the existing one using the fdopen(3S)
	# library call"
	# Now, that is not a problem as long as we're running, however when we are freeing the
	# filehandle, it will automatically call close() on it. Closing a FD owned by zmq is
	# unarguably not good (will crash badly when it tries to clean up internally).
	#
	# So. Instead make sure we just use a regular FD 'dup' instead. The difference is in 
	# the '=' sign. Use a generic symbol for this too, no need for IO::Handle.
	my $handle = gensym();
	open($handle, "<&$fd") or croak("Failed to open: $!");

	# Great; lets bless ourself
	my $self = bless [
		$socket,								# SOCKET
		$handle,								# HANDLE
		$inputevent,						# EVENT_INPUT
		$inputeventctx,					# EVENT_INPUT_CTX
		$errorevent,						# EVENT_ERROR

		# Internal state name
		undef,								# STATE_EVENTS 
		
		[], 									# BUFFER_OUT

		# Get us an uniqueu wheel ID
		&POE::Wheel::allocate_wheel_id(), # UNIQUE_ID

		], $type;

	# Lets define our main event state. It will just call check_event
	my $unique_id = $self->[UNIQUE_ID];
	$poe_kernel->state(
		$self->[STATE_EVENTS] = ref($self) . "($unique_id) -> select read",
		sub { $self->check_event; }
	);

	# Anyhow, lets read!
	$poe_kernel->select_read($handle, $self->[STATE_EVENTS]);

	return $self;
}

sub check_event {
	my ($self) = @_;
	my $socket = $self->[SOCKET];

	# A "event" on our ZMQ_FD only indicates that ZMQ want's "something".
	# Exactly what is to be found out!
	# Repeatedly read it until there are no more pending events.

	# Note that we might get an even triggered but no events to read/write,
	# this is fully valid. An example seems to be when we get an event in a SUB socket
	# NOT matching our subscription filter.
	while((my $events = $socket->getsockopt(ZMQ_EVENTS)) != 0) {
		if(($events & ZMQ_POLLIN) == ZMQ_POLLIN) {
			# We got data to recv. We do recv until
			# we RCVMORE says "nothing more", and then we 
			# feed all those msgs to the registered input event
			# XXX: If messages are very large, this will consume 
			# lots of memory. The user might want to handle
			# the messages one by one instead.
			# Implement idea: a SingleReadEvent handler which only gets feed
			# one msg at a time.
			my @msgs;
			do {
				push @msgs, $socket->recv(ZMQ_NOBLOCK);
			}while($socket->getsockopt(ZMQ_RCVMORE));

			$poe_kernel->yield($self->[EVENT_INPUT], \@msgs, $self->[EVENT_INPUT_CTX]);
		}

		# If we got a pollout event, and we got data left to write; write it.
		if(($events & ZMQ_POLLOUT) == ZMQ_POLLOUT &&
			scalar @{$self->[BUFFER_OUT]} > 0) {
			$self->write_one(1);
		}elsif($events == ZMQ_POLLOUT) {
			# If we ONLY got pollout, and no more read,
			# then we're done.
			last;
		}
	}
}

sub write_one
{
	my $self = shift;
	my $from_loop = shift;

	my $m = shift @{$self->[BUFFER_OUT]};
	my ($msg, $flags) = @$m;

	if($self->[SOCKET]->send($msg, ZMQ_NOBLOCK | $flags) == -1) {
		my $errno = $!;
		if($errno == EAGAIN) {
			# Push the msg back to the buffer, and try later.
			unshift @{$self->[BUFFER_OUT]}, $m;
			return;
		}

		die"writing one failed with $errno";
	}
	
	return if $from_loop;
	# If we are called from outside event selector, we need to check
	# for new events. In case we're doing 'write' from outside an event loop,
	# it seems the socket isnt triggered properly..
	my $ev = $self->[SOCKET]->getsockopt(ZMQ_EVENTS);
	$self->check_event if($ev != 0);
	return undef;
}

=head2 send

First argument is a single ZeroMQ::Message, or an array-ref with one or more
ZeroMQ::Messages. The array method can be used to send a multi-part message.

The second argument is any flags to forward on to the ZeroMQ::Socket
send method. Currently the only flag which makes any sense would be
the ZMQ_SNDMORE flag, if there are more message parts to come. However, if you use the
array-ref method, the ZMQ_SNDMORE flag is set automatically.

This method is non-blocking, and does not give any indication about success/failure.

=cut
sub send
{
	my ($self, $msg, $flags) = @_;
	$flags = 0 unless defined $flags;

	if(ref $msg eq 'ARRAY') {
		# Set SNDMORE for all messages
		$flags |= ZMQ_SNDMORE;
		for(my $i = 0; $i < @$msg; $i++) {
			# And remove SNDMORE for the last message
			$flags &= ~ZMQ_SNDMORE if($i == @$msg-1);

			# Push each individual msg
			push @{$self->[BUFFER_OUT]}, [$msg->[$i], $flags];
		}
	}
	else
	{
		# Push data to send to queue
		push @{$self->[BUFFER_OUT]}, [$msg, $flags];
	}

	$self->write_one;
}


=head2 close

To close the wheel you should call this. This will in turn call close() on the 
socket, regardless of how it was created.

=cut
sub close
{
	my $self = $_[0];
	return unless defined $self->[HANDLE];

	# Remove it from the select
	$poe_kernel->select_read($self->[HANDLE]);

	# and explicitly close handles & 
	# remove references.
	$self->[HANDLE]->close();
	delete $self->[HANDLE];

	$self->[SOCKET]->close();
	delete $self->[SOCKET];
}

=head2 socket

Returns the underlying socket, if the caller would like to do any
special operations on it.

=cut
sub socket {
	return $_[0]->[SOCKET];
}

# Get the wheel's ID.
sub ID {
	return $_[0]->[UNIQUE_ID];
}

sub DESTROY {
	my $self = shift;
	# We need to deallocate some stuff.

	$self->close();
	&POE::Wheel::free_wheel_id($self->[UNIQUE_ID]);
}

=head1 CAVEATS

This is an early release, developed together with an early release of the 
ZeroMQ perl library (0.09) and ZeroMQ 2.1.1.

There is currently no support for the serializer functions in the ZeroMQ perl modules.

It is to be considered experimental, and might contain problems or bugs.
If you find any, please report them to the author!

=head1 AUTHOR

Johan Strom "<johan@stromnet.se>"

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2011 by Johan Strom

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See http://www.perl.com/perl/misc/Artistic.html

=cut

1;
