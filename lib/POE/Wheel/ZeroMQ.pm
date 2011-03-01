package POE::Wheel::ZeroMQ;
use strict;
use warnings;

use vars qw($VERSION);
$VERSION = '1.000'; # NOTE - Should be #.### (three decimal places)

use POE qw(Wheel);
use base qw(POE::Wheel);
use Symbol qw(gensym);

use ZeroMQ qw(:all);
use Carp qw( croak carp );
use POSIX qw(EAGAIN);

sub SOCKET()			{ 0 }
sub HANDLE()			{ 1 }
sub EVENT_INPUT()		{ 2 }
sub EVENT_ERROR()		{ 3 }
sub STATE_EVENTS()	{ 4 }
sub BUFFER_OUT()		{ 5 } 
sub UNIQUE_ID()		{ 6 }

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
		$subscribe, $ctx);

	croak "Context parameter required"
		unless defined $params{Context};

	$ctx = delete $params{Context};

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
			# We got data to recv. We do recv until
			# we RCVMORE says "nothing more", and then we 
			# feed all those msgs to the registered input event
			my @msgs;
			do {
				push @msgs, $socket->recv(ZMQ_NOBLOCK);
			}while($socket->getsockopt(ZMQ_RCVMORE));

			$poe_kernel->yield($self->[EVENT_INPUT], \@msgs);
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

sub send
{
	my ($self, $msg, $flags) = @_;
	$flags = 0 unless defined $flags;
	# Push data to send to queue
	push @{$self->[BUFFER_OUT]}, [$msg, $flags];

	$self->write_one;
}

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


1;
