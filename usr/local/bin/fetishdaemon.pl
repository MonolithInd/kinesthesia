#!/usr/bin/perl

######################################################################
######################################################################
## fetsihdaemon.pl: Generic Fetish daemon for managing and interfacing 
## to fetishes in the kinethesia framework. 
## 
## Written by Kai Rigby - 25/02/2014
##
## v1: 		First implementation of a Fetish Daemon for the 
##			Kinethesia SW/HW framework.
## v1.1: 	Adding proper XML handling of values for passing from
##			the FD to the TD.
## v1.2:	Made the Daemon generic so it can interface with many
## 			types of fetish to cut down on codebase.

use strict;
use warnings;
use Data::Dumper; 
use Socket;
use XML::LibXML;
use POE qw(
	Wheel::SocketFactory
	Wheel::ReadWrite
	Driver::SysRW
	Filter::SSL
	Filter::Stackable
	Filter::Stream
);

if (!$ARGV[0]) {
	print "\nUsage: fetishdaemon.pl <FETSH TYPE>. Available fetish types are defined in the documentation for kinethesia.\n\n";
	exit 1;
}
my $fetish = $ARGV[0];
print "\n*** Starting Fetish Daemon for fetish $fetish ***\n\n";
my $configfile = "/etc/kinethesia/talismandaemon.xml";
my %cfg;
print "= I = Reading in config file: $configfile\n";
my $parser = XML::LibXML->new();
my $cfgref = $parser->parse_file($configfile);
my $cfg = $cfgref -> getDocumentElement();

#foreach my $env ($root->findnodes("fd-$fetish/environmental")) {
#		my $name = $env->findnodes('./name');
#		my $crit = $env->findnodes('./crit');
#		my $warn = $env->findnodes('./warn');
#		print "$name, crit : $crit, warn : $warn\n";
#		print "$env\n\n";
#}

#foreach my $environ ($cfgref->findnodes('/cfg/fd-sht15/environmntal/')) {
#    my($name) = $environ->findnodes('./name');
#    print $name->to_literal, "\n" 
#  }
print "= I = Config file read\n";

if (!$cfg->findnodes("fd-$fetish")) {
	print "\n= C = No config found in $configfile for fetish: $fetish. Exiting.\n\n";
	exit(1);
}

# Set up default values or the below. All values are overridable in the config file. 
my $daemon = 0;
my $debug = 0;
my $daemonport = 2001;
my $bindaddress = "127.0.0.1";
my $pollperiod = 30;
my $serverkey = "/etc/kinethesia/certs/server.key";
my $servercrt = "/etc/kinethesia/certs/server.crt";
my $cacrt = "/etc/kinethesia/certs/ca.crt";

