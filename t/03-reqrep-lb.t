use strict;
use warnings;
use ZeroMQ qw(:all);
use POE::Wheel::ZeroMQ;

my $version_string = ZeroMQ::version();
print "Starting with ZMQ $version_string\n";

use POE;
use Test::More tests => 10*5;

# This test starts three sockets; one req and two rep.
# It sends 10 messages, all should be received, every other by each other rep
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

				$_[HEAP]{rep1} = POE::Wheel::ZeroMQ->new(
						SocketType => ZMQ_REP,
						SocketConnect => "tcp://127.0.0.1:55559",
						InputEvent => 'got_input1',
						Context => $ctx
					);

				$_[HEAP]{rep2} = POE::Wheel::ZeroMQ->new(
						SocketType => ZMQ_REP,
						SocketConnect => "tcp://127.0.0.1:55559",
						InputEvent => 'got_input2',
						Context => $ctx
					);

				$_[HEAP]{cnt} = 0;
				$_[HEAP]{ctx} = $ctx;

				$poe_kernel->yield('ping');
			},
			_stop => sub {
				$_[HEAP]{ctx}->term;
			},
			got_input1 => sub {
				my $msgs = $_[ARG0];
				my $msg = shift @$msgs;

				print localtime()." rep1  got ".($msg->data)."\n";

				my $cnt = substr($msg->data, 4);
				is(substr($msg->data,0,4), 'ping', 'correct ping');
				is($cnt, $_[HEAP]{cnt}, 'correct cnt');
				is($cnt % 2, 0, 'correctly received by first socket');

				# send response.
				my $resp_msg = "pong". $_[HEAP]{cnt};
				print localtime()." rep1 send $resp_msg\n";
				$_[HEAP]{rep1}->send(ZeroMQ::Message->new($resp_msg));
			},
			got_input2 => sub {
				my $msgs = $_[ARG0];
				my $msg = shift @$msgs;

				print localtime()." rep2  got ".($msg->data)."\n";

				my $cnt = substr($msg->data, 4);
				is(substr($msg->data,0,4), 'ping', 'correct ping');
				is($cnt, $_[HEAP]{cnt}, 'correct cnt');
				is($cnt % 2, 1, 'correctly received by second socket');

				# send response.
				my $resp_msg = "pong". $_[HEAP]{cnt};
				print localtime()." rep2 send $resp_msg\n";
				$_[HEAP]{rep2}->send(ZeroMQ::Message->new($resp_msg));
			},
			got_response => sub {
				my $msgs = $_[ARG0];
				my $msg = shift @$msgs;

				print localtime()." req   got ".($msg->data)."\n";

				my $cnt = substr($msg->data, 4);
				is(substr($msg->data,0,4), 'pong', 'correct pong');
				is($cnt, $_[HEAP]{cnt}, 'correct cnt');

				$cnt = $_[HEAP]{cnt}++;

				if($cnt == 9) {
					# Break;
					$_[HEAP]{req}->close();
					$_[HEAP]{rep1}->close();
					$_[HEAP]{rep2}->close();
					return;
				}

				# ping again
				$poe_kernel->yield('ping');
			},

			ping => sub {
				my $msg = "ping". $_[HEAP]{cnt} ;
				print localtime()." req  send $msg\n";
				$_[HEAP]{req}->send(ZeroMQ::Message->new($msg));
			}
		}
	);

POE::Kernel->run();


