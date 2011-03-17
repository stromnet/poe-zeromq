use strict;
use warnings;
use ZeroMQ qw(:all);
use POE::Wheel::ZeroMQ;

my $version_string = ZeroMQ::version();
print "Starting with ZMQ $version_string\n";

use POE;
use Test::More tests => 10*4;

# This test starts two sockets; one req and one rep
# It sends 10 messages, all should be received.
POE::Session->create(
		inline_states => {
			_start => sub {
				my $ctx = ZeroMQ::Context->new();
				$_[HEAP]{req} = POE::Wheel::ZeroMQ->new(
						SocketType => ZMQ_REQ,
						SocketBind => "tcp://127.0.0.1:55559",
						InputEvent => 'got_response',
						Context => $ctx
					);

				$_[HEAP]{rep} = POE::Wheel::ZeroMQ->new(
						SocketType => ZMQ_REP,
						SocketConnect => "tcp://127.0.0.1:55559",
						InputEvent => 'got_input',
						Context => $ctx
					);

				$_[HEAP]{cnt} = 0;
				$_[HEAP]{ctx} = $ctx;

				$poe_kernel->yield('ping');
			},
			_stop => sub {
				$_[HEAP]{ctx}->term;
			},
			got_input => sub {
				my $msgs = $_[ARG0];
				my $msg = shift @$msgs;

				print localtime()." Got ".($msg->data)."\n";

				my $cnt = substr($msg->data, 4);
				is(substr($msg->data,0,4), 'ping', 'correct ping');
				is($cnt, $_[HEAP]{cnt}, 'correct cnt');

				# send response.
				my $resp_msg = "pong". $_[HEAP]{cnt};
				print localtime()." Responding $resp_msg\n";
				$_[HEAP]{rep}->send(ZeroMQ::Message->new($resp_msg));
			},
			got_response => sub {
				my $msgs = $_[ARG0];
				my $msg = shift @$msgs;

				my $cnt = substr($msg->data, 4);
				is(substr($msg->data,0,4), 'pong', 'correct pong');
				is($cnt, $_[HEAP]{cnt}, 'correct cnt');

				$cnt = $_[HEAP]{cnt}++;

				if($cnt >= 9) {
					# Break;
					$_[HEAP]{req}->close();
					$_[HEAP]{rep}->close();
					return;
				}

				# ping again
				$poe_kernel->yield('ping');
			},

			ping => sub {
				my $msg = "ping". $_[HEAP]{cnt} ;
				print localtime()." Sending $msg\n";
				$_[HEAP]{req}->send(ZeroMQ::Message->new($msg));
			}
		}
	);

POE::Kernel->run();