if ($cfg->findvalue("fd-$fetish/debug")) {
	$debug = $cfg->findvalue("fd-$fetish/debug");
	print "\n= I = Loading Debug Setting from config file: $debug\n" if ($debug == 1);
}
if ($cfg->findvalue("fd-$fetish/daemonport")) {
	$daemonport = $cfg->findvalue("fd-$fetish/daemonport");
	print "= I = Loading daemon port from config file: $daemonport\n" if ($debug == 1);
}
if ($cfg->findvalue("GlobalFetishD/bindaddress")) {
	$bindaddress = $cfg->findvalue("GlobalFetishD/bindaddress");
	print "= I = Loading Global bind address from config file: $bindaddress\n" if ($debug == 1);
} elsif ($cfg->findvalue("fd-$fetish/bindaddress")) {
	$bindaddress = $cfg->findvalue("fd-$fetish/bindaddress");
	print "= I = Loading bind address from config file: $bindaddress\n" if ($debug == 1);
}
if ($cfg->findvalue("GlobalFetishD/pollperiod")) {
        $pollperiod = $cfg->findvalue("GlobalFetishD/pollperiod");
	print "= I = Loading Global poll period from config file: $pollperiod\n" if ($debug == 1);
} elsif ($cfg->findvalue("fd-$fetish/pollperiod")) {
        $pollperiod = $cfg->findvalue("fd-$fetish/pollperiod");
	print "= I = Loading poll period from config file: $pollperiod\n" if ($debug == 1);
}
if ($cfg->findvalue("GlobalFetishD/serverkey")) {
	$serverkey = $cfg->findvalue("GlobalFetishD/serverkey");
	print "= I = Loading Global Server Key from config file: $serverkey\n" if ($debug == 1);
} elsif ($cfg->findvalue("fd-$fetish/serverkey")) {
	$serverkey = $cfg->findvalue("fd-$fetish/serverkey");
	print "= I = Loading server key from config file: $serverkey\n" if ($debug == 1);
}
if ($cfg->findvalue("GlobalFetishD/servercrt")) {
	$servercrt = $cfg->findvalue("GlobalFetishD/servercrt");
	print "= I = Loading Global Server Certificate from config file: $servercrt\n" if ($debug == 1);
} elsif ($cfg->findvalue("fd-$fetish/servercrt")) {
	$servercrt = $cfg->findvalue("fd-$fetish/servercrt");
	print "= I = Loading server certificate from config file: $servercrt\n" if ($debug == 1);
}
if ($cfg->findvalue("GlobalFetishD/cacrt")) {
	$cacrt = $cfg->findvalue("GlobalFetishD/cacrt");
	print "= I = Loading Global CA Certificate from config file: $cacrt\n" if ($debug == 1); 
} elsif ($cfg->findvalue("fd-$fetish/cacrt")) {
	$cacrt = $cfg->findvalue("fd-$fetish/cacrt");
	print "= I = Loading CA certificate from config file: $cacrt\n" if ($debug == 1);
}

# Global hash for storing the env details returned by this FD.
my %env;

# Set to run as a Daemon or not for debug. 
if ($daemon) {
        fork and exit;
}

# set print to flush immediatly, this is for the when debug is set high 
# and needs to print to term.
$| = 1;

# POE session for the SSL TCP server to listen for client queries and respond with the appropreate values. 
POE::Session->create(
	inline_states => {
    		_start => \&parent_start,
    		_stop  => \&parent_stop,

    		socket_birth => \&socket_birth,
    		socket_death => \&socket_death,
 	}
);


# POE session to gather data from the fetish and populate the global variables with their current values for serving
# to other clients/services.
POE::Session->create(
	inline_states => {
		_start => sub {
			print "\n= I = Starting fetish polling Session with a polling period of $pollperiod\n" if ($debug == 1);
			$_[HEAP]->{next_alarm_time} = int(time());
			$_[KERNEL]->alarm(tick => $_[HEAP]->{next_alarm_time});
			print "= I = Fetish Polling session started\n" if ($debug == 1);
		},

		tick => sub {
			print "\n= I = Polling fetish for environmental values and populating variables\n" if ($debug == 1);
			pollfetish();
			$_[HEAP]->{next_alarm_time} = $_[HEAP]->{next_alarm_time} + $pollperiod;
                        $_[KERNEL]->alarm(tick => $_[HEAP]->{next_alarm_time});
		}
	}
);


sub parent_start {
	my $heap = $_[HEAP];

	print "\n= I = Starting POE session and initialising socket\n" if ($debug == 1);
	$heap->{listener} = POE::Wheel::SocketFactory->new(
		BindAddress  => $bindaddress,
		BindPort     => $daemonport,
		Reuse        => 'yes',
		SuccessEvent => 'socket_birth',
		FailureEvent => 'socket_death',
  	);
	print "= I = Socket initialised on $bindaddress:$daemonport Waiting for connections\n" if ($debug == 1);
}

# clean up if we shut down the server
sub parent_stop {
	my $heap = $_[HEAP];
	delete $heap->{listener};
	delete $heap->{session};
	print "= I = Listener Death!\n" if ($debug == 1);
}


