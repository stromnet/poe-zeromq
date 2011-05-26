use strict;
use warnings;
use ZeroMQ qw(:all);
use POE::Wheel::ZeroMQ;

my $version_string = ZeroMQ::version();
print "Starting with ZMQ $version_string\n";

use POE;
use Test::More tests => 10*9;

# This test starts two sockets; one xreq and one rep
# It sends 10 messages, all should be received.
POE::Session->create(
		inline_states => {
			_start => sub {
				my $ctx = ZeroMQ::Context->new();
				$_[HEAP]{xreq} = POE::Wheel::ZeroMQ->new(
						SocketType => ZMQ_XREQ,
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
			ping => sub {
				my $cnt = $_[HEAP]{cnt};
				my $msg = "ping". $cnt ;
				print localtime()." Sending $msg\n";
				# Build a msg
				my @env = (
					ZeroMQ::Message->new('ID'.$cnt),
					ZeroMQ::Message->new(''),
					ZeroMQ::Message->new($msg)
				);
				if($cnt % 2 == 0) {
					# Send manually for half
					$_[HEAP]{xreq}->send(shift @env, ZMQ_SNDMORE);
					$_[HEAP]{xreq}->send(shift @env, ZMQ_SNDMORE);
					$_[HEAP]{xreq}->send(shift @env);
				}else{
					# And send newstyle array for other half
					$_[HEAP]{xreq}->send(\@env);
				}
			},
			got_input => sub {
				my $msgs = $_[ARG0];
				is(scalar @$msgs, 1, 'one msg part received');
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
				is(scalar @$msgs, 3, 'three msg parts received');
				my $id= shift @$msgs;
				my $null = shift @$msgs;
				my $msg = shift @$msgs;

				my $cnt = substr($id->data, 2);
				is(substr($id->data,0,2), 'ID', 'correct ID');
				is($cnt, $_[HEAP]{cnt}, 'correct cnt in ID');

				is($null->data, '', 'null message is blank');

				$cnt = substr($msg->data, 4);
				is(substr($msg->data,0,4), 'pong', 'correct pong');
				is($cnt, $_[HEAP]{cnt}, 'correct cnt in MSG');

				$cnt = $_[HEAP]{cnt}++;

				if($cnt >= 9) {
					# Break;
					$_[HEAP]{xreq}->close();
					$_[HEAP]{rep}->close();
					return;
				}

				# ping again
				$poe_kernel->yield('ping');
			}

		}
	);

POE::Kernel->run();


