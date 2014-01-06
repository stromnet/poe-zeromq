use strict;
use warnings;
use lib 'lib';
use ZMQ qw(:all);
use ZMQ::Constants qw(:all) ;
use POE::Wheel::ZeroMQ;
use Time::HiRes qw(sleep);

my $version_string = ZMQ::call( "zmq_version" );
print "Starting with ZMQ $version_string\n";

use POE;
use Test::More tests => 12;

# This test starts two sockets; one pub and one sub.
# It sends 10 messages, every other on a subscribed subject,
# and makes sure that 50% are received. Then exits.
POE::Session->create(
		inline_states => {
			_start => sub {
				my $ctx = ZMQ::Context->new();
				$_[HEAP]{p} = POE::Wheel::ZeroMQ->new(
						SocketType => ZMQ_PUB,
						SocketBind => "tcp://127.0.0.1:55559",
						Context => $ctx
					);

				$_[HEAP]{s} = POE::Wheel::ZeroMQ->new(
						SocketType => ZMQ_SUB,
						SocketConnect => "tcp://127.0.0.1:55559",
						InputEvent => 'got_input',
						InputEventContext => 'test socket',
						Subscribe => 'ping',
						Context => $ctx
					);

				$_[HEAP]{cnt} = 0;
				$_[HEAP]{ctx} = $ctx;

				sleep(0.5); # Wait for subscriber
				$poe_kernel->yield('ping', 1);
			},
			_stop => sub {
				$_[HEAP]{ctx}->term;
			},
			got_input => sub {
				my $msgs = $_[ARG0];
				my $ctx = $_[ARG1];
				my $msg = shift @$msgs;

				is($ctx, 'test socket');

				print localtime()." Got ".($msg->data)."\n";

				# We should get every other cnt
				my $cnt = substr($msg->data, 4);
				is($cnt, $_[HEAP]{cnt}-1, 'correct cnt');
				
				if($cnt >= 10) {
					# Break;
					$_[HEAP]{p}->close();
					$_[HEAP]{s}->close();
					$poe_kernel->delay('ping'); # No more calls please
				}
			},

			ping => sub {
				my $msg = ($_[HEAP]{cnt} % 2 == 0? "ping":"") 
					. $_[HEAP]{cnt} ++;

				print localtime()." Sending $msg\n";

				$_[HEAP]{p}->send(ZMQ::Message->new($msg));
				$poe_kernel->delay('ping', 0.1);
			}
		}
	);

POE::Kernel->run();