# open the socket for the remote session.
sub socket_birth {
	my ($socket, $address, $port) = @_[ARG0, ARG1, ARG2];

	$address = inet_ntoa($address);
	print "\n= S = Socket birth client connecting\n" if ($debug == 1);

	POE::Session->create(
		inline_states => {
			_start => \&socket_success,
			_stop  => \&socket_death,

			socket_input => \&socket_input,
			socket_death => \&socket_death,
    		},
		args => [$socket, $address, $port],
	);
}

# close the socket session when the user exits.
sub socket_death {
	my $heap = $_[HEAP];
	if ($heap->{socket_wheel}) {
		print "= S = Socket death, client disconnected\n" if ($debug == 1);
		delete $heap->{socket_wheel};
	}
}

#  yay! we sucessfully opened a socket. Set up the session.
sub socket_success {
	my ($heap, $kernel, $connected_socket, $address, $port) = @_[HEAP, KERNEL, ARG0, ARG1, ARG2];
	
	print "= I = CONNECTION from $address : $port \n" if ($debug == 1);
	print "= SSL = Creating SSL Object\n" if ($debug == 1);
	$heap->{sslfilter} = POE::Filter::SSL->new(
		crt    => $servercrt,
		key    => $serverkey,
		cacrt  => $cacrt,
		cipher => 'DHE-RSA-AES256-GCM-SHA384:AES256-SHA',
		debug  => 1,
		clientcert => 1
	);
	$heap->{socket_wheel} = POE::Wheel::ReadWrite->new(
		Handle => $connected_socket,
		Driver => POE::Driver::SysRW->new(),
		Filter => POE::Filter::Stackable->new(Filters => [
			$heap->{sslfilter},
			POE::Filter::Stream->new(),
		]),
		InputEvent => 'socket_input',
		ErrorEvent => 'socket_death',
	);
	print "= SSL = SSL Socket Created\n" if ($debug == 1);
}

sub socket_input {
	my ($heap, $kernel, $buf) = @_[HEAP, KERNEL, ARG0];
	my $response = "";
	my $sub;
	my $command;
	my $refresh;
	my $ref;
	$ref = XMLin($buf);
	print "= I = Client command received :\n\n$buf\n" if ($debug == 1);
	print "= SSL = Authing Client Command\n" if ($debug == 1);
	if ($heap->{sslfilter}->clientCertValid()) {
		print "= SSL = Client Certificate Valid, Authorised\n" if ($debug == 1);
		# If the talisman Daemon requests a realtime value from the fetish, update the values 
		# and return them. Note this will slow down the query response. 
		if ($ref->{'immediate'}) {
			print "\n= I = Clint has requested realtime fetish values, refreshing.\n" if ($debug == 1);
			pollfetish();
		}
		# The option is available here ti query the Fetish Daemon for only specific values.
		# the decision at this time is to only ask for everything it has and filter to the 
		# shadow at the telisman daemon level. But this can be changed at a later time for 
		# additional filtering and traffic efficiency on low bandwidth links.
		if ($ref->{'command'} eq "all") {
			$response = allresponse();
		} elsif ($ref->{'command'} eq "poll") {
			$response = pollreponse();
		} else {
			$response = errresponse("Unknown query command sent to fetish daemon $fetish");
		}
		print "= I = Sending Client Result:\n\n$response\n" if ($debug == 1);
		$heap->{socket_wheel}->put($response);
	} else {
		print "= SSL = Client Certificate Invalid! Rejecting command and disconnecting!\n" if ($debug == 1);
		$response = errresponse("INVALID CERT! Connection rejected!");
		print "= I = Sending Client Result:\n$response\n" if ($debug == 1);
		$heap->{socket_wheel}->put($response);
		$kernel->delay(socket_death => 1);
	}
}

$poe_kernel->run();

#### NON POE subs below this line

sub errresponse {

	my $msg = shift;
	my %err;
	my $hashref;
	my $xs;
	my $xml;

	$err{'msg'} = $msg;
	$hashref = \%err;
	$xs = new XML::Simple;
	$xml = $xs->XMLout($hashref, NoAttr => 1,RootName => 'error');
	return $xml;
}

