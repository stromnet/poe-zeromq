use lib 'lib';
use ZeroMQ qw(:all);
use POE::Wheel::ZeroMQ;
use strict;
use warnings;

my $version_string = ZeroMQ::version();
print "Starting with ZMQ $version_string\n";

use POE;

POE::Session->create(
	inline_states => {
		_start => sub {
			my $ctx = ZeroMQ::Context->new();
			$_[HEAP]{ctx} = $ctx;
			$_[HEAP]{wheel} = POE::Wheel::ZeroMQ->new(
				Context => $ctx,
				SocketType => ZMQ_REP,
				SocketBind => 'tcp://127.0.0.1:5555',
				InputEvent => 'on_remote_data'
			);
		},
		on_remote_data => sub {
			my $msgs = $_[ARG0];
			#print "Received ".(scalar @$msgs)." msgs\n";
			$_[HEAP]{wheel}->send($msgs->[0]);
		},
	},
);

POE::Kernel->run();
