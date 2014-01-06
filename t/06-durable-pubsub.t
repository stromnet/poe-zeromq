use strict;
use warnings;
use lib 'lib';
use ZMQ qw(:all);
use ZMQ::Constants qw(:all) ;
use POE::Wheel::ZeroMQ;
use Time::HiRes qw(sleep);

my $version_string = ZMQ::call( "zmq_version" );
print "Starting with ZMQ $version_string\n";

if($version_string =~ /^3./){
	use Test::More skip_all => "No durable sockets in ZMQ3";
	exit(0);
}

use POE;
use Test::More tests => 22;

# This test starts two sockets; one pub and one sub.
# The subscriber have a set identity.
# It sends 10 messages in a go.
# After 5 messages, the subscriber closes itself and re-connects.
# All 10 messages should arrive (since we're durable)
POE::Session->create(
		inline_states => {
			_start => sub {
				my $ctx = ZMQ::Context->new();
				$_[HEAP]{p} = POE::Wheel::ZeroMQ->new(
						SocketType => ZMQ_PUB,
						SocketBind => "tcp://127.0.0.1:55559",
						Context => $ctx
					);

				$_[HEAP]{ctx} = $ctx;
				$_[KERNEL]->call($_[SESSION]->ID, 'connect_sub');

				$_[HEAP]{cnt} = 0;
				$_[HEAP]{cnt2} = 0;

				sleep(0.5); # Wait for subscriber
				$poe_kernel->yield('ping', 1);
			},
			_stop => sub {
				$_[HEAP]{ctx}->term;
			},
			connect_sub => sub {
				print "Connceting subscriber\n";
				$_[HEAP]{s} = POE::Wheel::ZeroMQ->new(
						SocketType => ZMQ_SUB,
						SocketConnect => "tcp://127.0.0.1:55559",
						InputEvent => 'got_input',
						InputEventContext => 'test socket',
						Identity => 'MyIdentity',
						Subscribe => 'ping',
						Context => $_[HEAP]{ctx}
					);
			},
			got_input => sub {
				my $msgs = $_[ARG0];
				my $ctx = $_[ARG1];
				my $msg = shift @$msgs;

				is($ctx, 'test socket');

				print localtime()." Got ".($msg->data)."\n";

				my $cnt = substr($msg->data, 4);
				is($cnt, $_[HEAP]{cnt2}, 'correct cnt');
				$_[HEAP]{cnt2}++;

				if($cnt == 5) {
					# After 5 pings, close socket, leave it closed for a second,
					# and reopen it.
					print "Tearing down subscriber\n";
					$_[HEAP]{s}->close();
					delete $_[HEAP]{s};
					$poe_kernel->delay('connect_sub', 1); 
				} 
		
				if($cnt >= 10) {
					# Break;
					$_[HEAP]{p}->close();
					$_[HEAP]{s}->close();
				}
			},

			ping => sub {
				my $msg = "ping" . $_[HEAP]{cnt} ++;

				print localtime()." Sending $msg\n";

				$_[HEAP]{p}->send(ZMQ::Message->new($msg));
				if($_[HEAP]{cnt} <= 10) {
					$poe_kernel->delay('ping', 0.1);
				}
			}
		}
	);

POE::Kernel->run();