sub allresponse {

        my $resp;
        my $hashref;
        my $xs;
        my $xml;

	if (!%env) {
		$xml = errresponse("No values from the Fetish! Fetish is either broken or not responding");
	} else {  
        	$hashref = \%env;
        	$xs = new XML::Simple;
        	$xml = $xs->XMLout($hashref, NoAttr => 1,RootName => $fetish);
	}
        return $xml;
}

sub pollreponse {

        my %poll;
        my $hashref;
        my $xs;
        my $xml;

        $poll{'value'} = "OK";
        $hashref = \%poll;
        $xs = new XML::Simple;
        $xml = $xs->XMLout($hashref, NoAttr => 1,RootName => 'response');
        return $xml;
}
	
sub pollfetish {

	my @values;
	my @temp;
	my $key;
	my $envtemp;
	my %keyval;
	my $node_cnt = 0;
	my @nodes;
	my $node;
	my $fetishresponse;
	my @environmentals;
	my $pollval;
	my $critval;
	my $warnval;

	$fetishresponse = `/usr/local/bin/f-$fetish.py`;
	chomp($fetishresponse);
	if (!$fetishresponse) {
		print "= W = No values from the Fetish! Fetish is either broken or not responding\n" if ($debug == 1);
		undef %env;
	} else {
		@values = split(',', $fetishresponse);	
		# store the responses in a temp hash.
                foreach (@values) {
                        @temp = split(':', $_);
                        $keyval{"$temp[0]"} = $temp[1];
                }
		#first lets make sure we have as many environmentals defiend as were returned.
		my $node_cnt = $cfg->findvalue("count(fd-$fetish/environmental)");
		if ($node_cnt < @values) {
			print "= W = Fetish returned more environmental values than are defined in your cfg file, have you forgotten to define an environmental? (You could just be filtering in which case ignore this message)\n" if ($debug == 1);
		} 
		# now lts make sure we actually got all the values we expected from the config.
		foreach ($cfg->findnodes("fd-$fetish/environmental")) {
    			foreach ($_->findnodes('./name')) {
				$envtemp = $_->textContent();
				#create an array of expected respones to hand up the the talismandaemon.
				push(@environmentals, $envtemp);	
				if (!$keyval{$envtemp}) {
					print "= W = Fetish did not provide environmental $envtemp that is defined in the cfg file, Are you sure this fetish can give you this value?\n" if ($debug == 1);
				}
  			}
		}
		# Now lets go through our list of expected responses and make sure we don't have to raise any alerts based on the responses.
		foreach $key (@environmentals) {
			if (!$keyval{"$key"}) {
				next;
			} else {
				$pollval = $keyval{"$key"};
				# assign the epected returned values to the response hash.
				$env{"$key"}{'value'} = $keyval{"$key"};
			}
			@nodes = $cfg->findnodes("fd-$fetish/environmental/name[text( )='$key']/..");
			foreach (@nodes) {
				$warnval = $_->findvalue("./warn");
				$critval = $_->findvalue("./crit");
			}
			if ($critval) {
				if ($env{"$key"}{'value'} >= $critval) {
					print "= C = CRITICAL!: Polled value for $key of $pollval exceeds configured critical value for this environmental of $critval! Raising CRITICAL ALERT\n" if ($debug == 1);
				}
			} elsif ($warnval) {
				if ($env{"$key"}{'value'} >= $warnval) {
					print "= W = WARNING!: Polled value for $key of $pollval exceeds configured warning value for this environmental of $warnval! Raising WARNING ALERT\n" if ($debug == 1);
				}
			}
			$pollval = "";
			$warnval = "";
			$critval = "";
		}
		if ($debug == 1) {
			print "= I = Values populated : ";
			foreach $key (keys(%env)) {
				print "$key:$env{$key}{'value'} ";
			}
			print "\n";
		}
	}
}
### END OF LINE ###
