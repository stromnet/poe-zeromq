#use lib 'inst/usr/local/lib/perl5/site_perl/5.10.1/mach';
use lib 'lib';
use ZMQ qw(:all);
use ZMQ::Constants qw(:all);
use POE::Wheel::ZeroMQ;
use strict;
use Time::HiRes qw(time);

my $version_string = ZMQ::call("zmq_version");
print "Starting with ZMQ $version_string\n";

use Time::HiRes;
use IO::Handle;
use POE;
my $mode = $ARGV[0];
die "Invalid mode parmaeter $mode" unless($mode eq 'sub' or $mode eq 'pub');
my $ctx = ZMQ::Context->new();

POE::Session->create(
		options=>{default=>1, trace=>0},
		inline_states => {
			'sig_DIE' => sub {
				my( $sig, $ex ) = $_[ ARG1 ];
				warn "$$: error in $ex->{event}: $ex->{error_str}";
##				exit(1);
			},
			_start => sub {
				$poe_kernel->sig( DIE => 'sig_DIE' );

				$_[HEAP]{wheel} = POE::Wheel::ZeroMQ->new(
						Context => $ctx,
						SocketType => $mode eq 'pub' ? ZMQ_PUB:ZMQ_SUB, #ZMQ_REP,
						($mode eq 'pub'?'SocketBind':'SocketConnect') => "tcp://127.0.0.1:5555",
						InputEvent => 'got_input',
						Subscribe => ''
					);

				print localtime()." Socket set for $mode\n";
				$_[HEAP]{last} = time();
				$poe_kernel->delay('ping', 1) if($mode eq 'pub');
			},
			got_input => sub {
				my $msg = $_[ARG0];
				my $w = $_[HEAP]{wheel};

				die "Eek where did my wheel go" unless defined $w;
#				print "Got input, mirror!\n";
				
				my $now = time();
				my $jitter = $now - $_[HEAP]{last};
				$_[HEAP]{last} = $now;

				# bounce it
#				$w->send($msg, 0);
				my ($time, $str) = split(/:/,$msg->data,2);
				print localtime()." Got input >>$str<<. Delay is ".
					($now-$time).", since last is $jitter.\n";
			},

			ping => sub {
				print localtime()." Sending ping\n";
				my $wheel = $_[HEAP]{wheel};

				my $msg = ZMQ::Message->new(time().': ping at '.localtime());
				$wheel->send($msg);
				$poe_kernel->delay('ping', 1.25);
			}
		}
	);

POE::Kernel->run();
