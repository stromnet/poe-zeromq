package POE::Wheel::ZeroMQ;
use strict;
use warnings;

use vars qw($VERSION);
$VERSION = '1.000'; # NOTE - Should be #.### (three decimal places)

use POE qw(Wheel);
use base qw(POE::Wheel);

use ZeroMQ qw(:all);
use Carp qw( croak carp );
use POSIX qw(EAGAIN);

sub CONTEXT()			{ 0 }
sub SOCKET()			{ 1 }
sub HANDLE()			{ 2 }
sub EVENT_INPUT()		{ 3 }
sub EVENT_ERROR()		{ 4 }
sub STATE_EVENTS()	{ 5 }
sub BUFFER_OUT()		{ 6 } 
sub UNIQUE_ID()		{ 7 }

=head1 NAME

POE::Wheel::ZeroMQ - POE Wheel to use non-blocking ZeroMQ sockets in POE.

=head1 SYNOPSIS
	
	# This implements a 'echo-server' POE app, suitable for running
	# together with ZeroMQ distributions perf/remote_lat tool.

	POE::Session->create(
		inline_states => {
			_start => sub {
				$_[HEAP]{wheel} = POE::Wheel::ZeroMQ->new(
					SocketType => ZeroMQ::ZMQ_REP,
					SocketBind => 'tcp://127.0.0.1:5555',
					InputEvent => 'on_remote_data',
					ErrorEvent => 'on_remote_fail'
				);
			},
			on_remote_data => sub {
				print "Received: $_[ARG0]\n";
			},
			on_remote_fail => sub {
				print "Connection failed or ended.  Shutting down...\n";
				delete $_[HEAP]{client};
			},
		},
	);

=head1 DESCRIPTION

POE::Wheel::ZeroMQ is a simple wrapper around ZeroMQ::Sockets

=head1 PUBLIC METHODS

=head3 new

new() creates and returns a ZeroMQ socket wrapper.

=head4 Socket

This can be a 


=cut

sub new {
	my $type = shift;
	my %params = @_;

	croak "$type requires a working Kernel" unless defined $poe_kernel;

	my ($socket, $sockettype, $bind, $connect,
		$inputevent, $errorevent,
		$subscribe);
	if(defined $params{Socket}) {
		# Socket parameter always overrides any other
		carp "Ignoring SocketType parameter, Socket overrides"
			if defined $params{SocketType};
		$socket = delete $params{Socket};
	} else {
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
	$errorevent = delete $params{ErrorEvent};

	$subscribe = delete $params{Subscribe};

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
	my $ctx;
	if(!defined $socket) {
		# No socket defined, do we at least have a context?
		$ctx = delete $params{Context} if(defined $params{Context});

		# If not create one
		$ctx = ZeroMQ::Context->new unless(defined $ctx);

		# And the socket
		$socket = $ctx->socket($sockettype);
	}

	# Bind/Connect if requested 
	$socket->bind($bind) if(defined $bind) ;
	$socket->connect($connect) if(defined $connect) ;

	# Fetch the ZMQ_FD
	my $fd = $socket->getsockopt(ZMQ_FD);
	
	# Wrap it in a IO::Handle to be able to select_read on it.
	# This fd indicates any kind of zmq IO, so we dont need a 'write' handle.
	my $handle = IO::Handle->new_from_fd($fd, 'r');

	# Great; lets bless ourself
	my $self = bless [
		$ctx,									# CONTEXT
		$socket,								# SOCKET
		$handle,								# HANDLE
		$inputevent,						# EVENT_INPUT
		$errorevent,						# EVENT_ERROR

		# Internal state name
		undef,								# STATE_EVENTS 
		
		[], 									# BUFFER_OUT

		# Get us an uniqueu wheel ID
		&POE::Wheel::allocate_wheel_id(), # UNIQUE_ID

		], $type;

	my $event_input  = \$self->[EVENT_INPUT];
	my $event_error  = \$self->[EVENT_ERROR];

	# Lets define our main event state. It will just call check_event
	my $unique_id = $self->[UNIQUE_ID];
	$poe_kernel->state(
		$self->[STATE_EVENTS] = ref($self) . "($unique_id) -> select read",
		sub { $self->check_event; }
	);

	# If we got subscription, try to subscribe. Only for ZMQ_SUB sockets,
	# but again, the user should know what he does.
	if(defined $subscribe) {
		$socket->setsockopt(ZMQ_SUBSCRIBE, $subscribe);
	}

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
		# XXX: How would we handle RECVMORE stuff?
		# For now, if we read we just feed it to input event.
		if(($events & ZMQ_POLLIN) == ZMQ_POLLIN) {
			# We got data to recv
			my $msg = $socket->recv(ZMQ_NOBLOCK);
			$poe_kernel->yield($self->[EVENT_INPUT], $msg);
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
			print "writing one failed with $errno, trying later\n";
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

sub send
{
	my ($self, $msg, $flags) = @_;
	$flags = 0 unless defined $flags;
	# Push data to send to queue
	push @{$self->[BUFFER_OUT]}, [$msg, $flags];

	$self->write_one;
}

sub ctx
{
	return $_[0]->[CONTEXT];
}

# Get the wheel's ID.
sub ID {
	return $_[0]->[UNIQUE_ID];
}

sub DESTROY {
	my $self = shift;
	# We need to deallocate some stuff.

	$poe_kernel->select_read($self->[HANDLE]);
	&POE::Wheel::free_wheel_id($self->[UNIQUE_ID]);
	undef $self->[HANDLE];
	
	# XXX: Should we close() the socket?
}


1;

